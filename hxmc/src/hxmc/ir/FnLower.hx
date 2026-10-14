package hxmc.ir;

import hxmc.ir.Ir;
import hxmc.ir.Lower;
import core.Ast.Binop;
import core.Ast.Unop;
import core.Ast.UnopFlag;
import core.Ast.WhileFlag;
import core.TType;
import core.TFunctions;

using core.TFunctions;

// Lowers one function body to IR statements (A-normal form: calls and
// allocations only as the value of an SSet/SExpr). Every lowered expression
// has the representation of its typed-AST type, `ty(e.etype)`; consumers
// convert with `coerce`.
class FnLower {
	var l:Lower;
	var fi:FuncInfo;
	var self:Null<ClassInfo>;
	var lambda:Null<LambdaInfo>;
	var locals = new Map<Int, Local>();
	public var boxed:Map<Int, Bool>;
	var thisLocal:Null<Local>;
	var out:Array<Stmt>;
	var nextLocal = 0;

	public function new(l, fi, self, lambda) {
		this.l = l;
		this.fi = fi;
		this.self = self;
		this.lambda = lambda;
		nextLocal = fi.args.length + 1;
		out = fi.body;
	}

	function fail(msg:String, ?e:TExpr):Dynamic
		throw new LowerError(msg, e != null ? '${e.epos.pfile}:${e.epos.pmin}' : "");

	inline function ty(t:T):Ty
		return l.ty(t);

	inline function tyOf(e:TExpr):Ty
		return l.ty(e.etype);

	function newLocal(name:String, t:Ty):Local {
		if (t == TVoid) t = TI32;
		var lo = new Local(nextLocal++, name, t);
		fi.locals.push(lo);
		return lo;
	}

	// ---- entry points

	// a function body; `fi.args` already holds the caller-visible signature
	public function run(tf:TFunc, isCtor = false) {
		if (boxed == null) boxed = Boxing.analyze(tf.tfExpr, tf.tfArgs.map(a -> a.variable));
		var off = 0;
		if (self != null) {
			off = 1;
			if (isCtor) thisLocal = fi.args[0] else {
				thisLocal = newLocal("this", TRef(RObj(self)));
				out.push(SSet(thisLocal, ECast(thisLocal.ty, ELocal(fi.args[0]))));
			}
		}
		bindArgs(tf, off);
		stmt(tf.tfExpr);
	}

