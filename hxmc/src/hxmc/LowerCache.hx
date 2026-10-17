package hxmc;

import hxmc.ir.Ir;
import hxmc.ir.Lower;
import core.TType;

// Function bodies lowered once, reused by the next builds of the resident
// compiler (`hxmc --server`, Driver.resident).
//
// A lowered body is a function of its typed expression and of what the body
// asked the lowering on the way: the classes, functions, closures, globals,
// signatures and selectors it refers to, and a few questions about the
// program (does a call need dispatch, which method does a name find). Each
// body's entry keeps the expression it came from (by identity), those calls
// with their arguments and results, and the body. The next build, given the
// same field object with the same expression (the compilation server
// retypes a changed module and every module depending on it, which makes
// new field objects; the others keep theirs), replays the calls in order
// (the program gets every effect they had: what they make reachable, the
// numbers they hand out, in the order a fresh lowering gives them), binds
// the objects and numbers the old calls returned to the new ones, and
// copies the body through that binding. A question answered differently,
// or an old object or number the binding does not know, abandons the whole
// lowering, done again from scratch (and recorded). An entry is not changed
// by a replay: it keeps the objects of the build that recorded it (bound
// anew each build), so a body is copied once per build.
//
// Closures written in a body are cached with it (their bodies are lowered
// later, by their own entries, found through the closure's old function).
// Static initializers and the closures the lowering makes itself
// (forwarders, adapters) are lowered again each build: they are small.
class LowerCache {
	var entries = new haxe.ds.ObjectMap<TClassField, Entry>();
	var lambdas = new haxe.ds.ObjectMap<FuncInfo, Entry>(); // closure bodies, by their (recorded) function

	public var hits = 0;
	public var misses = 0;
	public var restarts = 0;
	public var build = 0; // builds lowered (Entry.gen)
	public var why:Null<String> = null; // the last restart's reason

	public function new() {}

	var target = -1; // the target the bodies were lowered for (they fold its tests)
	var lines = false; // and whether they have their positions (Lower.lines)

	public function lower(main:TClass, types:Array<ModuleType>, basic:BasicTypes):Program {
		hits = misses = 0;
		why = null;
		build++;
		if (Lower.targetCode != target || Lower.lines != lines) {
			entries = new haxe.ds.ObjectMap();
			lambdas = new haxe.ds.ObjectMap();
			target = Lower.targetCode;
			lines = Lower.lines;
		}
		var l = new CachedLower(this, true);
		var prog = try Lower.program(main, types, basic, l) catch (m:Mismatch) {
			restarts++;
			why = m.why;
			l = new CachedLower(this, false);
			Lower.program(main, types, basic, l);
		}
		hits = l.hits;
		misses = l.misses;
		entries = l.newEntries;
		lambdas = l.newLambdas;
		return prog;
	}

	@:allow(hxmc.CachedLower) function entry(cf:TClassField):Null<Entry>
		return entries.get(cf);

	@:allow(hxmc.CachedLower) function lambdaEntry(fi:FuncInfo):Null<Entry>
		return lambdas.get(fi);

}

class Mismatch {
	public var why:String;

	public function new(why)
		this.why = why;
}

class Entry {
	public var tf:Null<TFunc>; // the expression lowered (closures: null)
	public var fi:FuncInfo;
	public var log:Array<LCall> = [];
	public var body:Array<Stmt>;
	public var locals:Array<Local>;
	public var hasTry:Bool;
	public var nlambdas:Int;
	public var tests:Null<haxe.ds.ObjectMap<{}, Ex>> = null; // per catch with a test: the test applied to MARK
	public var gen = 0; // the build that recorded it: its global and selector numbers are that build's

	public function new(tf, fi) {
		this.tf = tf;
		this.fi = fi;
	}
}

