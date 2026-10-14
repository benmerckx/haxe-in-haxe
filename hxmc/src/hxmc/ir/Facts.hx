package hxmc.ir;

import hxmc.ir.Ir;

// The program-wide preparation hxmc's code generator and data share
// (hxmc.Prep): the part of hxc's C emitter (EmitC) that does not write C,
// copied when hxmc separated from hxc (hxmc/README.md, "Origin"). It names
// functions (F_<name>), string literals (S_<hash>) and program-wide numbers
// (TY_*, FID_*, SIG_*, GI_*, DSP_*: absolute symbols in hxmc's objects), lays
// out objects, assigns type indices and field ids, finds the functions that
// never reach a GC point and marks the statements whose only GC point is a
// slow path (SCold). The runtime (hxmc/rt) agrees on every number this way.
class Facts {
	public static inline var T_FIRST = 32;

	public var p:Program;
	public var strNames = new Map<String, String>(); // literal -> S_<hash of its content>
	public var strOrder:Array<String> = [];
	public var strByName = new Map<String, String>();
	public var fids = new Map<String, Int>();
	public var fieldNames:Array<String> = [];
	var cnames = new Map<FuncInfo, String>();
	var usedCNames = new Map<String, Bool>();
	public var byCName = new Map<String, FuncInfo>();
	public var types:Array<TypeEntry> = [];
	public var boundTypes = new Map<Int, Int>(); // sig -> type index of its bound-method closures

	// Function bodies refer to program-wide numbers (type indices, field ids,
	// signature ids, globals, dispatch selectors) by name: TY_*, FID_*, SIG_*,
	// GI_* (index into rt_globals), G_* (scalar globals), DSP_* (dispatch rows),
	// S_* (string literals, named by a hash of their content). Names stay the
	// same when unrelated code changes, so a module's code does not change when
	// the numbering does.
	public var ids = new Map<String, Int>(); // id name -> value
	public var idOrder:Array<String> = [];
	public var typeNames:Array<String> = []; // type index -> its name (program types: TY_* ids)
	public var fidNames = new Map<String, String>();
	public var sigNames:Array<String> = [];
	public var globalNames:Array<String> = [];
	public var selNames:Array<String> = [];

	public function new(p:Program) {
		this.p = p;
		for (f in p.funcs)
			byCName.set(cname(f), f);
		findNoGc();
		markCold();
		assignTypes();
		collectNames();
		assignNames();
	}

	// ---- names

	static function ident(s:String):String {
		var r = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			r.addChar((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code ? c : "_".code);
		}
		return r.toString();
	}

	public function cname(f:FuncInfo):String {
		var n = cnames.get(f);
		if (n != null) return n;
		if (f.cSymbol != null) {
			// @:hxmc.export: the runtime's C code calls it by its C name, which
			// is the entry that DataGen.exportEntries wraps around it (stack
			// maps: StackMaps.entry); the program's code calls it directly
			if (usedCNames.exists(f.cSymbol)) throw "hxmc: two functions export " + f.cSymbol;
			usedCNames.set(f.cSymbol, true);
			n = f.cSymbol + "$hx";
			usedCNames.set(n, true);
			cnames.set(f, n);
			return n;
		}
		var base = "F_" + ident(f.name);
		n = base;
		var i = 1;
		while (usedCNames.exists(n))
			n = base + "_" + i++;
		usedCNames.set(n, true);
		cnames.set(f, n);
		return n;
	}

	public function fid(name:String):Int {
		var f = fids.get(name);
		if (f == null) throw "field name not collected: " + name;
		return f;
	}


	// registers a literal: its symbol is a hash of its UTF-16 units (an ASCII
	// rendering: injective)
	public function str(s:String):String {
		var n = strNames.get(s);
		if (n == null) {
			n = "S_" + haxe.crypto.Md5.encode([for (i in 0...s.length) StringTools.hex(s.charCodeAt(i))].join(",")).substr(0, 16);
			if (strByName.exists(n)) throw "string literal hash collision: " + n;
			strByName.set(n, s);
			strNames.set(s, n);
			strOrder.push(s);
		}
		return n;
	}

