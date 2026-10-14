package hxmc;

import hxmc.Mir;

// Stack maps (hxmc/rt/rt_frames.c walks them): a collection finds the
// references of hxmc's frames through the frame-pointer chain and a table
// of frame descriptors keyed by code address (Emit writes one per function
// that calls: its root slots, MFunc.rootSlots). C frames are skipped:
// - a call of a C function that may collect (or enter a safe region, where
//   another thread may collect) records the calling frame first: its frame
//   pointer and an address in it (rt_last_fp, rt_last_pc), where the walk
//   starts. The program calls such a function through a thunk (one per
//   function and signature, DataGen.thunks) that records its own frame, so
//   the call sites carry no code for it; only rt_blocking_enter records
//   its caller (the safe region outlasts the call);
// - a function that C calls (an entry: main, the program's body, the
//   wrappers of the exported runtime functions) saves the record it finds
//   in its frame and restores it on return; the walk continues from the
//   saved record, past the C frames below the entry.
class StackMaps {
	// thread-local variables of the runtime (rt_frames.c)
	public static inline var LAST_FP = "rt_last_fp";
	public static inline var LAST_PC = "rt_last_pc";

	// C functions that neither collect nor wait in a safe region, besides
	// the runtime functions FnLower.noGcHost names
	static var QUIET = [
		"memset" => true, "memcpy" => true, "memmove" => true, "floor" => true, "pow" => true, "fmod" => true, "atan2" => true,
		"hxmc_barrier_slow" => true, "setjmp" => true, "_setjmp" => true, "__mingw_setjmp" => true, "hxmc_tls_base" => true,
	];

	// a C function that neither collects nor waits (besides FnLower.noGcHost's)
	public static function quiet(sym:String):Bool
		return QUIET.exists(sym) || StringTools.startsWith(sym, "hxmc$");

	// whether a call of `sym` needs the record: a C function (not one of
	// the program's) that may collect or enter a safe region
	public static function transition(sym:String, haxe:String->Bool):Bool {
		if (haxe(sym) || QUIET.exists(sym) || StringTools.startsWith(sym, "hxmc$")) return false;
		// (allocation stubs and thunks record their own frames)
		if (StringTools.startsWith(sym, MirBuild.ALLOC_STUB) || StringTools.startsWith(sym, THUNK)) return false;
		if (sym == "rt_blocking_enter") return true;
		return !hxmc.ir.FnLower.noGcHost(sym);
	}

	// the frame descriptors' section (Driver.frameTable merges the
	// objects' into one, between hxmc_frames_start and hxmc_frames_end)
	public static inline var SECTION = ".hxmc.frames";
	public static inline var TABLE = ".hxmc.frametab";
	public static inline var START = "hxmc_frames_start";
	public static inline var END = "hxmc_frames_end";
	public static inline var DESC_SIZE = 12;
	public static inline var ENTRY = 0x80000000;

	// the descriptor of the function `sym` (code bytes `len`): its slots
	// [fp + off, fp + off + 8 * n) hold references (or, ENTRY, the saved
	// record: frame pointer, then code address)
	//   int32 the function's address - the descriptor's
	//   uint32 len
	//   uint32 n << 18 | -off / 8 (off < 0: below the frame record) | flags
	public static function descriptor(obj:Obj, sym:String, len:Int, off:Int, n:Int, flags:Int) {
		if (n > 0x1fff || n > 0 && (off >= 0 || off & 7 != 0 || -off >> 3 > 0x3ffff))
			throw 'hxmc: $sym: a frame the stack maps cannot describe ($n slots at $off)';
		var sec = obj.section(SECTION, RoData, 4);
		var at = sec.buf.len;
		sec.relocs.push(new Obj.Reloc(at, RPc32, obj.sym(sym), 0));
		sec.buf.u32(0);
		sec.buf.u32(len);
		sec.buf.u32(n == 0 ? flags : (n << 18) | (-off >> 3) | flags);
	}

	// the frame slots' offsets from the frame's base (`start`: after the
	// outgoing arguments): the other slots, the entry's slot, then the root
	// slots together (next to the frame record: short offsets from it)
	public static function layout(f:hxmc.Lir.LFunc, start:Int):FrameLayout {
		var n = f.slots.length;
		var slotOff = [for (_ in 0...n) -1];
		var off = start;
		function place(k:Int) {
			var s = f.slots[k];
			var al = s.align < 8 ? 8 : s.align;
			off = (off + al - 1) & ~(al - 1);
			slotOff[k] = off;
			off += s.size;
		}
		var special = new Map<Int, Bool>();
		for (k in f.rootSlots)
			special.set(k, true);
		if (f.entrySlot >= 0) special.set(f.entrySlot, true);
		for (k in 0...n)
			if (!special.exists(k)) place(k);
		if (f.entrySlot >= 0) place(f.entrySlot);
		off = (off + 7) & ~7;
		var rootOff = off;
		var zeros = [];
		for (i in 0...f.rootSlots.length) {
			var k = f.rootSlots[i];
			place(k);
			if (f.rootZero[i] > 0) zeros.push({off: slotOff[k] + f.slots[k].size - f.rootZero[i], bytes: f.rootZero[i]});
		}
		return {
			slotOff: slotOff,
			end: off,
			rootOff: rootOff,
			rootBytes: off - rootOff,
			entryOff: f.entrySlot >= 0 ? slotOff[f.entrySlot] : -1,
			zeros: zeros
		};
	}