// A call of a body into the lowering, with its result
enum LCall {
	CTy(t:T, r:Ty);
	CClass(c:TClass, r:ClassInfo);
	CEnum(e:TEnum, r:EnumInfo);
	CCtorInfo(ef:TEnumField, en:TEnum, r:CtorInfo);
	CStatic(c:TClass, cf:TClassField, r:FuncInfo);
	CMethod(c:TClass, cf:TClassField, r:FuncInfo);
	CCtor(c:TClass, r:FuncInfo);
	CStructCtor(c:TClass, r:FuncInfo);
	CStructBox(name:String, r:ClassInfo);
	CStaticVar(c:TClass, cf:TClassField, r:Int);
	CReflect(c:TClass);
	CStaticClos(f:FuncInfo, r:LambdaInfo);
	CHostClos(name:String, sig:SigInfo, self:Null<Ty>, r:LambdaInfo);
	CCtorClos(ci:CtorInfo, sig:SigInfo, r:LambdaInfo);
	CBoundClos(f:FuncInfo, dispatch:Null<{sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass}>, owner:FuncInfo, r:LambdaInfo);
	CAdapter(from:SigInfo, to:SigInfo, r:LambdaInfo);
	CLambda(sig:SigInfo, captures:Array<Local>, name:String, module:String, r:LambdaInfo);
	CSelector(name:String, sig:SigInfo, r:Int);
	CNeedsDispatch(c:TClass, name:String, r:Bool);
	CLookup(c:TClass, name:String, r:Null<{cls:TClass, field:TClassField}>);
	CImplementors(c:TClass, name:String, r:Array<{cls:TClass, field:TClassField}>);
	CRootDecl(c:TClass, name:String, r:Null<TClassField>);
	CSuperOf(ci:ClassInfo, r:Null<TClass>);
	CRoot(r:ClassInfo);
	CSig(args:Array<Ty>, ret:Ty, r:SigInfo);
	CShape(fields:Array<{name:String, ty:Ty}>, r:ShapeInfo);
}

// The program's signatures and shapes asked by a body: logged
class CachedProgram extends Program {
	var l:CachedLower;

	public function new(l) {
		super();
		this.l = l;
	}

	override public function sig(args:Array<Ty>, ret:Ty):SigInfo {
		l.depth++;
		var r = super.sig(args, ret);
		l.depth--;
		l.log(CSig(args, ret, r));
		return r;
	}

	override public function shape(fields:Array<{name:String, ty:Ty}>):ShapeInfo {
		l.depth++;
		var r = super.shape(fields);
		l.depth--;
		l.log(CShape(fields, r));
		return r;
	}
}

@:access(hxmc.ir.Lower)
class CachedLower extends Lower {
	var cache:LowerCache;
	var reuse:Bool;

	public var newEntries = new haxe.ds.ObjectMap<TClassField, Entry>();
	public var newLambdas = new haxe.ds.ObjectMap<FuncInfo, Entry>();
	public var hits = 0;
	public var misses = 0;

	// the calls of the body being lowered are logged here (the ones a call
	// makes inside the lowering are not: replaying it makes them)
	var cur:Null<Entry> = null;
	var tests:Null<haxe.ds.ObjectMap<{}, Ex>> = null; // the catch tests of the body copied

	public var depth = 0;

	// closures written in the bodies logged: their bodies are recorded too
	var bodyLambdas = new haxe.ds.ObjectMap<FuncInfo, Bool>();
	// closures replayed: their old body, by the new function
	var replayLambdas = new haxe.ds.ObjectMap<FuncInfo, Entry>();

	// the old objects bound to the new ones, the old global and selector numbers
	var map = new haxe.ds.ObjectMap<{}, Dynamic>();
	// (numbers by the build that handed them out: entries of several builds meet)
	var gmaps = new Map<Int, Map<Int, Int>>();
	var smaps = new Map<Int, Map<Int, Int>>();
	var gmap:Map<Int, Int>;
	var smap:Map<Int, Int>;
	static var skipTy = Sys.getEnv("HXMC_LOWER_NOSKIP") != "1";
	var ident = false; // copying with no binding (the program's copy of a body)

	static var MARK = new Local(-0x7fff, "mark", TRef(RAny));

	public function new(cache, reuse) {
		super();
		this.cache = cache;
		this.reuse = reuse;
		var p = new CachedProgram(this);
		p.classes = prog.classes;
		prog = p;
	}

	public inline function log(c:LCall) {
		if (depth == 0 && cur != null) cur.log.push(c);
	}

	static function funcExpr(cf:TClassField):Null<TFunc>
		return cf.cfExpr == null ? null : switch cf.cfExpr.eexpr {
			case TFunction(tf): tf;
			case _: null;
		}