	// Names for keys: `prefix` + the key as an identifier; keys mapping to the
	// same identifier get a suffix by their sorted rank. Values become ids.
	function nameIds(prefix:String, keys:Array<String>, values:Null<Array<Int>>):Array<String> {
		var cands = [for (k in keys) prefix + ident(k)];
		var groups = new Map<String, Array<String>>();
		for (i in 0...keys.length) {
			var g = groups.get(cands[i]);
			if (g == null) groups.set(cands[i], g = []);
			g.push(keys[i]);
		}
		var names = [];
		for (i in 0...keys.length) {
			var g = groups.get(cands[i]);
			var n = cands[i];
			if (g.length > 1) {
				g.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
				n += "_" + g.indexOf(keys[i]);
			}
			names.push(n);
			if (values != null) {
				if (ids.exists(n)) throw "duplicate name " + n;
				ids.set(n, values[i]);
				idOrder.push(n);
			}
		}
		return names;
	}

	function assignNames() {
		var keys = [], vals = [];
		for (i in T_FIRST...types.length) {
			keys.push(types[i].key);
			vals.push(i);
		}
		var tn = nameIds("TY_", keys, vals);
		typeNames = [for (i in 0...types.length) i < T_FIRST ? Std.string(i) : tn[i - T_FIRST]];
		var fn = nameIds("FID_", fieldNames, [for (i in 0...fieldNames.length) i]);
		for (i in 0...fieldNames.length)
			fidNames.set(fieldNames[i], fn[i]);
		sigNames = nameIds("SIG_", [for (s in p.sigs) s.key], [for (s in p.sigs) s.id]);
		globalNames = nameIds("GI_", [for (g in p.globals) g.name], null);
		// reference globals are slots of rt_globals (GI_*: the index); scalar ones are variables (G_*)
		for (i in 0...p.globals.length)
			if (Ir.isRef(p.globals[i].ty)) {
				if (ids.exists(globalNames[i])) throw "duplicate name " + globalNames[i];
				ids.set(globalNames[i], i);
				idOrder.push(globalNames[i]);
			}
		selNames = nameIds("DSP_", [for (s in p.selectors) s.name], null);
	}

	// ---- types

	function addType(t:TypeEntry):Int {
		types.push(t);
		return types.length - 1;
	}

	static function entry(name:String, tk:String, slots:Array<Null<Ty>>, key:String):TypeEntry
		return {
			key: key,
			name: name,
			tk: tk,
			sup: -1,
			slots: slots,
			fields: [],
			methods: [],
			ifaces: [],
			tag: 0,
			ctors: []
		};

	// Field layout of classes and anonymous structures: fields in order, one
	// 8-byte slot each, except that Int/Bool fields are packed two per slot
	// (the second fills the free half of the previous one). A class's fields
	// start with its superclass's, so the layout of a subclass extends the
	// superclass's. Returns per field its location (see `at`); appends the
	// physical slots (for the pointer map) to `slots`.
	static function layout(slots:Array<Null<Ty>>, tys:Array<Ty>):Array<Int> {
		var locs = [], half = -1;
		for (t in tys)
			switch t {
				case TI32 | TBool:
					if (half >= 0) {
						locs.push(2 * half + 1);
						half = -1;
					} else {
						half = slots.length;
						locs.push(2 * half);
						slots.push(TI32);
					}
				case _:
					locs.push(slots.length);
					slots.push(t);
			}
		return locs;
	}

	// the location of a value of type t in slot `slot` of an unpacked layout:
	// Int/Bool are addressed by 4-byte index (FH), the rest by slot
	static function at(slot:Int, t:Ty):Int
		return t.match(TI32 | TBool) ? 2 * slot : slot;