	function bindArgs(tf:TFunc, off:Int) {
		for (i in 0...tf.tfArgs.length) {
			var v = tf.tfArgs[i].variable;
			var a = fi.args[i + off];
			var t = ty(v.vType);
			// direct calls pass defaults; calls through closures and Dynamic pass null
			var d = tf.tfArgs[i].defaultValue;
			if (d != null && Ir.isRef(a.ty) && !strip(d).eexpr.match(TConst(TNull)))
				out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), block(() -> out.push(SSet(a, coerceRhs(rhs(d), tyOf(d), a.ty)))), []));
			var x:Ex = ELocal(a);
			if (Ir.repr(t) != Ir.repr(a.ty) || a.ty.match(TRef(RClos(_))) && t.match(TRef(RClos(_)))) {
				var lo = newLocal(v.vName, t);
				out.push(SSet(lo, coerce(x, a.ty, t)));
				x = ELocal(lo);
			}
			if (boxed.exists(v.vId)) {
				var b = newLocal(v.vName + "_box", TRef(RBox(t)));
				out.push(SSet(b, ENewBox(t, x)));
				locals.set(v.vId, b);
			} else switch x {
				case ELocal(lo): locals.set(v.vId, lo);
				case _:
			}
		}
	}

	// the body of a closure literal
	public function runLambda(tf:TFunc, outerBoxed:Map<Int, Bool>, captured:Array<{id:Int, ty:Ty}>) {
		boxed = outerBoxed;
		var inner = Boxing.analyze(tf.tfExpr, tf.tfArgs.map(a -> a.variable));
		for (k in inner.keys())
			boxed.set(k, true);
		var clos = ELocal(fi.args[0]);
		for (i in 0...captured.length) {
			var c = captured[i];
			var lo = newLocal(c.id == -1 ? "this" : "cap" + i, c.ty);
			out.push(SSet(lo, ECapture(lambda, i, clos)));
			if (c.id == -1) thisLocal = lo else locals.set(c.id, lo);
		}
		bindArgs(tf, 1);
		stmt(tf.tfExpr);
	}

	// static initializer: every static var with an expression, then __init__
	public function runInit(c:TClass) {
		boxed = new Map();
		for (cf in c.clOrderedStatics)
			switch cf.cfKind {
				case Var(_) if (cf.cfExpr != null):
					var g = l.staticVar(c, cf);
					var t = l.getProgram().globals[g].ty;
					var x = value(cf.cfExpr);
					out.push(SSetGlobal(g, coerce(x, tyOf(cf.cfExpr), t)));
				case _:
			}
		if (c.clInit != null && c.clInit.cfExpr != null) switch c.clInit.cfExpr.eexpr {
			case TFunction(tf):
				boxed = Boxing.analyze(tf.tfExpr, []);
				stmt(tf.tfExpr);
			case _: stmt(c.clInit.cfExpr);
		}
	}

	// closure body forwarding to a function (static or bound method)
	public function forward(f:FuncInfo, dispatch:Null<{sel:Int, sig:SigInfo}>) {
		boxed = new Map();
		var args = [for (i in 1...fi.args.length) (ELocal(fi.args[i]) : Ex)];
		if (lambda.captures.length > 0) {
			var s = newLocal("self", TRef(RObj(l.rootClass())));
			out.push(SSet(s, ECapture(lambda, 0, ELocal(fi.args[0]))));
			args.unshift(ELocal(s));
		}
		var call = dispatch != null ? ECallDispatch(dispatch.sel, dispatch.sig, args) : ECall(f, args);
		if (fi.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", f.ret);
			out.push(SSet(r, call));
			out.push(SReturn(ELocal(r)));
		}
	}

	// closure body calling a runtime function
	public function forwardHost(name:String) {
		boxed = new Map();
		var args = [for (i in 1...fi.args.length) (ELocal(fi.args[i]) : Ex)];
		if (lambda.captures.length > 0) {
			var s = newLocal("self", lambda.captures[0].ty);
			out.push(SSet(s, ECapture(lambda, 0, ELocal(fi.args[0]))));
			args.unshift(ELocal(s));
		}
		if (fi.ret == TVoid) {
			out.push(SExpr(ECallHost(name, args, TVoid)));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", fi.ret);
			out.push(SSet(r, ECallHost(name, args, fi.ret)));
			out.push(SReturn(ELocal(r)));
		}
	}

	// closure body constructing an enum value
	public function forwardCtor(ci:CtorInfo) {
		boxed = new Map();
		var args = [for (i in 1...fi.args.length) (ELocal(fi.args[i]) : Ex)];
		var r = newLocal("r", fi.ret);
		out.push(SSet(r, ENewEnum(ci, args)));
		out.push(SReturn(ELocal(r)));
	}

	// closure body converting arguments and result between representations
	public function adapt(from:SigInfo) {
		boxed = new Map();
		var inner = newLocal("inner", TRef(RClos(from)));
		out.push(SSet(inner, ECapture(lambda, 0, ELocal(fi.args[0]))));
		var args = [];
		for (i in 0...from.args.length) {
			var a = fi.args[i + 1];
			args.push(coerce(ELocal(a), a.ty, from.args[i]));
		}
		var call = ECallClos(from, ELocal(inner), args);
		if (fi.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(null));
		} else if (from.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(nullOf(fi.ret)));
		} else {
			var r = newLocal("r", from.ret);
			out.push(SSet(r, call));
			out.push(SReturn(coerce(ELocal(r), from.ret, fi.ret)));
		}
	}

	// ---- helpers

	function local(v:TVar, e:TExpr):Local {
		var lo = locals.get(v.vId);
		if (lo == null) fail("unknown local " + v.vName, e);
		return lo;
	}

	function block(f:() -> Void):Array<Stmt> {
		var saved = out;
		out = [];
		f();
		var r = out;
		out = saved;
		return r;
	}

	function temp(t:Ty, e:Ex):Ex {
		var lo = newLocal("t", t);
		out.push(SSet(lo, e));
		return ELocal(lo);
	}

	static function isConst(e:Ex):Bool
		return switch e {
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | EGlobal(_, _) | EType(_): true;
			case _: false;
		}

	// runtime functions that neither allocate nor call back into Haxe code
	public static var PURE = [
		"hx_str_eq" => true, "hx_str_cmp" => true, "hx_dyn_eq" => true, "hx_dyn_cmp" => true, "hx_is" => true, "String_length" => true,
		"String_charCodeAt_i" => true, "hx_str_hash" => true, "hxmc_Native_strHash" => true, "hxmc_Native_objHash" => true, "hxmc_Native_refEq" => true,
		"hx_unbox_int" => true, "hx_unbox_float" => true, "hx_unbox_bool" => true
	];
	// the Math natives: pure, static inline in rt.h
	public static var MATH = [
		for (n in ["NaN", "POSITIVE_INFINITY", "NEGATIVE_INFINITY", "PI", "abs", "acos", "asin", "atan", "atan2", "cos", "sin", "tan", "exp", "log", "sqrt", "pow",
			"floor", "ceil", "round", "ffloor", "fceil", "fround", "max", "min", "isNaN", "isFinite"])
			"Math_" + n => true
	];
	// static inline in rt.h: no prototype is emitted for them
	public static var RT_INLINE = {
		var m = MATH.copy();
		m.set("StringBuf_addChar", true);
		m;
	};
	// natives that never allocate (not GC points), with side effects
	public static var NOGC = ["Math_random" => true, "hx_box_bool" => true];

	public static function isPure(n:String):Bool
		return PURE.exists(n) || MATH.exists(n) || PURE_INTRINSICS.exists(n);

	// C functions declared @:hxmc.c (hxmc.unsafe.LibC): called with the C ABI,
	// never GC points (filled while lowering)
	public static var C_EXTERNS = new Map<String, Bool>();
	// the variadic ones: their first variadic argument (@:hxmc.varargs)
	public static var C_VARIADIC = new Map<String, Int>();
	// the intrinsics of hxmc.unsafe (MirBuild.intrinsic): no GC point but the
	// allocations; these are pure (they read no memory)
	public static var PURE_INTRINSICS = [
		for (n in ["addr", "obj", "sym", "abi", "os", "arm", "target", "ult", "stack"])
			"hxmc_unsafe_Mem_" + n => true
	];

	public static inline function isIntrinsic(n:String):Bool
		return StringTools.startsWith(n, "hxmc_unsafe_Mem_") || StringTools.startsWith(n, "hxmc_unsafe_Atomic_");

	// a runtime function call that is not a GC point
	public static function noGcHost(n:String):Bool
		return isPure(n) || NOGC.exists(n) || C_EXTERNS.exists(n)
			|| (isIntrinsic(n) && n != "hxmc_unsafe_Mem_alloc" && n != "hxmc_unsafe_Mem_allocRaw" && !StringTools.startsWith(n, "hxmc_unsafe_Mem_call"));

	// the layout an object literal of the structural type t gets, when the
	// field `name` has the representation rt there
	function anonHint(t:T, name:String, rt:Ty):Null<ShapeInfo> {
		switch TFunctions.follow(t) {
			case TAnon(an) if (an.aStatus.match(Closed | Const)):
				var fs = [for (k => cf in an.aFields) {name: k, ty: ty(cf.cfType)}];
				var sh = l.getProgram().shape(fs);
				var i = sh.slot(name);
				return i > 0 && Ir.repr(sh.fields[i - 1].ty) == Ir.repr(rt) ? sh : null;
			case _:
				return null;
		}
	}

	// haxe.ds.Vector's data (an Array on hxmc), as Vector.get inlines it
	// the typedef itself, not what it follows to: lazy types (HXB reads typedef
	// instances as TLazy) and bound monomorphs are looked through
	static function isVectorData(t:T):Bool
		return switch t {
			case TLazy(f): isVectorData(TFunctions.lazyType(f));
			case TMono(r) if (r.tmType != null): isVectorData(r.tmType);
			case TType(td, _): td.tPath.name == "VectorData" && StringTools.startsWith(td.tPath.pack.join("."), "haxe.ds"); // haxe.ds._Vector.VectorData
			case TAbstract(a, _): a.aPath.name == "Vector" && a.aPath.pack.join(".") == "haxe.ds";
			case _: false;
		}

	public static function isImpure(e:Ex):Bool
		return switch e {
			case ECall(_) | ECallDispatch(_) | ECallClos(_) | ECallAnon(_) | ENewObj(_) | ENewEnum(_) | ENewArr(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_) | EBox(_):
				true;
			case ECallHost(n, _, _): !isPure(n);
			case EArrGet(TRef(RAny), _, _) | EArrGetU(TRef(RAny), _, _): true; // reading an Int/Float array as Dynamic boxes
			case EAnonGet(_): true; // the slow path may box
			case _: false;
		}

	// lowers operands left to right; spills earlier ones when a later one has side effects
	function operands(es:Array<TExpr>):Array<Ex> {
		var r = [];
		for (e in es) {
			var before = out.length;
			var x = value(e);
			if (out.length != before) {
				var spills = [];
				for (i in 0...r.length)
					if (!isConst(r[i]) && !r[i].match(ELocal(_))) {
						var lo = newLocal("s", tyOf(es[i]));
						spills.push(SSet(lo, r[i]));
						r[i] = ELocal(lo);
					}
				for (j in 0...spills.length)
					out.insert(before + j, spills[j]);
			}
			r.push(x);
		}
		return r;
	}

	// operands converted to the given representations (missing trailing ones: defaults)
	function args(es:Array<TExpr>, to:Array<Ty>, defaults:Null<Array<Null<TExpr>>>, offset = 0):Array<Ex> {
		var xs = operands(es);
		var r = [];
		for (i in 0...xs.length) {
			var t = i + offset < to.length ? to[i + offset] : TRef(RAny);
			r.push(coerce(xs[i], tyOf(es[i]), t));
		}
		for (i in xs.length + offset...to.length) {
			var d = defaults != null && i < defaults.length ? defaults[i] : null;
			r.push(d != null ? coerce(value(d), tyOf(d), to[i]) : nullOf(to[i]));
		}
		return r;
	}

	static function tys(f:FuncInfo):Array<Ty>
		return [for (a in f.args) a.ty];

	function asLocal(x:Ex, t:Ty):Local {
		return switch x {
			case ELocal(lo): lo;
			case _:
				var lo = newLocal("a", t);
				out.push(SSet(lo, x));
				lo;
		}
	}

	static function strip(e:TExpr):TExpr
		return switch e.eexpr {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case TCast(e1, null): strip(e1);
			case _: e;
		}

	function nullOf(t:Ty):Ex
		return switch t {
			case TI32 | TBool: EInt(0);
			case TF64: EF64(0);
			case TI64: EConv(I2L, EInt(0));
			case TVoid: EInt(0);
			case TRef(_): ENull(t);
		}

	// ---- conversions

	// converts x from representation `from` to `to`: boxing, unboxing, numeric
	// conversion, closure adapters. Allocations go to a temporary.
	public function coerce(x:Ex, from:Ty, to:Ty):Ex {
		if (to == TVoid || from == TVoid) return x;
		switch [from, to] {
			case [TRef(RClos(a)), TRef(RClos(b))] if (a != b):
				if (x.match(ENull(_))) return ENull(to);
				var li = l.adapter(a, b);
				var c = asLocal(x, from);
				var r = newLocal("adapted", to);
				out.push(SIf(EBin(RefEq, ELocal(c), ENull(from)), [SSet(r, ENull(to))], [SSet(r, ENewClos(li, [ELocal(c)]))]));
				return ELocal(r);
			case _:
		}
		var fr = Ir.repr(from), tr = Ir.repr(to);
		if (fr == tr) return x;
		return switch [from, to] {
			case [TI32, TF64]: EConv(I2F, x);
			case [TF64, TI32]: EConv(F2I, x);
			case [TI32 | TBool, TI64]: EConv(I2L, x);
			case [TI64, TI32]: EConv(L2I, x);
			case [TI64, TBool]: EBin(LNe, x, EConv(I2L, EInt(0)));
			case [TI64, TF64]: EConv(L2F, x);
			case [TF64, TI64]: EConv(F2L, x);
			case [TI32, TBool] | [TBool, TI32]: x;
			case [TF64, TBool]: EBin(FNe, x, EF64(0));
			case [TBool, TF64]: EConv(I2F, x);
			case [_, TRef(RNull(t))] if (Ir.isScalar(from)):
				x.match(ENull(_)) ? ENull(to) : temp(to, EBox(t, coerce(x, from, t)));
			case [_, TRef(_)] if (Ir.isScalar(from)):
				temp(to, EBox(from, x));
			case [TRef(_), _] if (Ir.isScalar(to)):
				x.match(ENull(_)) ? nullOf(to) : EUnbox(to, x);
			case _: x;
		}
	}

	// a value converted to String (for concatenation)
	function toStr(x:Ex, t:Ty):Ex {
		return switch t {
			case TRef(RStr): temp(TRef(RStr), ECallHost(l.native("hx_str_or_null"), [x], TRef(RStr)));
			case TI32: temp(TRef(RStr), ECallHost(l.native("hx_str_of_int"), [x], TRef(RStr)));
			case TF64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_float"), [x], TRef(RStr)));
			case TI64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_i64"), [x], TRef(RStr)));
			case TBool: temp(TRef(RStr), ECallHost(l.native("hx_str_of_bool"), [x], TRef(RStr)));
			case _: temp(TRef(RStr), ECallHost(l.native("hx_std_string"), [x], TRef(RStr)));
		}
	}

	// ---- statements

	function stmt(e:TExpr) {
		if (!Lower.survey) stmt1(e) else try stmt1(e) catch (err:LowerError) {
			l.record(err, fi.name);
			out.push(SThrow(ENull(TRef(RAny))));
		}
	}

	function declare(v:TVar):Local {
		var t = ty(v.vType);
		var lo = isBoxed(v) ? newLocal(v.vName + "_box", TRef(RBox(t))) : newLocal(v.vName, t);
		locals.set(v.vId, lo);
		return lo;
	}

	function stmt1(e:TExpr) {
		switch e.eexpr {
			case TBlock(es):
				for (x in es)
					stmt(x);
			case TParenthesis(e1) | TMeta(_, e1):
				stmt(e1);
			case TVar(v, init):
				var t = ty(v.vType);
				if (isBoxed(v)) {
					var x = init != null ? coerce(value(init), tyOf(init), t) : nullOf(t);
					var b = declare(v);
					out.push(SSet(b, ENewBox(t, x)));
				} else {
					var x = init != null ? rhs(init) : null;
					var lo = declare(v);
					out.push(SSet(lo, x != null ? coerceRhs(x, tyOf(init), t) : nullOf(t)));
				}
			case TIf(c, a, b):
				var cx = cond(c);
				out.push(SIf(cx, block(() -> stmt(a)), b != null ? block(() -> stmt(b)) : []));
			case TWhile(c, body, NormalWhile):
				out.push(SLoop(block(() -> {
					var cx = cond(c);
					out.push(SIf(ENot(cx), [SBreak], []));
					stmt(body);
				})));
			case TWhile(c, body, DoWhile):
				// first iteration skips the test, so `continue` reaches it
				var first = newLocal("first", TBool);
				out.push(SSet(first, EInt(1)));
				out.push(SLoop(block(() -> {
					out.push(SIf(ENot(ELocal(first)), block(() -> {
						var cx = cond(c);
						out.push(SIf(ENot(cx), [SBreak], []));
					}), []));
					out.push(SSet(first, EInt(0)));
					stmt(body);
				})));
			case TSwitch(sw):
				switchStmt(sw, null);
			case TTry(body, catches):
				tryStmt(body, catches, null);
			case TReturn(null):
				out.push(SReturn(null));
			case TReturn(r):
				var x = value(r);
				out.push(fi.ret == TVoid ? SReturn(null) : SReturn(coerce(x, tyOf(r), fi.ret)));
			case TBreak:
				out.push(SBreak);
			case TContinue:
				out.push(SContinue);
			case TThrow(x):
				// as the exceptions filter does for wildcard-catch targets: a haxe.Exception
				// is thrown as its native value (a wrapped value comes out unwrapped)
				var v = coerce(value(x), tyOf(x), TRef(RAny));
				var base = exceptionBase(x.etype);
				if (base != null) v = temp(TRef(RAny), ECall(l.staticFunc(base, base.clStatics.get("thrown")), [v]));
				out.push(SThrow(v));
			case TCall(_, _) | TNew(_, _, _) | TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
			case _:
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
		}
	}

	// value of an SSet: calls stay at the top, converted afterwards if needed
	function coerceRhs(x:Ex, from:Ty, to:Ty):Ex {
		if (Ir.repr(from) == Ir.repr(to) && !(from.match(TRef(RClos(_))) && to.match(TRef(RClos(_))))) return x;
		if (isImpure(x)) x = temp(from, x);
		return coerce(x, from, to);
	}

	function cond(c:TExpr):Ex
		return coerce(value(c), tyOf(c), TBool);

	// assigns the value of a branch to `target` (null: statement)
	function branch(e:TExpr, target:Null<Local>):Array<Stmt> {
		return block(() -> {
			if (target == null) stmt(e) else {
				var x = rhs(e);
				if (!isNoValue(e)) out.push(SSet(target, coerceRhs(x, tyOf(e), target.ty)));
			}
		});
	}

	static function isNoValue(e:TExpr):Bool
		return switch strip(e).eexpr {
			case TThrow(_) | TReturn(_) | TBreak | TContinue: true;
			case _: false;
		}

	function switchStmt(sw:TSwitch, target:Null<Local>) {
		var st = tyOf(sw.switchSubject);
		var subj = value(sw.switchSubject);
		var allInt = st == TI32 || st == TBool;
		if (allInt)
			for (c in sw.switchCases)
				for (p in c.casePatterns)
					if (!strip(p).eexpr.match(TConst(TInt(_) | TBool(_)))) allInt = false;
		var def = sw.switchDefault != null ? branch(sw.switchDefault, target) : [];
		if (allInt) {
			var cases = [];
			for (c in sw.switchCases)
				cases.push({
					values: [
						for (p in c.casePatterns)
							switch strip(p).eexpr {
								case TConst(TInt(i)): i;
								case TConst(TBool(b)): b ? 1 : 0;
								case _: 0;
							}
					],
					body: branch(c.caseExpr, target)
				});
			out.push(SSwitch(subj, cases, def));
		} else {
			var s = asLocal(subj, st);
			var chain = def;
			var i = sw.switchCases.length;
			while (i-- > 0) {
				var c = sw.switchCases[i];
				var body = branch(c.caseExpr, target);
				var r = newLocal("m", TBool);
				var pre = block(() -> {
					out.push(SSet(r, EInt(0)));
					for (p in c.casePatterns) {
						var px = value(p);
						var eq = equality(ELocal(s), st, px, tyOf(p), true);
						out.push(SIf(eq, [SSet(r, EInt(1))], []));
					}
				});
				chain = pre.concat([SIf(ELocal(r), body, chain)]);
			}
			for (x in chain)
				out.push(x);
		}
	}

	function tryStmt(body:TExpr, catches:Array<{variable:TVar, expr:TExpr}>, target:Null<Local>) {
		fi.hasTry = true;
		var b = branch(body, target);
		var cs = [];
		for (c in catches) {
			var t = ty(c.variable.vType);
			var exn = newLocal("exn", TRef(RAny));
			var test = typeTest(c.variable.vType);
			var lo = declare(c.variable);
			// catching haxe.Exception (or a subclass) catches any value, wrapped by haxe.Exception.caught
			var base = exceptionBase(c.variable.vType);
			var caught = null;
			if (base != null) {
				var fn = l.staticFunc(base, base.clStatics.get("caught"));
				caught = newLocal("caught", fn.ret);
				var cls = switch TFunctions.follow(c.variable.vType) {
					case TInst(k, _): k;
					case _: null;
				};
				test = if (cls == base) null else {
					var ci = l.classInfo(cls);
					x -> EInstOf(ci, ECall(fn, [x])); // pure enough: caught allocates only for non-Exception values
				};
			}
			var handler = block(() -> {
				var src:Ex = ELocal(exn);
				if (caught != null) {
					out.push(SSet(caught, ECall(l.staticFunc(base, base.clStatics.get("caught")), [ELocal(exn)])));
					src = ELocal(caught);
				}
				var x = coerce(src, caught != null ? caught.ty : TRef(RAny), t);
				if (isBoxed(c.variable)) out.push(SSet(lo, ENewBox(t, x))) else out.push(SSet(lo, x));
			}).concat(branch(c.expr, target));
			cs.push({test: test, l: exn, body: handler});
		}
		out.push(STry(b, cs));
	}

	// haxe.Exception when t is it or one of its subclasses
	function exceptionBase(t:T):Null<TClass> {
		var c = switch TFunctions.follow(t) {
			case TInst(c, _): c;
			case _: return null;
		};
		while (c != null) {
			if (c.clPath.name == "Exception" && c.clPath.pack.join(".") == "haxe") return c;
			c = c.clSuper != null ? c.clSuper.cls : null;
		}
		return null;
	}

	// a runtime test that a Dynamic value has the given type (null: always true)
	function typeTest(t:T):Null<Ex->Ex> {
		return switch TFunctions.follow(t) {
			case TDynamic(_) | TMono(_): null;
			case TAbstract(a, _) if (a.aPath.name == "Any"): null;
			case TInst(c, _) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && !c.clKind.match(KTypeParameter(_))):
				var ci = l.classInfo(c);
				x -> EInstOf(ci, x);
			case _:
				var tr = typeRefOfType(t);
				tr == null ? null : x -> ECallHost(l.native("hx_is"), [x, EType(tr)], TBool);
		}
	}

	function typeRefOfType(t:T):Null<TypeRef> {
		return switch TFunctions.follow(t) {
			case TInst(c, _):
				if (c.hasClassFlag(CExtern) || c.clKind.match(KTypeParameter(_))) TRBuiltin(Lower.nativeName(c)) else TRClass(l.classInfo(c));
			case TEnum(e, _): TREnum(l.enumInfo(e));
			case TAbstract(a, _): TRBuiltin(Lower.cname(a.aPath.pack, a.aPath.name));
			case _: null;
		}
	}

	function typeRef(mt:ModuleType):TypeRef {
		return switch mt {
			case TClassDecl(c):
				if (c.hasClassFlag(CExtern)) TRBuiltin(Lower.nativeName(c)) else TRClass(l.classInfo(c));
			case TEnumDecl(e): TREnum(l.enumInfo(e));
			case TAbstractDecl(a): TRBuiltin(Lower.cname(a.aPath.pack, a.aPath.name));
			case TTypeDecl(d): typeRefOfType(d.tType);
		}
	}

	// ---- values

	// a pure expression with the representation of ty(e.etype); side effects go to `out`
	function value(e:TExpr):Ex {
		var x = rhs(e);
		if (!isImpure(x)) return x;
		var t = tyOf(e);
		if (t == TVoid) {
			out.push(SExpr(x));
			return EInt(0);
		}
		return temp(t, x);
	}

	function isBoxed(v:TVar):Bool
		return boxed.exists(v.vId);

	// an expression that may be a call or allocation at the top, with the
	// representation of ty(e.etype)
	function rhs(e:TExpr):Ex {
		return switch e.eexpr {
			case TConst(TInt(i)):
				switch tyOf(e) {
					case TF64: EF64(i);
					case TRef(_): coerce(EInt(i), TI32, tyOf(e));
					case _: EInt(i);
				}
			case TConst(TFloat(f)):
				var v = Std.parseFloat(StringTools.replace(f, "_", ""));
				tyOf(e) == TF64 ? EF64(v) : coerce(EF64(v), TF64, tyOf(e));
			case TConst(TBool(b)): coerce(EInt(b ? 1 : 0), TBool, tyOf(e));
			case TConst(TString(s)): EStr(s);
			case TConst(TNull): nullOf(tyOf(e));
			case TConst(TThis):
				if (thisLocal == null) fail("this outside a method", e);
				ELocal(thisLocal);
			case TConst(TSuper):
				if (thisLocal == null) fail("super outside a method", e);
				ELocal(thisLocal);
			case TLocal(v):
				var lo = local(v, e);
				var x:Ex = isBoxed(v) ? EBoxGet(ty(v.vType), ELocal(lo)) : ELocal(lo);
				coerce(x, ty(v.vType), tyOf(e));
			case TParenthesis(e1) | TMeta(_, e1): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, null): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, mt):
				// checked cast: throws when the value doesn't have the type
				var x = coerce(value(e1), tyOf(e1), TRef(RAny));
				var c = temp(TRef(RAny), ECallHost(l.native("hx_cast"), [x, EType(typeRef(mt))], TRef(RAny)));
				coerce(c, TRef(RAny), tyOf(e));
			case TTypeExpr(mt):
				switch mt {
					case TClassDecl(c): l.reflectStatics(c);
					case _:
				}
				EType(typeRef(mt));
			case TField(obj, fa): field(obj, fa, e);
			case TEnumIndex(e1):
				var en = switch TFunctions.follow(e1.etype) {
					case TEnum(en, _): l.enumInfo(en);
					case _: null;
				};
				EEnumTag(value(e1), en);
			case TEnumParameter(e1, ef, i):
				var en = switch TFunctions.follow(e1.etype) {
					case TEnum(en, _): en;
					case _: fail("enum parameter of non-enum", e);
				};
				var c = l.ctorInfo(ef, en);
				coerce(EEnumParam(c, i, value(e1)), c.params[i], tyOf(e));
			case TArray(a, i):
				switch tyOf(a) {
					case TRef(RArr(elem)):
						var xs = operands([a, i]);
						var ix = coerce(xs[1], tyOf(i), TI32);
						coerce(isVectorData(a.etype) ? EArrGetU(elem, xs[0], ix) : EArrGet(elem, xs[0], ix), elem, tyOf(e));
					case _:
						var xs = operands([a, i]);
						var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_aget"), [coerce(xs[0], tyOf(a), TRef(RAny)), coerce(xs[1], tyOf(i), TI32)], TRef(RAny)));
						coerce(r, TRef(RAny), tyOf(e));
				}
			case TBinop(op, a, b): binop(op, a, b, e);
			case TUnop(op, flag, e1): unop(op, flag, e1, e);
			case TCall(f, cargs): call(f, cargs, e);
			case TNew(c, _, cargs) if (Lower.isCore(c, "Array")):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				ENewArr(elem, []);
			case TNew(c, _, cargs) if (c.hasClassFlag(CExtern)):
				var s = ctorSig(c);
				var x = temp(TRef(RNative(Lower.nativeName(c))), ECallHost(l.native(Lower.nativeName(c) + "_new"), args(cargs, s, null), TRef(RNative(Lower.nativeName(c)))));
				coerce(x, TRef(RNative(Lower.nativeName(c))), tyOf(e));
			case TNew(c, _, cargs):
				var ci = l.classInfo(c);
				var k = c;
				while (k.clConstructor == null && k.clSuper != null)
					k = k.clSuper.cls;
				var obj = temp(TRef(RObj(ci)), ENewObj(ci));
				if (k.clConstructor != null) {
					var ctor = l.ctor(k);
					var xs = args(cargs, tys(ctor), l.defaults.get(ctor), 1);
					out.push(SExpr(ECall(ctor, [obj].concat(xs))));
				}
				coerce(obj, TRef(RObj(ci)), tyOf(e));
			case TArrayDecl(vs):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands(vs);
				ENewArr(elem, [for (i in 0...xs.length) coerce(xs[i], tyOf(vs[i]), elem)]);
			case TObjectDecl(fs):
				var xs = operands([for (f in fs) f.expr]);
				var fields = [for (i in 0...fs.length) {name: fs[i].key.name, ty: tyOf(fs[i].expr)}];
				var sh = l.getProgram().shape(fields);
				var vals = [];
				for (sf in sh.fields)
					for (i in 0...fs.length)
						if (fs[i].key.name == sf.name) vals.push(coerce(xs[i], tyOf(fs[i].expr), sf.ty));
				ENewAnon(sh, vals);
			case TFunction(tf): closure(tf, e);
			case TBlock(es):
				if (es.length == 0) EInt(0) else {
					for (i in 0...es.length - 1)
						stmt(es[i]);
					var last = es[es.length - 1];
					coerceRhs(rhs(last), tyOf(last), tyOf(e));
				}
			case TIf(c, a, b) if (b != null && tyOf(e) != TVoid):
				var t = tyOf(e);
				var cx = cond(c);
				var lo = newLocal("r", t);
				out.push(SIf(cx, branch(a, lo), branch(b, lo)));
				ELocal(lo);
			case TSwitch(sw):
				var t = tyOf(e);
				if (t == TVoid) {
					switchStmt(sw, null);
					EInt(0);
				} else {
					var lo = newLocal("r", t);
					switchStmt(sw, lo);
					ELocal(lo);
				}
			case TTry(body, catches):
				var t = tyOf(e);
				var lo = t == TVoid ? null : newLocal("r", t);
				tryStmt(body, catches, lo);
				lo == null ? EInt(0) : ELocal(lo);
			case TThrow(_) | TReturn(_) | TBreak | TContinue | TIf(_, _, _) | TWhile(_, _, _) | TVar(_, _):
				stmt(e);
				nullOf(tyOf(e));
			case TIdent(n): fail("identifier " + n, e);
			case _: fail("expression " + e.eexpr.getName(), e);
		}
	}

	function ctorSig(c:TClass):Array<Ty> {
		if (c.clConstructor == null) return [];
		return switch TFunctions.follow(c.clConstructor.cfType) {
			case TFun(s): [for (a in s.args) ty(a.type)];
			case _: [];
		}
	}

	// ---- field access

	function field(obj:TExpr, fa:TFieldAccess, e:TExpr):Ex {
		return switch fa {
			case FInstance(c, _, cf):
				switch cf.cfKind {
					case Method(MethDynamic) if (isDynMethod(c, cf)): coerce(dynMethod(obj, c, cf, e), dynSlotTy(c, cf), tyOf(e));
					case Method(_): methodClosure(obj, c, cf, e);
					case Var(_) if (Lower.isCore(c, "Array") && cf.cfName == "length"):
						EArrLen(value(obj));
					case Var(_) if (Lower.isCore(c, "String") && cf.cfName == "length"):
						ECallHost("String_length", [value(obj)], TI32);
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						var x = temp(t, ECallHost(l.native(Lower.nativeName(c) + "_get_" + cf.cfName), [value(obj)], t));
						coerce(x, t, tyOf(e));
					case Var(_) if (c.hasClassFlag(CInterface)):
						EAnonGet(cf.cfName, tyOf(e), value(obj), anonHint(obj.etype, cf.cfName, tyOf(e)));
					case Var(_):
						var ci = l.classInfo(c);
						var idx = ci.fieldIndex(cf.cfName);
						coerce(EField(ci, idx, value(obj)), ci.fields[idx].ty, tyOf(e));
				}
			case FStatic(c, cf):
				switch cf.cfKind {
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						coerce(temp(t, ECallHost(l.native(Lower.nativeName(c) + "_" + cf.cfName), [], t)), t, tyOf(e));
					case Var(_):
						var g = l.staticVar(c, cf);
						var t = l.getProgram().globals[g].ty;
						coerce(EGlobal(g, t), t, tyOf(e));
					case Method(_) if (c.hasClassFlag(CExtern) || cf.cfExpr == null):
						var s = switch TFunctions.follow(cf.cfType) {
							case TFun(s): s;
							case _: fail("extern static " + cf.cfName + " is not a function", e);
						};
						var sig = l.getProgram().sig([for (a in s.args) ty(a.type)], ty(s.ret));
						var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig);
						coerce(temp(TRef(RClos(sig)), ENewClos(li, [])), TRef(RClos(sig)), tyOf(e));
					case Method(MethDynamic):
						var g = staticDynMethod(c, cf);
						coerce(EGlobal(g, l.getProgram().globals[g].ty), l.getProgram().globals[g].ty, tyOf(e));
					case Method(_):
						var f = l.staticFunc(c, cf);
						var li = l.staticClosure(f);
						var x = temp(TRef(RClos(li.sig)), ENewClos(li, []));
						coerce(x, TRef(RClos(li.sig)), tyOf(e));
				}
			case FAnon(cf):
				EAnonGet(cf.cfName, tyOf(e), value(obj), anonHint(obj.etype, cf.cfName, tyOf(e)));
			case FDynamic(name):
				var o = coerce(value(obj), tyOf(obj), TRef(RAny));
				var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_get"), [o, EStr(name)], TRef(RAny)));
				coerce(r, TRef(RAny), tyOf(e));
			case FClosure(cl, cf):
				if (cl == null) {
					// a closure of a structural field: just the field's value
					EAnonGet(cf.cfName, tyOf(e), value(obj), anonHint(obj.etype, cf.cfName, tyOf(e)));
				} else if (cf.cfKind.match(Method(MethDynamic)) && isDynMethod(cl.cls, cf)) {
					coerce(dynMethod(obj, cl.cls, cf, e), dynSlotTy(cl.cls, cf), tyOf(e));
				} else methodClosure(obj, cl.cls, cf, e);
			case FEnum(en, ef):
				var ci = l.ctorInfo(ef, en);
				if (ci.global >= 0) coerce(EGlobal(ci.global, TRef(RCtor(ci))), TRef(RCtor(ci)), tyOf(e)) else {
					// a constructor with arguments used as a function
					var sig = l.getProgram().sig(ci.params, TRef(REnum(ci.en)));
					var li = l.ctorClosure(ci, sig);
					coerce(temp(TRef(RClos(sig)), ENewClos(li, [])), TRef(RClos(sig)), tyOf(e));
				}
		}
	}

	// dynamic methods (`dynamic function`): the current function lives in a field
	// slot (Lower.classInfo) or, for statics, a global. The slot starts null and
	// gets the bound method on first use, so every allocation path (constructors,
	// Type.createEmptyInstance) is covered. Deviation: assigning null and calling
	// restores the original method instead of failing.
	function isDynMethod(c:TClass, cf:TClassField):Bool
		return !c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && !Lower.isCore(c, "String") && !Lower.isCore(c, "Array");

	function dynSlotTy(c:TClass, cf:TClassField):Ty {
		var ci = l.classInfo(c);
		return ci.fields[ci.fieldIndex(cf.cfName)].ty;
	}

	function dynMethod(obj:TExpr, c:TClass, cf:TClassField, e:TExpr):Ex {
		var ci = l.classInfo(c);
		var idx = ci.fieldIndex(cf.cfName);
		var st = ci.fields[idx].ty;
		var o = asLocal(value(obj), tyOf(obj));
		var s = newLocal("dm", st);
		out.push(SSet(s, EField(ci, idx, ELocal(o))));
		out.push(SIf(EBin(RefEq, ELocal(s), ENull(st)), block(() -> {
			out.push(SSet(s, methodClosureOf(ELocal(o), c, cf, st, e)));
			out.push(SSetField(ci, idx, ELocal(o), ELocal(s)));
		}), []));
		return ELocal(s);
	}

	function staticDynMethod(c:TClass, cf:TClassField):Int {
		var g = l.staticVar(c, cf);
		var t = l.getProgram().globals[g].ty;
		out.push(SIf(EBin(RefEq, EGlobal(g, t), ENull(t)), block(() -> {
			var f = l.staticFunc(c, cf);
			var li = l.staticClosure(f);
			out.push(SSetGlobal(g, coerce(temp(TRef(RClos(li.sig)), ENewClos(li, [])), TRef(RClos(li.sig)), t)));
		}), []));
		return g;
	}

	// obj.method as a value
	function methodClosure(obj:TExpr, c:TClass, cf:TClassField, e:TExpr):Ex {
		if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array"))
			return methodClosureOf(null, c, cf, tyOf(e), e, obj);
		return methodClosureOf(value(obj), c, cf, tyOf(e), e);
	}

	function methodClosureOf(o:Null<Ex>, c:TClass, cf:TClassField, rt:Ty, e:TExpr, ?obj:TExpr):Ex {
		if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array")) {
			var s = switch TFunctions.follow(cf.cfType) {
				case TFun(s): s;
				case _: fail("extern method " + cf.cfName + " is not a function", e);
			};
			var sig = l.getProgram().sig([for (a in s.args) ty(a.type)], ty(s.ret));
			var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig, tyOf(obj));
			var x = temp(TRef(RClos(sig)), ENewClos(li, [value(obj)]));
			return coerce(x, TRef(RClos(sig)), rt);
		}
		var li:LambdaInfo;
		if (l.needsDispatch(c, cf.cfName)) {
			var d = dispatchSig(c, cf);
			var impl = l.lookupMethod(c, cf.cfName);
			var f = impl != null ? l.method(impl.cls, impl.field) : null;
			if (f == null) fail("closure of an abstract method", e);
			li = l.boundClosure(f, {sel: l.selector(cf.cfName, d), sig: d}, fi);
		} else {
			var impl = l.lookupMethod(c, cf.cfName);
			if (impl == null) fail("no implementation of " + cf.cfName, e);
			li = l.boundClosure(l.method(impl.cls, impl.field), null, fi);
		}
		var x = temp(TRef(RClos(li.sig)), ENewClos(li, [o]));
		return coerce(x, TRef(RClos(li.sig)), rt);
	}

	// the selector signature of a method: its root declaration's
	function dispatchSig(c:TClass, cf:TClassField):SigInfo {
		var decl = l.rootDecl(c, cf.cfName);
		var impl = l.lookupMethod(c, cf.cfName);
		if (impl != null) {
			var f = l.method(impl.cls, impl.field);
			return l.getProgram().sig([for (a in f.args) a.ty], f.ret);
		}
		return switch Lower.followFun((decl != null ? decl : cf).cfType) {
			case TFun(s): l.getProgram().sig([TRef(RObj(l.rootClass()))].concat([for (a in s.args) ty(a.type)]), ty(s.ret));
			case _: fail("method type");
		}
	}

	// ---- operators

	function binop(op:Binop, a:TExpr, b:TExpr, e:TExpr):Ex {
		switch op {
			case OpAssign:
				return assign(a, () -> {x: rhs(b), t: tyOf(b)}, e);
			case OpAssignOp(op2):
				return assign(a, null, e, (cur, curTy) -> arith(op2, cur, curTy, () -> {x: value(b), t: tyOf(b)}, tyOf(a), e));
			case OpBoolAnd | OpBoolOr:
				var lo = newLocal("c", TBool);
				out.push(SSet(lo, cond(a)));
				var rest = block(() -> out.push(SSet(lo, cond(b))));
				out.push(op == OpBoolAnd ? SIf(ELocal(lo), rest, []) : SIf(ELocal(lo), [], rest));
				return ELocal(lo);
			case OpEq | OpNotEq:
				var xs = operands([a, b]);
				var eq = equality(xs[0], tyOf(a), xs[1], tyOf(b), false);
				return op == OpEq ? eq : ENot(eq);
			case OpLt | OpLte | OpGt | OpGte:
				var xs = operands([a, b]);
				return compare(op, xs[0], tyOf(a), xs[1], tyOf(b));
			case OpNullCoal:
				var t = tyOf(e);
				var lo = newLocal("nc", tyOf(a));
				out.push(SSet(lo, rhs(a)));
				var r = newLocal("r", t);
				var other = block(() -> out.push(SSet(r, coerceRhs(rhs(b), tyOf(b), t))));
				var isNull = Ir.isRef(lo.ty) ? EBin(RefEq, ELocal(lo), ENull(lo.ty)) : EInt(0);
				out.push(SIf(isNull, other, block(() -> out.push(SSet(r, coerce(ELocal(lo), lo.ty, t))))));
				return ELocal(r);
			case _:
				var xa = value(a);
				return arith(op, xa, tyOf(a), () -> {x: value(b), t: tyOf(b)}, tyOf(e), e);
		}
	}

	// a op b, with a already lowered; b lowered by the callback (after a)
	function arith(op:Binop, xa:Ex, ta:Ty, getB:() -> {x:Ex, t:Ty}, rt:Ty, e:TExpr):Ex {
		var before = out.length;
		var rb = getB();
		if (out.length != before && !isConst(xa) && !xa.match(ELocal(_))) {
			var lo = newLocal("s", ta);
			out.insert(before, SSet(lo, xa));
			xa = ELocal(lo);
		}
		var xb = rb.x, tb = rb.t;
		var isStr = (t:Ty) -> t.match(TRef(RStr));
		if (op == OpAdd && (rt.match(TRef(RStr)) || isStr(ta) || isStr(tb))) {
			var sa = toStr(xa, ta), sb = toStr(xb, tb);
			return temp(TRef(RStr), ECallHost(l.native("hx_str_concat"), [sa, sb], TRef(RStr)));
		}
		var num = (t:Ty) -> t == TI32 || t == TF64 || t == TBool || t == TI64 || t.match(TRef(RNull(_)));
		if (!num(ta) || !num(tb)) {
			// Dynamic arithmetic
			var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
			var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_op"), [EInt(opCode(op)), da, db], TRef(RAny)));
			return coerce(r, TRef(RAny), rt);
		}
		var scalar = (t:Ty) -> switch t {
			case TRef(RNull(s)): s;
			case _: t;
		};
		var sa = scalar(ta), sb = scalar(tb);
		if ((sa == TI64 || sb == TI64) && sa != TF64 && sb != TF64) {
			// Int64 (hxmc.I64 operators): the shift count stays an Int
			var shift = op == OpShl || op == OpShr || op == OpUShr;
			var la = coerce(xa, ta, TI64), lb = shift ? coerce(xb, tb, TI32) : coerce(xb, tb, TI64);
			var r = EBin(switch op {
				case OpAdd: LAdd;
				case OpSub: LSub;
				case OpMult: LMul;
				case OpDiv: LDiv;
				case OpMod: LMod;
				case OpAnd: LAnd;
				case OpOr: LOr;
				case OpXor: LXor;
				case OpShl: LShl;
				case OpShr: LShr;
				case OpUShr: LUShr;
				case _: fail("Int64 operator " + op, e);
			}, la, lb);
			return coerce(r, TI64, rt);
		}
		var isFloat = sa == TF64 || sb == TF64 || op == OpDiv || rt == TF64 && (op == OpAdd || op == OpSub || op == OpMult || op == OpMod);
		if (isFloat && !(op == OpAnd || op == OpOr || op == OpXor || op == OpShl || op == OpShr || op == OpUShr)) {
			var fa = coerce(xa, ta, TF64), fb = coerce(xb, tb, TF64);
			var r = EBin(switch op {
				case OpAdd: FAdd;
				case OpSub: FSub;
				case OpMult: FMul;
				case OpDiv: FDiv;
				case OpMod: FMod;
				case _: fail("float operator " + op, e);
			}, fa, fb);
			return coerce(r, TF64, rt);
		}
		var ia = coerce(xa, ta, TI32), ib = coerce(xb, tb, TI32);
		var r = EBin(switch op {
			case OpAdd: Add;
			case OpSub: Sub;
			case OpMult: Mul;
			case OpMod: Mod;
			case OpAnd: And;
			case OpOr: Or;
			case OpXor: Xor;
			case OpShl: Shl;
			case OpShr: Shr;
			case OpUShr: UShr;
			case _: fail("int operator " + op, e);
		}, ia, ib);
		return coerce(r, TI32, rt);
	}

	static function opCode(op:Binop):Int
		return switch op {
			case OpAdd: 0;
			case OpSub: 1;
			case OpMult: 2;
			case OpDiv: 3;
			case OpMod: 4;
			case OpAnd: 5;
			case OpOr: 6;
			case OpXor: 7;
			case OpShl: 8;
			case OpShr: 9;
			case OpUShr: 10;
			case _: -1;
		}

	// a == b as a TBool expression
	function equality(xa:Ex, ta:Ty, xb:Ex, tb:Ty, pureOnly:Bool):Ex {
		if (xb.match(ENull(_)) || xa.match(ENull(_))) {
			var x = xb.match(ENull(_)) ? xa : xb;
			var t = xb.match(ENull(_)) ? ta : tb;
			return Ir.isRef(t) ? EBin(RefEq, x, ENull(t)) : EInt(0);
		}
		var scalar = (t:Ty) -> t == TI32 || t == TBool || t == TF64 || t == TI64;
		if (scalar(ta) && scalar(tb)) {
			if (ta == TF64 || tb == TF64) return EBin(FEq, coerce(xa, ta, TF64), coerce(xb, tb, TF64));
			if (ta == TI64 || tb == TI64) return EBin(LEq, coerce(xa, ta, TI64), coerce(xb, tb, TI64));
			return EBin(Eq, xa, xb);
		}
		switch [ta, tb] {
			case [TRef(RStr), TRef(RStr)]:
				return ECallHost("hx_str_eq", [xa, xb], TBool);
			case [TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RAnon | RType | RNative(_)), TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RAnon | RType | RNative(_))]:
				return EBin(RefEq, xa, xb);
			case _:
				var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
				return ECallHost("hx_dyn_eq", [da, db], TBool);
		}
	}

	function compare(op:Binop, xa:Ex, ta:Ty, xb:Ex, tb:Ty):Ex {
		var scalar = (t:Ty) -> switch t {
			case TI32 | TBool | TF64 | TI64: t;
			case TRef(RNull(s)): s;
			case _: null;
		};
		var sa = scalar(ta), sb = scalar(tb);
		if (sa != null && sb != null) {
			if ((sa == TI64 || sb == TI64) && sa != TF64 && sb != TF64) {
				var la = coerce(xa, ta, TI64), lb = coerce(xb, tb, TI64);
				return EBin(switch op {
					case OpLt: LLt;
					case OpLte: LLe;
					case OpGt: LGt;
					case _: LGe;
				}, la, lb);
			}
			if (sa == TF64 || sb == TF64) {
				var fa = coerce(xa, ta, TF64), fb = coerce(xb, tb, TF64);
				return EBin(switch op {
					case OpLt: FLt;
					case OpLte: FLe;
					case OpGt: FGt;
					case _: FGe;
				}, fa, fb);
			}
			var ia = coerce(xa, ta, TI32), ib = coerce(xb, tb, TI32);
			return EBin(switch op {
				case OpLt: Lt;
				case OpLte: Le;
				case OpGt: Gt;
				case _: Ge;
			}, ia, ib);
		}
		var c = if (ta.match(TRef(RStr)) && tb.match(TRef(RStr))) ECallHost("hx_str_cmp", [xa, xb], TI32) else
			ECallHost("hx_dyn_cmp", [coerce(xa, ta, TRef(RAny)), coerce(xb, tb, TRef(RAny))], TI32);
		return EBin(switch op {
			case OpLt: Lt;
			case OpLte: Le;
			case OpGt: Gt;
			case _: Ge;
		}, c, EInt(0));
	}

	// lhs = value (or lhs = update(current)); returns the new value in ty(e.etype)
	function assign(lhs:TExpr, getValue:Null<() -> {x:Ex, t:Ty}>, e:TExpr, ?update:(Ex, Ty) -> Ex):Ex {
		inline function compute(cur:() -> Ex, curTy:Ty, to:Ty):Ex {
			if (update != null) return coerce(update(cur(), curTy), curTy, to);
			var v = getValue();
			return coerceRhs(v.x, v.t, to);
		}
		function pure(x:Ex, t:Ty):Ex
			return isConst(x) || x.match(ELocal(_)) ? x : ELocal(asLocal(x, t));
		var et = tyOf(e);
		switch strip(lhs).eexpr {
			case TLocal(v):
				var lo = local(v, e);
				var t = ty(v.vType);
				if (isBoxed(v)) {
					var x = pure(compute(() -> EBoxGet(t, ELocal(lo)), t, t), t);
					out.push(SBoxSet(t, ELocal(lo), x));
					return coerce(x, t, et);
				}
				var x = compute(() -> ELocal(lo), t, t);
				out.push(SSet(lo, x));
				return coerce(ELocal(lo), t, et);
			case TField(obj, FInstance(c, _, cf)) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface)):
				var ci = l.classInfo(c);
				var idx = ci.fieldIndex(cf.cfName);
				var t = ci.fields[idx].ty;
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EField(ci, idx, o), t, t), t);
				out.push(SSetField(ci, idx, o, x));
				return coerce(x, t, et);
			case TField(obj, FAnon(cf) | FInstance(_, _, cf)):
				var t = tyOf(lhs);
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EAnonGet(cf.cfName, t, o, null), t, t), t);
				out.push(SAnonSet(cf.cfName, t, o, x));
				return coerce(x, t, et);
			case TField(_, FStatic(c, cf)) if (!c.hasClassFlag(CExtern)):
				var g = l.staticVar(c, cf);
				var t = l.getProgram().globals[g].ty;
				var x = pure(compute(() -> EGlobal(g, t), t, t), t);
				out.push(SSetGlobal(g, x));
				return coerce(x, t, et);
			case TField(obj, FDynamic(name)):
				var o = ELocal(asLocal(coerce(value(obj), tyOf(obj), TRef(RAny)), TRef(RAny)));
				var t = TRef(RAny);
				var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_get"), [o, EStr(name)], t)), t, t), t);
				out.push(SExpr(ECallHost(l.native("hx_dyn_set"), [o, EStr(name), x], TVoid)));
				return coerce(x, t, et);
			case TArray(a, i):
				switch tyOf(a) {
					case TRef(RArr(elem)):
						var al = asLocal(value(a), tyOf(a));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var x = pure(compute(() -> EArrGet(elem, ELocal(al), ix), elem, elem), elem);
						out.push(SArrSet(elem, al, ix, x));
						return coerce(x, elem, et);
					case _:
						var t = TRef(RAny);
						var o = ELocal(asLocal(coerce(value(a), tyOf(a), t), t));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_aget"), [o, ix], t)), t, t), t);
						out.push(SExpr(ECallHost(l.native("hx_dyn_aset"), [o, ix, x], TVoid)));
						return coerce(x, t, et);
				}
			case _:
				return fail("assignment target " + strip(lhs).eexpr.getName(), e);
		}
	}

	function unop(op:Unop, flag:UnopFlag, e1:TExpr, e:TExpr):Ex {
		return switch op {
			case Increment | Decrement:
				var bop = op == Increment ? OpAdd : OpSub;
				var one = () -> {x: (EInt(1) : Ex), t: TI32};
				if (flag == Prefix) assign(e1, null, e, (cur, t) -> arith(bop, cur, t, one, t, e)) else {
					var t1 = tyOf(e1);
					var old = newLocal("old", t1);
					assign(e1, null, e, (cur, t) -> {
						out.push(SSet(old, cur));
						arith(bop, ELocal(old), t, one, t, e);
					});
					coerce(ELocal(old), t1, tyOf(e));
				}
			// the result has the representation of tyOf(e), which may be Null<T>
			case Not: coerce(ENot(cond(e1)), TBool, tyOf(e));
			case Neg:
				var t1 = tyOf(e1);
				var x = value(e1);
				switch tyOf(e) {
					case TF64: EConv(FNeg, coerce(x, t1, TF64));
					case TI64: EConv(LNeg, coerce(x, t1, TI64));
					case TI32: EBin(Sub, EInt(0), coerce(x, t1, TI32));
					case t = TRef(RNull(TI32)): coerce(EBin(Sub, EInt(0), coerce(x, t1, TI32)), TI32, t);
					case t: coerce(EConv(FNeg, coerce(x, t1, TF64)), TF64, t);
				}
			case NegBits: coerce(EBin(Xor, coerce(value(e1), tyOf(e1), TI32), EInt(-1)), TI32, tyOf(e));
			case Spread: fail("spread", e);
		}
	}

	// ---- calls

	function call(f:TExpr, cargs:Array<TExpr>, e:TExpr):Ex {
		var rt = tyOf(e);
		switch strip(f).eexpr {
			case TField(_, FStatic(_, cf)) if (cf.cfKind.match(Var(_))):
				return callValue(f, cargs, e);
			case TField(_, FStatic(c, cf)) if (c.hasClassFlag(CExtern) || cf.cfExpr == null):
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: fail("extern static " + cf.cfName + " is not a function", e);
				};
				var name = Lower.nativeName(c) + "_" + cf.cfName;
				var leaf = Lower.hasMeta(":hxmc.c", c.clMeta);
				if (leaf || Lower.hasMeta(":hxmc.rt", c.clMeta)) {
					// a C function by its own symbol: @:hxmc.c (hxmc.unsafe.LibC)
					// never reaches a GC point; @:hxmc.rt (the runtime's C
					// functions, hxmc.rt.C) may collect
					var n = Lower.metaArg(core.Meta.getOpt(Native, cf.cfMeta));
					name = n != null ? n : cf.cfName;
					if (leaf) C_EXTERNS.set(name, true);
					// @:hxmc.varargs(k): a variadic C function, its arguments from k on variadic
					var va = core.Meta.getOpt(Custom(":hxmc.varargs"), cf.cfMeta);
					if (va != null && va.exprs.length == 1)
						switch va.exprs[0].expr {
							case EConst(Int(k, _)): C_VARIADIC.set(name, Std.parseInt(k));
							case _:
						}
				}
				var intrinsic = intrinsicStatic(name, cargs, e);
				if (intrinsic != null) return intrinsic;
				var t = ty(s.ret);
				var xs = args(cargs, [for (a in s.args) ty(a.type)], null);
				return coerceRhs(ECallHost(l.native(name), xs, t), t, rt);
			case TField(obj, FDynamic("cca")) if (tyOf(obj).match(TRef(RStr)) && cargs.length == 1):
				// StringTools.fastCodeAt / unsafeCodeAt: `untyped s.cca(i)` (0 past the end, as on cpp/hl)
				var xs = operands([obj, cargs[0]]);
				return coerceRhs(ECallHost("String_charCodeAt_i", [xs[0], coerce(xs[1], tyOf(cargs[0]), TI32)], TI32), TI32, rt);
			case TField(_, FStatic(c, cf)) if (cf.cfKind.match(Method(MethDynamic)) && !c.hasClassFlag(CExtern)):
				var g = staticDynMethod(c, cf);
				var t = l.getProgram().globals[g].ty;
				var s = switch t { case TRef(RClos(s)): s; case _: fail("dynamic static " + cf.cfName + " is not a closure", e); };
				var cl = asLocal(EGlobal(g, t), t);
				var xs = args(cargs, s.args, null);
				return coerceRhs(ECallClos(s, ELocal(cl), xs), s.ret, rt);
			case TField(_, FStatic(c, cf)):
				var fn = l.staticFunc(c, cf);
				var xs = args(cargs, tys(fn), l.defaults.get(fn));
				return coerceRhs(ECall(fn, xs), fn.ret, rt);
			case TField({eexpr: TConst(TSuper)}, FInstance(c, _, cf)):
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("super." + cf.cfName + " without implementation", e);
				var fn = l.method(impl.cls, impl.field);
				var xs = args(cargs, tys(fn), l.defaults.get(fn), 1);
				return coerceRhs(ECall(fn, [(ELocal(thisLocal) : Ex)].concat(xs)), fn.ret, rt);
			case TConst(TSuper):
				var sup = l.superOf(self);
				while (sup != null && sup.clConstructor == null && sup.clSuper != null)
					sup = sup.clSuper.cls;
				if (sup == null || sup.clConstructor == null) return EInt(0);
				var fn = l.ctor(sup);
				var xs = args(cargs, tys(fn), l.defaults.get(fn), 1);
				out.push(SExpr(ECall(fn, [(ELocal(thisLocal) : Ex)].concat(xs))));
				return EInt(0);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "push"):
				var at = tyOf(obj);
				var elem = switch at {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands([obj, cargs[0]]);
				var al = asLocal(xs[0], at);
				out.push(SArrPush(elem, al, coerce(xs[1], tyOf(cargs[0]), elem)));
				return coerce(EArrLen(ELocal(al)), TI32, rt);
			case TField(obj, FInstance(c, _, cf)) if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array")):
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: fail("extern method " + cf.cfName + " is not a function", e);
				};
				var name = Lower.nativeName(c) + "_" + cf.cfName;
				var t = ty(s.ret);
				var xs = args([obj].concat(cargs), [tyOf(obj)].concat([for (a in s.args) ty(a.type)]), null);
				var intrinsic = intrinsicMethod(name, xs, tyOf(obj));
				if (intrinsic != null) return coerce(intrinsic, t, rt);
				return coerceRhs(ECallHost(l.native(name), xs, t), t, rt);
			case TField(obj, FInstance(c, _, cf)):
				switch cf.cfKind {
					case Var(_):
						// a field holding a function
						return callValue(f, cargs, e);
					case Method(MethDynamic) if (isDynMethod(c, cf)):
						var st = dynSlotTy(c, cf);
						var s = switch st { case TRef(RClos(s)): s; case _: fail("dynamic method " + cf.cfName + " is not a closure", e); };
						var cl = asLocal(dynMethod(obj, c, cf, e), st);
						var xs = args(cargs, s.args, null); // closure calls apply defaults in the callee
						return coerceRhs(ECallClos(s, ELocal(cl), xs), s.ret, rt);
					case Method(_):
				}
				if (l.needsDispatch(c, cf.cfName)) {
					var sig = dispatchSig(c, cf);
					var decl = l.rootDecl(c, cf.cfName);
					var impl = l.lookupMethod(c, cf.cfName);
					var ds = impl != null ? l.defaults.get(l.method(impl.cls, impl.field)) : null;
					var o = coerce(value(obj), tyOf(obj), TRef(RObj(l.rootClass())));
					var xs = args(cargs, sig.args, ds, 1);
					return coerceRhs(ECallDispatch(l.selector(cf.cfName, sig), sig, [o].concat(xs)), sig.ret, rt);
				}
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("no implementation of " + cf.cfName, e);
				var fn = l.method(impl.cls, impl.field);
				var o = value(obj);
				var xs = args(cargs, tys(fn), l.defaults.get(fn), 1);
				return coerceRhs(ECall(fn, [o].concat(xs)), fn.ret, rt);
			case TField(_, FEnum(en, ef)):
				var ci = l.ctorInfo(ef, en);
				var xs = args(cargs, ci.params, null);
				return coerceRhs(ENewEnum(ci, xs), TRef(RCtor(ci)), rt);
			case TField(obj, FAnon(cf) | FInstance(_, _, cf)) if (tyOf(f).match(TRef(RClos(_)))):
				var s = switch tyOf(f) {
					case TRef(RClos(s)): s;
					case _: null;
				};
				var o = asLocal(value(obj), tyOf(obj));
				var xs = args(cargs, s.args, null);
				return coerceRhs(ECallAnon(cf.cfName, s, ELocal(o), xs), s.ret, rt);
			case TField(obj, FDynamic(name)):
				var o = coerce(value(obj), tyOf(obj), TRef(RAny));
				var xs = args(cargs, [for (_ in cargs) TRef(RAny)], null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				var r = ECallHost(l.native("hx_dyn_call_field"), [o, EStr(name), arr], TRef(RAny));
				return coerceRhs(r, TRef(RAny), rt);
			case _:
				return callValue(f, cargs, e);
		}
	}

	// calling a function value: a closure, or Dynamic
	function callValue(f:TExpr, cargs:Array<TExpr>, e:TExpr):Ex {
		var rt = tyOf(e);
		switch tyOf(f) {
			case TRef(RClos(s)):
				var fx = value(f);
				var c = asLocal(fx, tyOf(f));
				var xs = args(cargs, s.args, null);
				return coerceRhs(ECallClos(s, ELocal(c), xs), s.ret, rt);
			case _:
				var fx = coerce(value(f), tyOf(f), TRef(RAny));
				var c = asLocal(fx, TRef(RAny));
				var xs = args(cargs, [for (_ in cargs) TRef(RAny)], null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				return coerceRhs(ECallHost(l.native("hx_dyn_call"), [ELocal(c), arr], TRef(RAny)), TRef(RAny), rt);
		}
	}

	// static externs lowered to IR operations instead of runtime calls
	function intrinsicStatic(name:String, cargs:Array<TExpr>, e:TExpr):Null<Ex> {
		return switch name {
			case "Std_int" if (cargs.length == 1):
				coerce(EConv(F2I, coerce(value(cargs[0]), tyOf(cargs[0]), TF64)), TI32, tyOf(e));
			case _: null;
		}
	}

	function intrinsicMethod(name:String, xs:Array<Ex>, selfTy:Ty):Null<Ex> {
		return null;
	}

	// ---- closures

	function closure(tf:TFunc, e:TExpr):Ex {
		var free = Boxing.freeVars(tf);
		var caps:Array<{id:Int, ty:Ty}> = [];
		var capVals = [];
		var captureLocals = [];
		for (v in free) {
			if (v == null) {
				if (thisLocal == null) continue;
				caps.push({id: -1, ty: thisLocal.ty});
				capVals.push(ELocal(thisLocal));
				captureLocals.push(new Local(-1, "this", thisLocal.ty));
				continue;
			}
			var lo = locals.get(v.vId);
			if (lo == null) continue;
			caps.push({id: v.vId, ty: lo.ty});
			capVals.push(ELocal(lo));
			captureLocals.push(new Local(v.vId, v.vName, lo.ty));
		}
		var sig = switch tyOf(e) {
			case TRef(RClos(s)): s;
			case _: l.getProgram().sig([for (a in tf.tfArgs) ty(a.variable.vType)], ty(tf.tfType));
		};
		var outerBoxed = boxed;
		var li = l.newLambda(sig, captureLocals, fl -> fl.runLambda(tf, copyMap(outerBoxed), caps), Lower.lambdaName(fi), fi.module);
		return ENewClos(li, capVals);
	}

	static function copyMap(m:Map<Int, Bool>):Map<Int, Bool> {
		var r = new Map();
		for (k in m.keys())
			r.set(k, true);
		return r;
	}
}