	override function lowerBody(fi:FuncInfo, key:Null<TClassField>, run:() -> Void) {
		depth = 0;
		if (key != null) {
			var tf = funcExpr(key);
			var old = reuse ? cache.entry(key) : null;
			if (old != null && tf != null && old.tf == tf) {
				replay(fi, old);
				newEntries.set(key, old);
				hits++;
			} else {
				newEntries.set(key, recordBody(fi, tf, run));
				misses++;
			}
			return;
		}
		var old = replayLambdas.get(fi);
		if (old != null) {
			replay(fi, old);
			newLambdas.set(old.fi, old);
			hits++;
		} else if (bodyLambdas.exists(fi)) {
			newLambdas.set(fi, recordBody(fi, null, run));
			misses++;
		} else run();
	}

	function recordBody(fi:FuncInfo, tf:Null<TFunc>, run:() -> Void):Entry {
		var e = new Entry(tf, fi);
		e.gen = cache.build;
		cur = e;
		run();
		cur = null;
		e.body = fi.body;
		e.locals = fi.locals;
		e.hasTry = fi.hasTry;
		e.nlambdas = fi.nlambdas;
		// the catches' tests, as expressions of MARK
		if (e.hasTry)
			walkTries(e.body, c -> if (c.test != null) {
				if (e.tests == null) e.tests = new haxe.ds.ObjectMap();
				e.tests.set(c, c.test(ELocal(MARK)));
			});
		// the program's copy (Facts' preparation rewrites statement lists)
		ident = true;
		tests = e.tests;
		fi.body = stmts(e.body);
		ident = false;
		fi.locals = e.locals.copy();
		return e;
	}

	function replay(fi:FuncInfo, old:Entry) {
		gmap = gmaps.get(old.gen);
		if (gmap == null) gmaps.set(old.gen, gmap = new Map());
		smap = smaps.get(old.gen);
		if (smap == null) smaps.set(old.gen, smap = new Map());
		stamp++;
		bindFunc(old.fi, fi);
		for (c in old.log)
			call(c);
		fi.locals = [for (x in old.locals) local(x)];
		fi.hasTry = old.hasTry;
		fi.nlambdas = old.nlambdas;
		tests = old.tests;
		fi.body = stmts(old.body);
	}

	// ---- the calls, logged

	override public function ty(t:T):Ty {
		depth++;
		var r = super.ty(t);
		depth--;
		log(CTy(t, r));
		return r;
	}

	override public function classInfo(c:TClass):ClassInfo {
		depth++;
		var r = super.classInfo(c);
		depth--;
		log(CClass(c, r));
		return r;
	}

	override public function enumInfo(e:TEnum):EnumInfo {
		depth++;
		var r = super.enumInfo(e);
		depth--;
		log(CEnum(e, r));
		return r;
	}

	override public function ctorInfo(ef:TEnumField, en:TEnum):CtorInfo {
		depth++;
		var r = super.ctorInfo(ef, en);
		depth--;
		log(CCtorInfo(ef, en, r));
		return r;
	}

	override public function staticFunc(c:TClass, cf:TClassField):FuncInfo {
		depth++;
		var r = super.staticFunc(c, cf);
		depth--;
		log(CStatic(c, cf, r));
		return r;
	}

	override public function method(c:TClass, cf:TClassField):FuncInfo {
		depth++;
		var r = super.method(c, cf);
		depth--;
		log(CMethod(c, cf, r));
		return r;
	}

	override public function ctor(c:TClass):FuncInfo {
		depth++;
		var r = super.ctor(c);
		depth--;
		log(CCtor(c, r));
		return r;
	}

	override public function structBox(name:String):ClassInfo {
		depth++;
		var r = super.structBox(name);
		depth--;
		log(CStructBox(name, r));
		return r;
	}

	override public function structCtor(c:TClass):FuncInfo {
		depth++;
		var r = super.structCtor(c);
		depth--;
		log(CStructCtor(c, r));
		return r;
	}

	override public function staticVar(c:TClass, cf:TClassField):Int {
		depth++;
		var r = super.staticVar(c, cf);
		depth--;
		log(CStaticVar(c, cf, r));
		return r;
	}

	override public function reflectStatics(c:TClass) {
		depth++;
		super.reflectStatics(c);
		depth--;
		log(CReflect(c));
	}

	override public function staticClosure(f:FuncInfo):LambdaInfo {
		depth++;
		var r = super.staticClosure(f);
		depth--;
		log(CStaticClos(f, r));
		return r;
	}

	override public function hostClosure(name:String, sig:SigInfo, ?self:Ty):LambdaInfo {
		depth++;
		var r = super.hostClosure(name, sig, self);
		depth--;
		log(CHostClos(name, sig, self, r));
		return r;
	}