	function assignTypes() {
		var rtNames = ["None", "String", "Int", "Float", "Bool", "Array", "ArrayData", "ArrayData", "haxe.io.Bytes", "haxe.io.BytesBuffer", "StringBuf", "Ref", "Ref", "Ref", "Class", "Overflow", "Native", "ArrayIterator", "haxe.Int64"];
		var rtSlots:Array<Array<Null<Ty>>> = [[], [], [TI32], [TF64], [TBool], [TI32, TRef(RAny)], [], [], [], [TI32, TRef(RAny)], [TI32, TRef(RAny)], [TRef(RAny)], [TI32], [TF64], [TI32], [], [], [TRef(RAny), TI32], [TI64]];
		for (i in 0...T_FIRST)
			addType(entry(i < rtNames.length ? rtNames[i] : "Reserved", "TK_RUNTIME", i < rtSlots.length ? rtSlots[i] : [], "rt" + i));
		for (c in p.classes) {
			var slots:Array<Null<Ty>> = [];
			c.locs = layout(slots, [for (f in c.fields) f.ty]);
			c.nslots = slots.length;
			var t = entry(c.name, "TK_CLASS", slots, c.name);
			t.fields = [for (i in 0...c.fields.length) {name: c.fields[i].name, slot: c.locs[i], ty: c.fields[i].ty}];
			c.tindex = addType(t);
		}
		for (c in p.classes)
			types[c.tindex].sup = c.sup == null ? -1 : c.sup.tindex;
		for (c in p.interfaces)
			c.tindex = addType(entry(c.name, "TK_INTERFACE", [], c.name));
		for (c in p.classes)
			types[c.tindex].ifaces = [for (i in c.ifaces) i.tindex];
		for (e in p.enums) {
			var et = entry(e.name, "TK_ENUM", [], e.name);
			et.tag = e.ctors.length;
			e.tindex = addType(et);
			for (c in e.ctors) {
				// no tag slot: the constructor is the type index (rt.h)
				var slots:Array<Null<Ty>> = [for (pt in c.params) pt];
				var t = entry(c.name, "TK_CTOR", slots, e.name + "." + c.name);
				t.sup = e.tindex;
				t.tag = c.tag;
				t.fields = [for (i in 0...c.params.length) {name: c.paramNames[i], slot: at(i, c.params[i]), ty: c.params[i]}];
				c.tindex = addType(t);
			}
			types[e.tindex].ctors = [for (c in e.ctors) c.tindex];
		}
		for (s in p.shapes) {
			var slots:Array<Null<Ty>> = [TRef(RAny)];
			s.locs = layout(slots, [for (f in s.fields) f.ty]);
			s.nslots = slots.length;
			var t = entry("{}", "TK_ANON", slots, "anon." + haxe.crypto.Md5.encode([for (f in s.fields) f.name + ":" + Ir.repr(f.ty)].join(",")).substr(0, 16));
			t.fields = [for (i in 0...s.fields.length) {name: s.fields[i].name, slot: s.locs[i], ty: s.fields[i].ty}];
			s.tindex = addType(t);
		}
		for (l in p.lambdas) {
			var slots:Array<Null<Ty>> = [TI32];
			for (c in l.captures)
				slots.push(c.ty);
			var t = entry("<closure>", "TK_CLOSURE", slots, "clos." + cname(l.fn));
			t.sup = l.sig.id;
			l.tindex = addType(t);
		}
		// class methods for structural and dynamic access: the effective implementation of every name
		for (c in p.classes) {
			var seen = new Map<String, Bool>();
			var k = c;
			var ms = [];
			while (k != null) {
				for (name => m in k.methods)
					if (!seen.exists(name)) {
						seen.set(name, true);
						var sig = p.sig([for (i in 1...m.args.length) m.args[i].ty], m.ret);
						ms.push({name: name, fn: cname(m), sig: sig.id});
					}
				k = k.sup;
			}
			types[c.tindex].methods = ms;
		}
		// the runtime's array iterator (Iterable.iterator() on an Array): methods in rt_dyn.c
		types[17].methods = [
			{name: "hasNext", fn: "hx_arrayiter_hasNext", sig: p.sig([], TBool).id},
			{name: "next", fn: "hx_arrayiter_next", sig: p.sig([], TRef(RAny)).id}
		];
		// one bound-method closure type per signature: code, this, method
		for (s in p.sigs) {
			var t = entry("<bound>", "TK_BOUND", [TI32, TRef(RAny), TI32], "bound." + s.key);
			t.sup = s.id;
			boundTypes.set(s.id, addType(t));
		}
	}

