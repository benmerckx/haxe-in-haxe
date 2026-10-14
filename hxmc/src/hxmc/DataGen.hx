package hxmc;

import hxmc.ir.Facts;
import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.Obj;

// The program's data, as sections of an Obj: the type table rt_types
// and its field/method/static/pointer-map arrays, dispatch rows, field
// names, string literals, scalar globals, the per-signature trampolines
// (DYN<s>, BT<s>) and main.
@:access(hxmc.ir.Facts)
@:access(hxmc.MirBuild)
class DataGen {
	var prep:Prep;
	var e:Facts;
	var p:Program;
	var obj:Obj;
	var data:Section;
	var rodata:Section;
	var bss:Section;
	var compile:MFunc->Void;
	var abi:Abi;
	var cstrs = new Map<String, Symbol>();
	var ncstr = 0;
	var nlocal = 0;

	public function new(prep:Prep, abi:Abi, obj:Obj, compile:MFunc->Void) {
		this.prep = prep;
		this.abi = abi;
		e = prep.e;
		p = prep.p;
		this.obj = obj;
		this.compile = compile;
		data = obj.section(".data", Data, 16);
		rodata = obj.section(".rodata", RoData, 16);
		bss = obj.section(".bss", Bss, 16);
	}

	// ---- helpers

	function ptr(sec:Section, sym:String, addend = 0) {
		sec.relocs.push(new Reloc(sec.buf.len, RAbs64, obj.sym(sym), addend));
		sec.buf.u64(0, 0);
	}

	function ptrSym(sec:Section, sym:Symbol, addend = 0) {
		sec.relocs.push(new Reloc(sec.buf.len, RAbs64, sym, addend));
		sec.buf.u64(0, 0);
	}

	// a NUL-terminated UTF-8 string in .rodata
	function cstr(s:String):Symbol {
		var r = cstrs.get(s);
		if (r != null) return r;
		var off = rodata.buf.len;
		rodata.buf.str(s);
		rodata.buf.u8(0);
		r = obj.define(".Lstr" + ncstr++, rodata, off, 0, false);
		cstrs.set(s, r);
		return r;
	}

	function begin(sec:Section, name:String, align:Int, global:Bool):Symbol {
		sec.buf.align(align);
		return obj.define(name, sec, sec.buf.len, 0, global);
	}

	function local(sec:Section, prefix:String, align:Int):Symbol
		return begin(sec, ".L" + prefix + nlocal++, align, false);

	function int32Global(name:String, v:Int) {
		rodata.buf.align(4);
		obj.define(name, rodata, rodata.buf.len, 4, true);
		rodata.buf.u32(v);
	}

	function bssGlobal(name:String, size:Int, align:Int, global = true) {
		bss.bssSize = (bss.bssSize + align - 1) & ~(align - 1);
		obj.define(name, bss, bss.bssSize, size, global);
		bss.bssSize += size;
	}

	static function kindChar(t:Ty):Int
		return switch t {
			case TI32: "i".code;
			case TBool: "b".code;
			case TF64: "f".code;
			case TI64: "l".code;
			case _: "p".code;
		};

	static function tk(s:String):Int
		return ["TK_RUNTIME", "TK_CLASS", "TK_INTERFACE", "TK_ENUM", "TK_CTOR", "TK_ANON", "TK_CLOSURE", "TK_BOUND"].indexOf(s);

	// ---- everything

	public function run() {
		ids();
		strings();
		fieldNames();
		signatures();
		globals();
		types();
		dispatch();
		mainBody();
		exportEntries();
	}