	override public function ctorClosure(ci:CtorInfo, sig:SigInfo):LambdaInfo {
		depth++;
		var r = super.ctorClosure(ci, sig);
		depth--;
		log(CCtorClos(ci, sig, r));
		return r;
	}

	override public function boundClosure(f:FuncInfo, dispatch:Null<{sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass}>, owner:FuncInfo):LambdaInfo {
		depth++;
		var r = super.boundClosure(f, dispatch, owner);
		depth--;
		log(CBoundClos(f, dispatch, owner, r));
		return r;
	}

	override public function adapter(from:SigInfo, to:SigInfo):LambdaInfo {
		depth++;
		var r = super.adapter(from, to);
		depth--;
		log(CAdapter(from, to, r));
		return r;
	}

	override public function newLambda(sig:SigInfo, captures:Array<Local>, body:hxmc.ir.FnLower->Void, name:String, module:String):LambdaInfo {
		depth++;
		var r = super.newLambda(sig, captures, body, name, module);
		depth--;
		if (depth == 0 && cur != null) {
			cur.log.push(CLambda(sig, captures, name, module, r));
			bodyLambdas.set(r.fn, true);
		}
		return r;
	}

	override public function selector(name:String, sig:SigInfo):Int {
		depth++;
		var r = super.selector(name, sig);
		depth--;
		log(CSelector(name, sig, r));
		return r;
	}

	override public function needsDispatch(c:TClass, name:String):Bool {
		depth++;
		var r = super.needsDispatch(c, name);
		depth--;
		log(CNeedsDispatch(c, name, r));
		return r;
	}

	override public function lookupMethod(c:TClass, name:String):Null<{cls:TClass, field:TClassField}> {
		depth++;
		var r = super.lookupMethod(c, name);
		depth--;
		log(CLookup(c, name, r));
		return r;
	}

	override public function implementors(c:TClass, name:String):Array<{cls:TClass, field:TClassField}> {
		depth++;
		var r = super.implementors(c, name);
		depth--;
		log(CImplementors(c, name, r));
		return r;
	}

	override public function rootDecl(c:TClass, name:String):TClassField {
		depth++;
		var r = super.rootDecl(c, name);
		depth--;
		log(CRootDecl(c, name, r));
		return r;
	}

	override public function superOf(ci:ClassInfo):TClass {
		depth++;
		var r = super.superOf(ci);
		depth--;
		log(CSuperOf(ci, r));
		return r;
	}

	override public function rootClass():ClassInfo {
		var r = super.rootClass();
		log(CRoot(r));
		return r;
	}

	// ---- replay

	static function mismatch(why:String):Dynamic
		throw new Mismatch(why);