	// ---- field names: collected from the whole program, sorted, so the runtime can search them

	function collectNames() {
		var names = new Map<String, Bool>();
		for (t in types) {
			for (f in t.fields)
				names.set(f.name, true);
			for (m in t.methods)
				names.set(m.name, true);
		}
		for (e in p.enums)
			for (c in e.ctors)
				names.set(c.name, true);
		for (c in p.classes)
			if (c.statics != null)
				for (s in c.statics)
					names.set(s.name, true);
		function ex(e:Ex) {
			switch e {
				case EAnonGet(n, _, o, _):
					names.set(n, true);
					ex(o);
				case ECallAnon(n, _, o, args):
					names.set(n, true);
					ex(o);
					for (a in args)
						ex(a);
				case ECallHost("hx_dyn_get" | "hx_dyn_set" | "hx_dyn_call_field", args, _) if (args[1].match(EStr(_))):
					switch args[1] {
						case EStr(n): names.set(n, true);
						case _:
					}
					for (a in args)
						ex(a);
				case _:
					iterEx(ex, e);
			}
		}
		function st(s:Stmt) {
			switch s {
				case SAnonSet(n, _, o, v):
					names.set(n, true);
					ex(o);
					ex(v);
				case _:
					iterStmt(st, ex, s);
			}
		}
		for (f in p.funcs)
			for (s in f.body)
				st(s);
		fieldNames = [for (k in names.keys()) k];
		fieldNames.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (i in 0...fieldNames.length)
			fids.set(fieldNames[i], i);
	}

	public static function iterEx(f:Ex->Void, e:Ex) {
		switch e {
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | ELocal(_) | EGlobal(_, _) | EType(_):
			case EBin(_, a, b):
				f(a);
				f(b);
			case ENot(a) | EConv(_, a) | EBox(_, a) | EUnbox(_, a) | EField(_, _, a) | EAnonGet(_, _, a, _) | ECast(_, a) | EInstOf(_, a) | EEnumTag(a, _) | EEnumParam(_, _, a) | EArrLen(a) | EBoxGet(_, a) | ECapture(_, _, a) | ENewBox(_, a):
				f(a);
			case EArrGet(_, a, i) | EArrGetU(_, a, i):
				f(a);
				f(i);
			case ECall(_, args) | ECallDispatch(_, _, args) | ECallHost(_, args, _) | ENewEnum(_, args) | ENewArr(_, args) | ENewClos(_, args) | ENewAnon(_, args):
				for (a in args)
					f(a);
			case ECallClos(_, c, args) | ECallAnon(_, _, c, args):
				f(c);
				for (a in args)
					f(a);
			case ENewObj(_):
		}
	}