	// HXMC_FRAMES=all: a descriptor for every function with a frame record
	// (the walk then knows every frame: RT_FRAMES_STRICT=1 checks it); by
	// default only for those with root slots and the entries (a frame
	// without one has no references)
	static var allFrames = Sys.getEnv("HXMC_FRAMES") == "all";

	// the descriptor of an emitted function; `base` is the frame base's
	// offset from the frame pointer
	public static function describe(obj:Obj, f:hxmc.Lir.LFunc, lay:FrameLayout, len:Int, base:Int) {
		if (lay.rootBytes == 0 && f.entrySlot < 0 && !allFrames) return;
		if (f.entrySlot >= 0) {
			if (lay.rootBytes > 0) throw "hxmc: " + f.name + ": an entry with root slots";
			descriptor(obj, f.name, len, base + lay.entryOff, 2, ENTRY);
		} else
			descriptor(obj, f.name, len, base + lay.rootOff, lay.rootBytes >> 3, 0);
	}

	// the thunks: hxmc_tr$<n if it never returns><result><arguments>$<function>,
	// types i (32 bits), l (64), d (double), v (none)
	public static inline var THUNK = "hxmc_tr$";

	static function tyChar(t:MTy):String
		return switch t {
			case I32: "i";
			case I64: "l";
			case F64: "d";
			case Void: "v";
		};

	public static function charTy(c:String):MTy
		return switch c {
			case "i": I32;
			case "l": I64;
			case "d": F64;
			case _: Void;
		};

	static function thunkName(i:MIns):String {
		var b = new StringBuf();
		b.add(THUNK);
		if (i.noReturn) b.add("n");
		b.add(tyChar(i.ty));
		for (t in i.argTys)
			b.add(tyChar(t));
		b.add("$");
		b.add(i.sym);
		return b.toString();
	}

	// the calls that need the record: through thunks, or (`inlineOnly`, and the
	// calls of rt_blocking_enter and variadic functions) after storing it
	public static function record(f:MFunc, haxe:String->Bool, inlineOnly:Bool) {
		for (b in f.blocks) {
			var k = 0;
			while (k < b.ins.length) {
				var i = b.ins[k];
				if (i.op == Call && !i.dead && i.sym != null && transition(i.sym, haxe)) {
					if (!inlineOnly && i.variadic < 0 && i.sym != "rt_blocking_enter") {
						i.sym = thunkName(i);
						k++;
						continue;
					}
					var at = k;
					function put(x:MIns) {
						x.id = f.vals.length;
						f.vals.push(x);
						x.block = b;
						b.ins.insert(at++, x);
					}
					var fp = new MIns(FramePtr, I64);
					put(fp);
					var s1 = new MIns(TlsStore, Void);
					s1.sym = LAST_FP;
					s1.a = fp.id;
					put(s1);
					var pc = new MIns(SymAddr, I64);
					pc.sym = f.name;
					put(pc);
					var s2 = new MIns(TlsStore, Void);
					s2.sym = LAST_PC;
					s2.a = pc.id;
					put(s2);
					k = at;
				}
				k++;
			}
		}
	}

	// makes f an entry: it saves the record on entry (after its
	// parameters), restores it before each return
	public static function entry(f:MFunc) {
		var slot = f.slot(16, 16);
		f.entrySlot = slot;
		function mk(op:Op, ty:MTy, b:MBlock):MIns {
			var x = new MIns(op, ty);
			x.id = f.vals.length;
			f.vals.push(x);
			x.block = b;
			return x;
		}
		function copy(b:MBlock, at:Int, from:Bool):Int {
			// from: the record into the slot; else back
			var out:Array<MIns> = [];
			var addr = mk(StackAddr, I64, b);
			addr.imm = slot;
			out.push(addr);
			for (k in 0...2) {
				var sym = k == 0 ? LAST_FP : LAST_PC;
				if (from) {
					var l = mk(TlsLoad, I64, b);
					l.sym = sym;
					out.push(l);
					var st = mk(Store, Void, b);
					st.a = addr.id;
					st.c = l.id;
					st.imm = 8 * k;
					st.size = 8;
					st.mem = Opt.MFrame;
					out.push(st);
				} else {
					var l = mk(Load, I64, b);
					l.a = addr.id;
					l.imm = 8 * k;
					l.size = 8;
					l.mem = Opt.MFrame;
					out.push(l);
					var st = mk(TlsStore, Void, b);
					st.sym = sym;
					st.a = l.id;
					out.push(st);
				}
			}
			for (x in out)
				b.ins.insert(at++, x);
			return at;
		}
		var e = f.entry;
		var first = 0;
		while (first < e.ins.length && e.ins[first].op == Param)
			first++;
		copy(e, first, true);
		for (b in f.blocks) {
			var t = b.term();
			if (t != null && t.op == Ret) copy(b, b.ins.length - 1, false);
		}
	}
}

typedef FrameLayout = {
	slotOff:Array<Int>,
	end:Int,
	rootOff:Int,
	rootBytes:Int,
	entryOff:Int,
	zeros:Array<{off:Int, bytes:Int}> // the root slots' bytes the prologue zeroes
}