	function call(c:LCall) {
		switch c {
			case CTy(t, r):
				// (made of what is bound already: no effect, the same type)
				if (!skipTy || !boundTy(r)) bindTy(r, ty(t));
			case CClass(k, r):
				bindClass(r, classInfo(k));
			case CEnum(e, r):
				bindEnum(r, enumInfo(e));
			case CCtorInfo(ef, en, r):
				bindCtor(r, ctorInfo(ef, en));
			case CStatic(k, cf, r):
				bindFunc(r, staticFunc(k, cf));
			case CMethod(k, cf, r):
				bindFunc(r, method(k, cf));
			case CCtor(k, r):
				bindFunc(r, ctor(k));
			case CStructCtor(k, r):
				bindFunc(r, structCtor(k));
			case CStructBox(name, r):
				bindClass(r, structBox(name));
			case CStaticVar(k, cf, r):
				bindGlobal(r, staticVar(k, cf));
			case CReflect(k):
				reflectStatics(k);
			case CStaticClos(f, r):
				bindLambda(r, staticClosure(obj(f)));
			case CHostClos(name, s, self, r):
				bindLambda(r, hostClosure(name, obj(s), self == null ? null : mapTy(self)));
			case CCtorClos(ci, s, r):
				bindLambda(r, ctorClosure(obj(ci), obj(s)));
			case CBoundClos(f, d, owner, r):
				bindLambda(r, boundClosure(obj(f), d == null ? null : {sel: sel(d.sel), sig: obj(d.sig), args: [for (t in d.args) mapTy(t)], cls: d.cls}, obj(owner)));
			case CAdapter(from, to, r):
				bindLambda(r, adapter(obj(from), obj(to)));
			case CLambda(s, caps, name, module, r):
				var body = cache.lambdaEntry(r.fn);
				if (body == null) mismatch("closure " + name + " without its body");
				var n = newLambda(obj(s), [for (x in caps) local(x)], _ -> throw "hxmc: a replayed closure lowered", name, module);
				bindLambda(r, n);
				bodyLambdas.remove(n.fn);
				replayLambdas.set(n.fn, body);
			case CSelector(name, s, r):
				bindSel(r, selector(name, obj(s)));
			case CNeedsDispatch(k, name, r):
				if (needsDispatch(k, name) != r) mismatch("dispatch of " + name + " changed");
			case CLookup(k, name, r):
				var n = lookupMethod(k, name);
				if ((n == null) != (r == null) || n != null && (n.cls != r.cls || n.field != r.field)) mismatch("method " + name + " changed");
			case CImplementors(k, name, r):
				var n = implementors(k, name);
				if (n.length != r.length) mismatch("implementations of " + name + " changed");
				for (i in 0...n.length)
					if (n[i].cls != r[i].cls || n[i].field != r[i].field) mismatch("implementations of " + name + " changed");
			case CRootDecl(k, name, r):
				if (rootDecl(k, name) != r) mismatch("declaration of " + name + " changed");
			case CSuperOf(ci, r):
				if (superOf(obj(ci)) != r) mismatch("superclass changed");
			case CRoot(r):
				bindClass(r, rootClass());
			case CSig(args, ret, r):
				bindSig(r, prog.sig([for (a in args) mapTy(a)], mapTy(ret)));
			case CShape(fields, r):
				bindShape(r, prog.shape([for (f in fields) {name: f.name, ty: mapTy(f.ty)}]));
		}
	}

	// ---- binding old to new

	// false: already bound (to n)
	function bind(o:{}, n:{}):Bool {
		var m = map.get(o);
		if (m != null) {
			if (m != n) mismatch("an object bound twice");
			return false;
		}
		map.set(o, n);
		return true;
	}

	function bindClass(o:Null<ClassInfo>, n:Null<ClassInfo>) {
		if (o == null || n == null) {
			if (o != n) mismatch("class against none");
			return;
		}
		if (!bind(o, n)) return;
		if (o.name != n.name || o.isInterface != n.isInterface || o.fields.length != n.fields.length) mismatch("class " + o.name + " changed");
		bindClass(o.sup, n.sup);
		for (i in 0...o.fields.length) {
			if (o.fields[i].name != n.fields[i].name) mismatch("class " + o.name + " changed");
			bindTy(o.fields[i].ty, n.fields[i].ty);
		}
	}

	function bindEnum(o:Null<EnumInfo>, n:Null<EnumInfo>) {
		if (o == null || n == null) {
			if (o != n) mismatch("enum against none");
			return;
		}
		if (!bind(o, n)) return;
		if (o.name != n.name || o.ctors.length != n.ctors.length) mismatch("enum " + o.name + " changed");
		for (i in 0...o.ctors.length)
			bindCtor(o.ctors[i], n.ctors[i]);
	}

	function bindCtor(o:CtorInfo, n:CtorInfo) {
		if (!bind(o, n)) return;
		if (o.name != n.name || o.tag != n.tag || o.params.length != n.params.length || (o.global < 0) != (n.global < 0))
			mismatch("constructor " + o.name + " changed");
		bindEnum(o.en, n.en);
		for (i in 0...o.params.length)
			bindTy(o.params[i], n.params[i]);
		if (o.global >= 0) bindGlobal(o.global, n.global);
	}

	function bindFunc(o:FuncInfo, n:FuncInfo) {
		if (!bind(o, n)) return;
		if (o.name != n.name || o.args.length != n.args.length) mismatch("function " + o.name + " changed");
		for (i in 0...o.args.length)
			bindLocal(o.args[i], n.args[i]);
		bindTy(o.ret, n.ret);
		if (o.selfClass != null || n.selfClass != null) bindClass(o.selfClass, n.selfClass);
		if (o.lambda != null || n.lambda != null) {
			if (o.lambda == null || n.lambda == null) mismatch("function " + o.name + " changed");
			bindLambda(o.lambda, n.lambda);
		}
	}

	function bindLocal(o:Local, n:Local) {
		if (!bind(o, n)) return;
		bindTy(o.ty, n.ty);
	}