	public static function iterStmt(fs:Stmt->Void, fe:Ex->Void, s:Stmt) {
		switch s {
			case SSet(_, e) | SExpr(e) | SThrow(e) | SSetGlobal(_, e):
				fe(e);
			case SSetField(_, _, o, v) | SAnonSet(_, _, o, v) | SBoxSet(_, o, v):
				fe(o);
				fe(v);
			case SArrSet(_, _, i, v):
				fe(i);
				fe(v);
			case SArrPush(_, _, v):
				fe(v);
			case SIf(c, a, b):
				fe(c);
				for (x in a)
					fs(x);
				for (x in b)
					fs(x);
			case SLoop(body):
				for (x in body)
					fs(x);
			case SCold(_, x):
				fs(x);
			case SBreak | SContinue:
			case SSwitch(e, cases, def):
				fe(e);
				for (c in cases)
					for (x in c.body)
						fs(x);
				for (x in def)
					fs(x);
			case SReturn(e):
				if (e != null) fe(e);
			case STry(body, catches):
				for (x in body)
					fs(x);
				for (c in catches) {
					if (c.test != null) fe(c.test(ELocal(c.l)));
					for (x in c.body)
						fs(x);
				}
		}
	}

	// Functions that never reach a GC point: no allocation, no impure native,
	// no throw, and direct calls only to such functions (the largest such set:
	// candidates are dropped until none calls a dropped one, so recursion
	// stays in). A call to one keeps the caller's references in registers, and
	// one needs no frame. They also never stop at a safepoint (rt_thread.c),
	// so another thread's collection cannot move objects under them.
	function findNoGc() {
		var cand = new Map<FuncInfo, Bool>();
		for (f in p.funcs)
			if (!f.hasTry) cand.set(f, true);
		function exOk(e:Ex):Bool {
			var ok = switch e {
				case ECall(g, _): cand.exists(g);
				case _: GcPoints.gcPoint(e) == 0;
			}
			if (ok) Facts.iterEx(x -> if (ok && !exOk(x)) ok = false, e);
			return ok;
		}
		function stOk(s:Stmt):Bool {
			var ok = switch s {
				case SArrSet(_) | SArrPush(_) | SAnonSet(_) | SThrow(_) | STry(_): false;
				case _: true;
			}
			if (ok) Facts.iterStmt(x -> if (ok && !stOk(x)) ok = false, x -> if (ok && !exOk(x)) ok = false, s);
			return ok;
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (f in p.funcs)
				if (cand.exists(f) && !Lambda.foreach(f.body, stOk)) {
					cand.remove(f);
					changed = true;
				}
		}
		for (f in p.funcs)
			f.noGc = cand.exists(f);
		// the functions that enter a safe region, or call one that does (one
		// walk of the bodies: the direct ones and the callers, then the
		// callers' closure)
		var callers = new Map<FuncInfo, Array<FuncInfo>>();
		var work:Array<FuncInfo> = [];
		for (f in p.funcs) {
			var here = false;
			function ex(e:Ex) {
				switch e {
					case ECallHost("rt_blocking_enter", _, _): here = true;
					case ECall(g, _):
						var cs = callers.get(g);
						if (cs == null) callers.set(g, cs = []);
						if (cs.length == 0 || cs[cs.length - 1] != f) cs.push(f);
					case _:
				}
				Facts.iterEx(ex, e);
			}
			function st(s:Stmt)
				Facts.iterStmt(st, ex, s);
			for (s in f.body)
				st(s);
			if (here) {
				f.blocksHere = f.blocks = true;
				work.push(f);
			}
		}
		while (work.length > 0) {
			var g = work.pop();
			var cs = callers.get(g);
			if (cs != null)
				for (c in cs)
					if (!c.blocks) {
						c.blocks = true;
						work.push(c);
					}
		}
		// @:hxmc.noGc: a promise the runtime's Haxe code relies on (raw
		// addresses kept across calls), checked
		for (f in p.funcs)
			if (f.declNoGc && !f.noGc) throw '${f.name} is declared @:hxmc.noGc but reaches a GC point: ${noGcCulprit(f, cand)}';
	}