// Which locals are captured by a closure and also assigned after their
// declaration: those live in a heap box shared by all closures.
class Boxing {
	public static function analyze(body:TExpr, args:Array<TVar>):Map<Int, Bool> {
		var captured = new Map<Int, Bool>();
		var assigned = new Map<Int, Bool>();
		function walk(e:TExpr, depth:Int, declDepth:Map<Int, Int>) {
			switch e.eexpr {
				case TVar(v, init):
					declDepth.set(v.vId, depth);
					if (init != null) walk(init, depth, declDepth);
				case TLocal(v):
					var d = declDepth.get(v.vId);
					if (d != null && d < depth) captured.set(v.vId, true);
				case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, rhs):
					assigned.set(v.vId, true);
					var d = declDepth.get(v.vId);
					if (d != null && d < depth) captured.set(v.vId, true);
					walk(rhs, depth, declDepth);
				case TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
					assigned.set(v.vId, true);
					var d = declDepth.get(v.vId);
					if (d != null && d < depth) captured.set(v.vId, true);
				case TFunction(tf):
					for (a in tf.tfArgs)
						declDepth.set(a.variable.vId, depth + 1);
					walk(tf.tfExpr, depth + 1, declDepth);
				case TTry(b, cs):
					walk(b, depth, declDepth);
					for (c in cs) {
						declDepth.set(c.variable.vId, depth);
						walk(c.expr, depth, declDepth);
					}
				case _:
					core.Texpr.iter(x -> walk(x, depth, declDepth), e);
			}
		}
		var decl = new Map<Int, Int>();
		for (a in args)
			decl.set(a.vId, 0);
		walk(body, 0, decl);
		var r = new Map<Int, Bool>();
		for (id in captured.keys())
			if (assigned.exists(id)) r.set(id, true);
		return r;
	}

	// free variables of a closure literal; null stands for `this`
	public static function freeVars(tf:TFunc):Array<Null<TVar>> {
		var declared = new Map<Int, Bool>();
		for (a in tf.tfArgs)
			declared.set(a.variable.vId, true);
		var seen = new Map<Int, Bool>();
		var r:Array<Null<TVar>> = [];
		var usesThis = false;
		function walk(e:TExpr) {
			switch e.eexpr {
				case TVar(v, init):
					declared.set(v.vId, true);
					if (init != null) walk(init);
				case TLocal(v):
					if (!declared.exists(v.vId) && !seen.exists(v.vId)) {
						seen.set(v.vId, true);
						r.push(v);
					}
				case TConst(TThis | TSuper):
					usesThis = true;
				case TFunction(tf2):
					for (a in tf2.tfArgs)
						declared.set(a.variable.vId, true);
					walk(tf2.tfExpr);
				case TTry(b, cs):
					walk(b);
					for (c in cs) {
						declared.set(c.variable.vId, true);
						walk(c.expr);
					}
				case _:
					core.Texpr.iter(walk, e);
			}
		}
		walk(tf.tfExpr);
		if (usesThis) r.unshift(null);
		return r;
	}
}