	function bindLambda(o:LambdaInfo, n:LambdaInfo) {
		if (!bind(o, n)) return;
		if (o.captures.length != n.captures.length) mismatch("closure changed");
		bindSig(o.sig, n.sig);
		for (i in 0...o.captures.length)
			bindLocal(o.captures[i], n.captures[i]);
		bindFunc(o.fn, n.fn);
	}

	function bindSig(o:SigInfo, n:SigInfo) {
		if (!bind(o, n)) return;
		if (o.key != n.key) mismatch("signature changed");
	}

	function bindShape(o:ShapeInfo, n:ShapeInfo) {
		if (!bind(o, n)) return;
		if (o.fields.length != n.fields.length) mismatch("shape changed");
		for (i in 0...o.fields.length) {
			if (o.fields[i].name != n.fields[i].name) mismatch("shape changed");
			bindTy(o.fields[i].ty, n.fields[i].ty);
		}
	}

	function bindGlobal(o:Int, n:Int) {
		var m = gmap.get(o);
		if (m == null) gmap.set(o, n) else if (m != n) mismatch("a global bound twice");
	}

	function bindSel(o:Int, n:Int) {
		var m = smap.get(o);
		if (m == null) smap.set(o, n) else if (m != n) mismatch("a selector bound twice");
	}

	// whether every object of t is bound
	function boundTy(t:Ty):Bool {
		return switch t {
			case TRef(r):
				switch r {
					case RObj(c): map.exists(c);
					case REnum(e): e == null || map.exists(e);
					case RCtor(c): map.exists(c);
					case RArr(t) | RBox(t) | RNull(t): boundTy(t);
					// (a function type lowers its argument types too, normalized away in the signature)
					case RClos(_): false;
					case RStr | RAnon | RAny | RType | RNative(_): true;
				}
			case _: true;
		}
	}

	function bindTy(o:Ty, n:Ty) {
		switch [o, n] {
			case [TRef(a), TRef(b)]:
				bindRef(a, b);
			case [TI32, TI32] | [TBool, TBool] | [TF64, TF64] | [TI64, TI64] | [TVoid, TVoid]:
			case [TStruct(a, x), TStruct(b, y)] if (a == b && x == y):
			case _:
				mismatch("type changed");
		}
	}

	function bindRef(a:RefTy, b:RefTy) {
		switch [a, b] {
			case [RObj(x), RObj(y)]: bindClass(x, y);
			case [REnum(x), REnum(y)]: bindEnum(x, y);
			case [RCtor(x), RCtor(y)]: bindCtor(x, y);
			case [RArr(x), RArr(y)]: bindTy(x, y);
			case [RClos(x), RClos(y)]: bindSig(x, y);
			case [RBox(x), RBox(y)]: bindTy(x, y);
			case [RNull(x), RNull(y)]: bindTy(x, y);
			case [RStr, RStr] | [RAnon, RAnon] | [RAny, RAny] | [RType, RType]:
			case [RNative(x), RNative(y)] if (x == y):
			case _: mismatch("type changed");
		}
	}

	// ---- copying through the binding

	function obj<X>(o:X):X {
		if (ident || o == null) return o;
		var n = map.get(cast o);
		if (n == null) mismatch("an object not bound");
		return n;
	}

	// (the function's locals by id, before the map: ids are distinct in a function)
	var lOld:Array<Local> = [];
	var lNew:Array<Local> = [];
	var lStamp:Array<Int> = [];
	var stamp = 0;

	function local(o:Local):Local {
		if (ident || o == MARK) return o;
		var id = o.id;
		if (id >= 0 && id < lOld.length && lStamp[id] == stamp && lOld[id] == o) return lNew[id];
		var n:Local = map.get(o);
		if (n == null) {
			n = new Local(o.id, o.name, mapTy(o.ty));
			map.set(o, n);
		}
		if (id >= 0 && id < 1 << 16) {
			if (id >= lOld.length) {
				lOld.resize(id + 1);
				lNew.resize(id + 1);
				lStamp.resize(id + 1);
			}
			lOld[id] = o;
			lNew[id] = n;
			lStamp[id] = stamp;
		}
		return n;
	}

	function glob(g:Int):Int {
		if (ident) return g;
		var n = gmap.get(g);
		if (n == null) mismatch("a global not bound");
		return n;
	}