	// what keeps `f` from being a no-GC function (the first offending
	// statement or expression), for the error of findNoGc
	function noGcCulprit(f:FuncInfo, cand:Map<FuncInfo, Bool>):String {
		if (f.hasTry) return "it has a try block";
		var why:Null<String> = null;
		function exWhy(e:Ex) {
			if (why != null) return;
			switch e {
				case ECall(g, _) if (!cand.exists(g)): why = "it calls " + g.name + (g.declNoGc ? "" : " (not a no-GC function)");
				case ECall(_):
				case ECallHost(n, _, _) if (GcPoints.gcPoint(e) > 0): why = "it calls the runtime's " + n;
				case _ if (GcPoints.gcPoint(e) > 0): why = "it allocates or calls dynamically (" + e.getName() + ")";
				case _:
			}
			Facts.iterEx(exWhy, e);
		}
		function stWhy(s:Stmt) {
			if (why != null) return;
			switch s {
				case SArrSet(_) | SArrPush(_): why = "it stores into an array (the slow path grows it)";
				case SAnonSet(_): why = "it sets a structural field (the slow path may allocate)";
				case SThrow(_): why = "it throws";
				case STry(_): why = "it has a try block";
				case _:
			}
			Facts.iterStmt(stWhy, exWhy, s);
		}
		for (s in f.body)
			stWhy(s);
		return why != null ? why : "a callee reaches one";
	}

	// Wraps the statements whose only GC point is an allocation or an array
	// store's slow path in SCold (functions without try blocks)
	function markCold() {
		var next = 0;
		function gcFree(e:Ex):Bool
			return GcPoints.gcPoint(e) == 0 && !GcPoints.nestedGc(e);
		function mark(ss:Array<Stmt>) {
			for (k in 0...ss.length) {
				var st = ss[k];
				switch st {
					case SArrSet(_, _, ix, v) if (gcFree(ix) && gcFree(v)):
						ss[k] = SCold(next++, st);
					case SArrPush(_, _, v) if (gcFree(v)):
						ss[k] = SCold(next++, st);
					case SSet(_, e) if (e.match(ENewObj(_) | ENewEnum(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_)) && !GcPoints.nestedGc(e)):
						ss[k] = SCold(next++, st);
					case SIf(_, a, b):
						mark(a);
						mark(b);
					case SLoop(body):
						mark(body);
					case SSwitch(_, cases, def):
						for (c in cases)
							mark(c.body);
						mark(def);
					case _:
				}
			}
		}
		for (f in p.funcs)
			if (!f.hasTry) mark(f.body);
	}

	public function scalarGlobal(g:Int):String
		return "G_" + globalNames[g].substr(3);
}

typedef TypeEntry = {
	key:String, // stable across unrelated changes: its name (TY_*) derives from it
	name:String,
	tk:String,
	sup:Int,
	slots:Array<Null<Ty>>,
	fields:Array<{name:String, slot:Int, ty:Ty}>,
	methods:Array<{name:String, fn:String, sig:Int}>,
	ifaces:Array<Int>,
	tag:Int,
	ctors:Array<Int>
};

// GC points (the part of hxc's EmitC.Roots that hxmc's own shadow-stack
// analysis, hxmc.Roots, builds on)
class GcPoints {
	// GC point of an expression; 2: operands are read after an allocation
	public static function gcPoint(e:Ex):Int
		return switch e {
			case ECall(f, _) if (f.noGc): 0;
			case ECall(_) | ECallDispatch(_) | ECallClos(_) | ECallAnon(_) | EBox(_) | EAnonGet(_) | EArrGet(TRef(RAny), _, _) | EArrGetU(TRef(RAny), _, _): 1;
			case ECallHost(n, _, _): FnLower.noGcHost(n) ? 0 : 1;
			case ENewObj(_) | ENewEnum(_) | ENewArr(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_): 2;
			case _: 0;
		}

	// a GC point nested inside an expression's operands
	public static function nestedGc(e:Ex):Bool {
		var r = false;
		Facts.iterEx(x -> if (gcPoint(x) > 0 || nestedGc(x)) r = true, e);
		return r;
	}
}