	// the entries C calls the exported runtime functions by (their C names,
	// Facts.cname): a call of the Haxe function between saving and
	// restoring the stack maps' record (StackMaps.entry); dropped with it
	// by the linker when nothing calls it
	function exportEntries() {
		var names = [for (n in prep.exports.keys()) n];
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in names) {
			var f = prep.exports.get(n);
			var params = [for (a in f.args) MirBuild.mty(a.ty)];
			var ret = MirBuild.mty(f.ret);
			var mf = MirBuild.synthetic(prep, abi, n, params, ret, (b, ps) -> {
				var r = b.call(e.cname(f), ps, ret);
				b.ret(ret == Void ? -1 : r);
			});
			StackMaps.entry(mf);
			mf.section = Link.GC_PREFIX + n;
			compile(mf);
		}
	}

	// the program-wide numbers as absolute symbols (Prep.tySym...)
	function ids() {
		for (n in e.idOrder)
			obj.defineAbs(n, e.ids.get(n));
		for (g in 0...p.globals.length)
			if (Ir.isRef(p.globals[g].ty)) obj.defineAbs(prep.globalOffSym(g), 8 * g);
		for (c in p.classes)
			obj.defineAbs(prep.spanSym(c), c.lastDescendant - c.id);
		// the type objects: slots of rt_type_objs (bss, see types())
		bss.bssSize = (bss.bssSize + 15) & ~15;
		typeObjs = bss.bssSize;
		var n = e.types.length;
		obj.define("rt_type_objs", bss, typeObjs, 8 * 2 * n, true);
		for (t in 0...n)
			obj.define(prep.typeObjSym(t), bss, typeObjs + 8 * (2 * t + 1), 8, true);
		bss.bssSize += 8 * 2 * n;
	}

	var typeObjs = 0;

	function strings() {
		for (s in e.strOrder) {
			var n = e.strNames.get(s);
			var units = [for (i in 0...s.length) s.charCodeAt(i)];
			var nslots = Std.int((8 + 2 * units.length + 7) / 8);
			data.buf.align(8);
			obj.define(n, data, data.buf.len, 8 + 8 + 2 * (units.length + 1), true);
			// MKHDR(nslots, K_RAW, T_STRING)
			data.buf.u64(nslots | (Abi.K_RAW << 28), 1);
			data.buf.u32(s.length);
			data.buf.u32(0);
			for (u in units)
				data.buf.u16(u);
			data.buf.u16(0);
		}
	}

	function fieldNames() {
		var names = e.fieldNames;
		var syms = [for (n in names) cstr(n)];
		begin(data, "rt_field_names", 8, true);
		for (s in syms)
			ptrSym(data, s);
		int32Global("rt_nfield_names", names.length);
	}

	function signatures() {
		for (s in p.sigs) {
			compile(dynTrampoline(s));
			compile(boundTrampoline(s));
		}
		begin(data, "rt_dyncalls", 8, true);
		for (s in p.sigs)
			ptr(data, "DYN" + s.id);
		var keys = [for (s in p.sigs) cstr(s.key)];
		begin(data, "rt_sig_keys", 8, true);
		for (k in keys)
			ptrSym(data, k);
		int32Global("rt_nsigs", p.sigs.length);
		begin(data, "rt_bound_tramps", 8, true);
		for (s in p.sigs)
			ptr(data, "BT" + s.id);
		rodata.buf.align(4);
		obj.define("rt_bound_types", rodata, rodata.buf.len, 4 * p.sigs.length, true);
		for (s in p.sigs)
			rodata.buf.u32(e.boundTypes.get(s.id));
	}

	// DYN<s>(c, args): calls closure c with the boxed arguments args[i], boxes the result
	function dynTrampoline(s:SigInfo):MFunc {
		return MirBuild.synthetic(prep, abi, "DYN" + s.id, [I64, I64], I64, (b, ps) -> {
			var c = ps[0], args = ps[1];
			var xs = [c];
			for (i in 0...s.args.length)
				xs.push(b.unboxTo(s.args[i], b.load(I64, 8, args, 8 * i)));
			var fp = b.load(I64, 8, c, 0);
			var r = b.callInd(fp, xs, MirBuild.mty(s.ret), [I64].concat([for (t in s.args) MirBuild.mty(t)]));
			b.ret(s.ret == TVoid ? b.lconst(0, 0) : b.boxFrom(s.ret, r));
		});
	}

	// BT<s>(c, args...): the code of bound-method closures: FP(c, 2)(FP(c, 1), args...)
	function boundTrampoline(s:SigInfo):MFunc {
		var params:Array<MTy> = [I64].concat([for (t in s.args) MirBuild.mty(t)]);
		return MirBuild.synthetic(prep, abi, "BT" + s.id, params, MirBuild.mty(s.ret), (b, ps) -> {
			var c = ps[0];
			var fp = b.load(I64, 8, c, 16);
			var self = b.load(I64, 8, c, 8);
			var r = b.callInd(fp, [self].concat(ps.slice(1)), MirBuild.mty(s.ret), params);
			b.ret(s.ret == TVoid ? -1 : r);
		});
	}

	function globals() {
		for (i in 0...p.globals.length) {
			var t = p.globals[i].ty;
			if (!Ir.isRef(t)) bssGlobal(e.scalarGlobal(i), t == TI32 || t == TBool ? 4 : 8, 8);
		}
	}

	function types() {
		var types:Array<hxmc.ir.Facts.TypeEntry> = e.types;
		var staticsOf = new Map<Int, Array<{name:String, clos:Null<LambdaInfo>, global:Int}>>();
		for (c in p.classes)
			if (c.statics != null && c.statics.length > 0) staticsOf.set(c.tindex, c.statics);
		// the arrays each entry points to, then the table
		var entries = [];
		for (i in 0...types.length) {
			var t = types[i];
			var ss = staticsOf.get(i);
			var ssSym = null, pmSym = null, fsSym = null, msSym = null, ifSym = null, ctSym = null;
			if (ss != null) {
				ss = ss.copy();
				ss.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
				ssSym = local(data, "ss", 8);
				for (x in ss) {
					data.buf.u32(e.fid(x.name));
					if (x.clos != null) {
						data.buf.u32("c".code);
						data.buf.u32(x.clos.tindex);
						data.buf.u32(0);
						ptr(data, e.cname(x.clos.fn));
					} else {
						var gt = p.globals[x.global].ty;
						if (Ir.isRef(gt)) {
							data.buf.u32("p".code);
							data.buf.u32(x.global);
							data.buf.u32(0);
							data.buf.u64(0, 0);
						} else {
							data.buf.u32(kindChar(gt));
							data.buf.u32(-1);
							data.buf.u32(0);
							ptr(data, e.scalarGlobal(x.global));
						}
					}
				}
			}
			var n = t.slots.length;
			var nwords = Std.int((n + 63) / 64);
			if (nwords > 0) {
				pmSym = local(rodata, "pm", 8);
				for (w in 0...nwords) {
					var lo = 0, hi = 0;
					for (j in w * 64...Std.int(Math.min(n, w * 64 + 64))) {
						var s = t.slots[j];
						if (s != null && Ir.isRef(s)) {
							var k = j - w * 64;
							if (k < 32) lo |= 1 << k else hi |= 1 << (k - 32);
						}
					}
					rodata.buf.u64(lo, hi);
				}
			}
			var fs = t.fields.copy();
			fs.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
			if (fs.length > 0) {
				fsSym = local(rodata, "fs", 4);
				for (f in fs) {
					rodata.buf.u32(e.fid(f.name));
					rodata.buf.u32(f.slot);
					rodata.buf.u32(kindChar(f.ty));
				}
			}
			var ms = t.methods.copy();
			ms.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
			if (ms.length > 0) {
				msSym = local(data, "ms", 8);
				for (m in ms) {
					data.buf.u32(e.fid(m.name));
					data.buf.u32(0);
					ptr(data, m.fn);
					data.buf.u32(m.sig);
					data.buf.u32(0);
				}
			}
			if (t.ifaces.length > 0) {
				ifSym = local(rodata, "if", 4);
				for (x in t.ifaces)
					rodata.buf.u32(x);
			}
			if (t.ctors.length > 0) {
				ctSym = local(rodata, "ct", 4);
				for (x in t.ctors)
					rodata.buf.u32(x);
			}
			entries.push({
				t: t,
				ss: ss,
				ssSym: ssSym,
				pmSym: pmSym,
				fs: fs.length,
				fsSym: fsSym,
				ms: ms.length,
				msSym: msSym,
				ifSym: ifSym,
				ctSym: ctSym
			});
		}
		var nameSyms = [for (x in entries) cstr(x.t.name)];
		begin(data, "rt_types", 16, true);
		for (k in 0...entries.length) {
			var x = entries[k];
			var t = x.t;
			var at = data.buf.len;
			ptrSym(data, nameSyms[k]); // 0 name
			data.buf.u32(tk(t.tk)); // 8 tk (u8)
			data.buf.u32(t.sup); // 12 super
			data.buf.u32(t.slots.length); // 16 nslots
			data.buf.u32(0);
			if (x.pmSym != null) ptrSym(data, x.pmSym) else data.buf.u64(0, 0); // 24 ptrmap
			data.buf.u32(x.fs); // 32 nfields
			data.buf.u32(0);
			if (x.fsSym != null) ptrSym(data, x.fsSym) else data.buf.u64(0, 0); // 40 fields
			data.buf.u32(x.ms); // 48 nmethods
			data.buf.u32(0);
			if (x.msSym != null) ptrSym(data, x.msSym) else data.buf.u64(0, 0); // 56 methods
			data.buf.u32(t.ifaces.length); // 64 nifaces
			data.buf.u32(0);
			if (x.ifSym != null) ptrSym(data, x.ifSym) else data.buf.u64(0, 0); // 72 ifaces
			data.buf.u32(t.tag); // 80 tag
			data.buf.u32(0);
			if (x.ctSym != null) ptrSym(data, x.ctSym) else data.buf.u64(0, 0); // 88 ctors
			data.buf.u32(x.ss != null ? x.ss.length : 0); // 96 nstatics
			data.buf.u32(0);
			if (x.ssSym != null) ptrSym(data, x.ssSym) else data.buf.u64(0, 0); // 104 statics
			if (data.buf.len - at != Abi.TYPE_SIZE) throw "hxmc: rt_type layout";
		}
		int32Global("rt_ntypes", types.length);
	}

	function dispatch() {
		for (s in 0...p.selectors.length) {
			begin(data, e.selNames[s], 8, true);
			for (c in p.classes) {
				var m = c.findMethod(p.selectors[s].name);
				if (m != null && m.dispatchSel == s) ptr(data, e.cname(m)) else data.buf.u64(0, 0);
			}
		}
	}

	// the allocation stubs the program's code calls (MirBuild.ALLOC_STUB):
	// each passes its header words and size to hxmc_alloc_slow, so an
	// allocation site's slow path is one call (after run: hx_main_body
	// allocates). They record their frames for the stack maps (an
	// allocation may collect), as the thunks the program calls C functions
	// through (StackMaps.THUNK) do; both are dropped by the linker when
	// nothing calls them.
	public function allocStubs(objs:Array<Obj>) {
		var names = new Map<String, Bool>();
		var thunks = new Map<String, Bool>();
		for (o in objs.concat([obj]))
			for (s in o.symbols)
				if (s.section == null && !s.abs) {
					if (StringTools.startsWith(s.name, MirBuild.ALLOC_STUB)) names.set(s.name, true);
					else if (StringTools.startsWith(s.name, StackMaps.THUNK)) thunks.set(s.name, true);
				}
		var list = [for (n in names.keys()) n];
		list.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in list) {
			var parts = n.substr(MirBuild.ALLOC_STUB.length).split("$");
			var lo = Std.parseInt(parts[0]), bytes = Std.parseInt(parts[2]);
			var ty = parts[1];
			var mf = MirBuild.synthetic(prep, abi, n, [], I64, (b, _) -> {
				var t = StringTools.startsWith(ty, "#") ? b.iconst(Std.parseInt(ty.substr(1))) : b.idConst(ty, 0);
				b.ret(b.call("hxmc_alloc_slow", [b.iconst(lo), t, b.iconst(bytes)], I64));
			});
			mf.inlineRecords = true;
			mf.section = Link.GC_PREFIX + n;
			compile(mf);
		}
		var list = [for (n in thunks.keys()) n];
		list.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in list) {
			var sig = n.substr(StackMaps.THUNK.length);
			var d = sig.indexOf("$");
			var target = sig.substr(d + 1);
			sig = sig.substr(0, d);
			var noReturn = StringTools.startsWith(sig, "n");
			if (noReturn) sig = sig.substr(1);
			var ret = StackMaps.charTy(sig.charAt(0));
			var params = [for (k in 1...sig.length) StackMaps.charTy(sig.charAt(k))];
			var mf = MirBuild.synthetic(prep, abi, n, params, ret, (b, ps) -> {
				var r = b.call(target, ps, ret, noReturn);
				if (noReturn) b.add(b.mk(Unreachable, Void)) else b.ret(ret == Void ? -1 : r);
			});
			mf.inlineRecords = true;
			mf.section = Link.GC_PREFIX + n;
			compile(mf);
		}
	}

	function entry(mf:MFunc) {
		StackMaps.entry(mf);
		compile(mf);
	}

	function mainBody() {
		// (main and the program's body are entries: C calls them, StackMaps.entry)
		entry(MirBuild.synthetic(prep, abi, "hx_main_body", [], Void, (b, _) -> {
			for (i in 0...p.globals.length) {
				var c = p.globals[i].init;
				if (c != null) {
					var o = b.alloc(1, c.tindex, Abi.K_OBJ, true);
					b.store(8, b.load(I64, 8, b.symAddr("rt_globals"), 0), 8 * i, o);
				}
			}
			for (f in p.inits)
				b.call(e.cname(f), [], Void);
			b.call(e.cname(p.main), [], Void);
			b.ret(-1);
		}));
		entry(MirBuild.synthetic(prep, abi, "main", [I32, I64], I32, (b, ps) -> {
			b.call("rt_init", [b.iconst(p.globals.length), ps[0], ps[1]], Void);
			b.call("rt_run_main", [b.symAddr("hx_main_body")], Void);
			b.ret(b.iconst(0));
		}));
	}
}