	function sel(s:Int):Int {
		if (ident) return s;
		var n = smap.get(s);
		if (n == null) mismatch("a selector not bound");
		return n;
	}

	function mapTy(t:Ty):Ty {
		if (ident) return t;
		return switch t {
			case TRef(r): TRef(mapRef(r));
			case _: t;
		}
	}

	function mapRef(r:RefTy):RefTy {
		return switch r {
			case RObj(c): RObj(obj(c));
			case REnum(e): REnum(obj(e));
			case RCtor(c): RCtor(obj(c));
			case RArr(t): RArr(mapTy(t));
			case RClos(s): RClos(obj(s));
			case RBox(t): RBox(mapTy(t));
			case RNull(t): RNull(mapTy(t));
			case RStr | RAnon | RAny | RType | RNative(_): r;
		}
	}

	function typeRef(t:TypeRef):TypeRef {
		return switch t {
			case TRClass(c): TRClass(obj(c));
			case TREnum(e): TREnum(obj(e));
			case TRBuiltin(_): t;
		}
	}

	function stmts(ss:Array<Stmt>):Array<Stmt>
		return [for (s in ss) stmt(s)];

	function exs(xs:Array<Ex>):Array<Ex>
		return [for (x in xs) ex(x)];

	function stmt(s:Stmt):Stmt {
		return switch s {
			case SSet(l, e): SSet(local(l), ex(e));
			case SExpr(e): SExpr(ex(e));
			case SSetField(c, idx, o, v): SSetField(obj(c), idx, ex(o), ex(v));
			case SAnonSet(name, t, o, v): SAnonSet(name, mapTy(t), ex(o), ex(v));
			case SArrSet(t, a, i, v): SArrSet(mapTy(t), local(a), ex(i), ex(v));
			case SArrPush(t, a, v): SArrPush(mapTy(t), local(a), ex(v));
			case SBoxSet(t, b, v): SBoxSet(mapTy(t), ex(b), ex(v));
			case SSetGlobal(g, v): SSetGlobal(glob(g), ex(v));
			case SIf(c, a, b): SIf(ex(c), stmts(a), stmts(b));
			case SLoop(b): SLoop(stmts(b));
			case SBreak | SContinue: s;
			case SSwitch(e, cases, def): SSwitch(ex(e), [for (c in cases) {values: c.values.copy(), body: stmts(c.body)}], stmts(def));
			case SReturn(e): SReturn(e == null ? null : ex(e));
			case SThrow(e): SThrow(ex(e));
			case STry(b, cs):
				STry(stmts(b), [
					for (c in cs) {
						var t = c.test == null ? null : tests == null ? null : tests.get(c);
						if (c.test != null && t == null) mismatch("a catch without its test");
						{test: t == null ? null : testOf(ex(t)), l: local(c.l), body: stmts(c.body)};
					}
				]);
			case SCold(id, x): SCold(id, stmt(x));
			case SPos(_): s;
		}
	}

	// a catch's test: its template with the value for MARK
	static function testOf(t:Ex):Ex->Ex
		return x -> subst(t, x);

	static function subst(e:Ex, x:Ex):Ex {
		inline function s(e:Ex):Ex
			return subst(e, x);
		inline function ss(xs:Array<Ex>):Array<Ex>
			return [for (y in xs) subst(y, x)];
		return switch e {
			case ELocal(l) if (l == MARK): x;
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | ELocal(_) | EGlobal(_, _) | EType(_) | ENewObj(_): e;
			case EBin(op, a, b): EBin(op, s(a), s(b));
			case ENot(a): ENot(s(a));
			case EConv(op, a): EConv(op, s(a));
			case EBox(t, a): EBox(t, s(a));
			case EUnbox(t, a): EUnbox(t, s(a));
			case EField(c, idx, o): EField(c, idx, s(o));
			case EFieldAddr(c, idx, o): EFieldAddr(c, idx, s(o));
			case EAnonGet(name, t, o, hint): EAnonGet(name, t, s(o), hint);
			case ECast(t, a): ECast(t, s(a));
			case EInstOf(c, a): EInstOf(c, s(a));
			case EEnumTag(a, en): EEnumTag(s(a), en);
			case EEnumParam(c, idx, a): EEnumParam(c, idx, s(a));
			case EArrLen(a): EArrLen(s(a));
			case EArrGet(t, a, i): EArrGet(t, s(a), s(i));
			case EArrGetU(t, a, i): EArrGetU(t, s(a), s(i));
			case EBoxGet(t, b): EBoxGet(t, s(b));
			case ECapture(l, idx, c): ECapture(l, idx, s(c));
			case ECall(f, args): ECall(f, ss(args));
			case ECallDispatch(sel, sig, args): ECallDispatch(sel, sig, ss(args));
			case ECallClos(sig, c, args): ECallClos(sig, s(c), ss(args));
			case ECallAnon(name, sig, o, args): ECallAnon(name, sig, s(o), ss(args));
			case ECallHost(name, args, ret): ECallHost(name, ss(args), ret);
			case ENewEnum(c, args): ENewEnum(c, ss(args));
			case ENewArr(t, vals): ENewArr(t, ss(vals));
			case ENewClos(l, caps): ENewClos(l, ss(caps));
			case ENewBox(t, v): ENewBox(t, s(v));
			case ENewAnon(sh, vals): ENewAnon(sh, ss(vals));
		}
	}

	function ex(e:Ex):Ex {
		return switch e {
			case EInt(_) | EF64(_) | EStr(_): e;
			case ENull(t): ENull(mapTy(t));
			case ELocal(l): ELocal(local(l));
			case EGlobal(g, t): EGlobal(glob(g), mapTy(t));
			case EBin(op, a, b): EBin(op, ex(a), ex(b));
			case ENot(a): ENot(ex(a));
			case EConv(op, a): EConv(op, ex(a));
			case EBox(t, a): EBox(mapTy(t), ex(a));
			case EUnbox(t, a): EUnbox(mapTy(t), ex(a));
			case EField(c, idx, o): EField(obj(c), idx, ex(o));
			case EFieldAddr(c, idx, o): EFieldAddr(obj(c), idx, ex(o));
			case EAnonGet(name, t, o, hint): EAnonGet(name, mapTy(t), ex(o), obj(hint));
			case ECast(t, a): ECast(mapTy(t), ex(a));
			case EInstOf(c, a): EInstOf(obj(c), ex(a));
			case EEnumTag(a, en): EEnumTag(ex(a), obj(en));
			case EEnumParam(c, idx, a): EEnumParam(obj(c), idx, ex(a));
			case EArrLen(a): EArrLen(ex(a));
			case EArrGet(t, a, i): EArrGet(mapTy(t), ex(a), ex(i));
			case EArrGetU(t, a, i): EArrGetU(mapTy(t), ex(a), ex(i));
			case EBoxGet(t, b): EBoxGet(mapTy(t), ex(b));
			case ECapture(l, idx, c): ECapture(obj(l), idx, ex(c));
			case EType(t): EType(typeRef(t));
			case ECall(f, args): ECall(obj(f), exs(args));
			case ECallDispatch(s, sig, args): ECallDispatch(sel(s), obj(sig), exs(args));
			case ECallClos(sig, c, args): ECallClos(obj(sig), ex(c), exs(args));
			case ECallAnon(name, sig, o, args): ECallAnon(name, obj(sig), ex(o), exs(args));
			case ECallHost(name, args, ret): ECallHost(name, exs(args), mapTy(ret));
			case ENewObj(c): ENewObj(obj(c));
			case ENewEnum(c, args): ENewEnum(obj(c), exs(args));
			case ENewArr(t, vals): ENewArr(mapTy(t), exs(vals));
			case ENewClos(l, caps): ENewClos(obj(l), exs(caps));
			case ENewBox(t, v): ENewBox(mapTy(t), ex(v));
			case ENewAnon(sh, vals): ENewAnon(obj(sh), exs(vals));
		}
	}

	static function walkTries(ss:Array<Stmt>, f:{test:Null<Ex->Ex>, l:Local, body:Array<Stmt>}->Void) {
		for (s in ss)
			walkTry(s, f);
	}

	static function walkTry(s:Stmt, f:{test:Null<Ex->Ex>, l:Local, body:Array<Stmt>}->Void) {
		switch s {
			case SIf(_, a, b):
				walkTries(a, f);
				walkTries(b, f);
			case SLoop(b):
				walkTries(b, f);
			case SSwitch(_, cases, def):
				for (c in cases)
					walkTries(c.body, f);
				walkTries(def, f);
			case STry(b, cs):
				walkTries(b, f);
				for (c in cs) {
					f(c);
					walkTries(c.body, f);
				}
			case SCold(_, x):
				walkTry(x, f);
			case _:
		}
	}
}
