package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.rt.LibM;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// rt.c's boxes, array element access and growth, and Int conversion for
// WebAssembly (README.md, "WebAssembly"), in Haxe: references kept
// across allocations are ordinary locals here (the compiler roots them),
// raw addresses are taken again after each allocation.
@:hxmc.wasm @:keep
class Boxes {
	static inline var SMALL_MIN = -128;
	static inline var SMALL_MAX = 1023;
	static inline var T_ADATA_RAW = 7;
	static inline var T_ADATA_P = 6;
	static var smallInts:Ptr; // static boxes (outside the heap)
	static var boolBoxes:Ptr;

	@:hxmc.noGc public static function init() {
		var n = SMALL_MAX - SMALL_MIN + 1;
		smallInts = Heap.calloc(2 * n, 8);
		for (i in 0...n) {
			Mem.setI64(smallInts, 16 * i, Gc.mkhdr(1, K_OBJ, T_BOXINT));
			Mem.setI32(smallInts, 16 * i + 8, i + SMALL_MIN);
		}
		boolBoxes = Heap.calloc(4, 8);
		for (i in 0...2) {
			Mem.setI64(boolBoxes, 16 * i, Gc.mkhdr(1, K_OBJ, T_BOXBOOL));
			Mem.setI32(boolBoxes, 16 * i + 8, i);
		}
	}

	@:hxmc.export("hx_box_int") static function boxInt(v:Int):Dynamic {
		if (v >= SMALL_MIN && v <= SMALL_MAX) return Mem.obj(smallInts.add(16 * (v - SMALL_MIN) + 8));
		var b = Mem.allocRaw(1, T_BOXINT, K_OBJ);
		Mem.setI64(Mem.addr(b), 0, 0);
		Mem.setI32(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_float") static function boxFloat(v:Float):Dynamic {
		var b = Mem.allocRaw(1, T_BOXFLOAT, K_OBJ);
		Mem.setF64(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_i64") static function boxI64(v:I64):Dynamic {
		var b = Mem.allocRaw(1, T_BOXI64, K_OBJ);
		Mem.setI64(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_bool") @:hxmc.noGc static function boxBool(v:Int):Dynamic
		return Mem.obj(boolBoxes.add(v != 0 ? 24 : 8));

	@:hxmc.noGc static function f2l(f:Float):I64 {
		if (f != f) return 0;
		if (f >= 9223372036854775808.0) return ((1 : I64) << 63) - 1;
		if (f < -9223372036854775808.0) return (1 : I64) << 63;
		var l:I64 = cast f;
		return l;
	}

	// Std.int / Int casts: truncation in range; NaN gives 0, wider values wrap
	@:hxmc.noGc static inline function f2i(f:Float):Int
		return f > -2147483649.0 && f < 2147483648.0 ? (cast f : Int) : f2iSlow(f);

	@:hxmc.export("hx_f2i_slow") @:hxmc.noGc static function f2iSlow(f:Float):Int {
		if (f != f) return 0;
		if (f >= 2147483648.0 || f <= -2147483649.0) {
			var l:I64 = cast LibM.fmod(f, 4294967296.0);
			return l.toInt();
		}
		return cast f;
	}

	@:hxmc.export("hx_unbox_int") @:hxmc.noGc static function unboxInt(v:Dynamic):Int {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: f2i(Mem.getF64(p, 0));
			case T_BOXI64: Mem.getI64(p, 0).toInt();
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_float") @:hxmc.noGc static function unboxFloat(v:Dynamic):Float {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: Mem.getF64(p, 0);
			case T_BOXI64:
				var f:Float = cast Mem.getI64(p, 0);
				f;
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_i64") @:hxmc.noGc static function unboxI64(v:Dynamic):I64 {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: f2l(Mem.getF64(p, 0));
			case T_BOXI64: Mem.getI64(p, 0);
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_bool") @:hxmc.noGc static function unboxBool(v:Dynamic):Int {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0) != 0 ? 1 : 0;
			case T_BOXFLOAT: Mem.getF64(p, 0) != 0 ? 1 : 0;
			case T_BOXI64: Mem.getI64(p, 0) == 0 ? 0 : 1;
			case _: 1;
		}
	}

	// ---- arrays (rt.h: slot 0 the length and the element kind, slot 1 the data)

	static inline function arrLen(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 0);

	static inline function arrKind(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 4);

	static inline function arrData(a:Dynamic):Ptr
		return Mem.getPtr(Mem.addr(a), 8);

	static inline function arrCap(a:Dynamic):Int {
		var d = arrData(a);
		return d.isNull() ? 0 : (Mem.getI32(d, -8) & 0x0FFFFFFF) << (arrKind(a) == AK_I32 ? 1 : 0);
	}

	static function dataAlloc(kind:Int, cap:Int):Dynamic {
		if (cap < 1) cap = 1;
		return switch kind {
			case AK_I32: Mem.alloc((cap + 1) >> 1, T_ADATA_RAW, K_RAW);
			case AK_F64 | AK_I64: Mem.alloc(cap, T_ADATA_RAW, K_RAW);
			case _: Mem.alloc(cap, T_ADATA_P, K_PARR);
		}
	}

	@:hxmc.export("hx_arr_new_n") static function arrNewN(kind:Int, len:Int):Dynamic {
		var d = dataAlloc(kind, len);
		var a = Mem.alloc(2, T_ARRAY, K_OBJ);
		Mem.setI32(Mem.addr(a), 0, len);
		Mem.setI32(Mem.addr(a), 4, kind);
		Mem.setRefBarrier(a, 8, d);
		return a;
	}

	@:hxmc.export("hx_arr_grow") static function arrGrow(slot:Ptr, need:Int):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		var cap = arrCap(a);
		if (need <= cap) return;
		var ncap = cap * 2;
		if (ncap < 2) ncap = 2;
		if (ncap < need) ncap = need;
		var kind = arrKind(a);
		var nd = dataAlloc(kind, ncap);
		a = Mem.getRef(slot, 0);
		var len = arrLen(a);
		var d = arrData(a);
		if (!d.isNull()) {
			var es = kind == AK_I32 ? 4 : 8;
			Wasm.memcpy(Mem.addr(nd), d, es * len);
			if (kind == AK_PTR && !inYoungObj(nd)) Gc_barrierRange(nd, len);
		}
		Mem.setRefBarrier(a, 8, nd);
	}

	@:hxmc.noGc static function inYoungObj(o:Dynamic):Bool {
		var p = Mem.addr(o);
		return !p.ult(Mem.getPtr(Mem.sym("rt_young_start"), 0)) && p.ult(Mem.getPtr(Mem.sym("rt_young_end"), 0));
	}

	@:hxmc.noGc static function Gc_barrierRange(o:Dynamic, n:Int)
		hxmc.rt.C.Leaf.rt_barrier_range(o, Mem.addr(o), n);

	@:hxmc.export("hx_arr_to_ptr") static function arrToPtr(slot:Ptr):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		if (arrKind(a) == AK_PTR) return;
		var len = arrLen(a);
		var nd = dataAlloc(AK_PTR, len);
		for (i in 0...len) {
			a = Mem.getRef(slot, 0);
			var k = arrKind(a);
			var v:Dynamic = k == AK_I32 ? boxInt(Mem.getI32At(arrData(a), 0, i)) : k == AK_I64 ? boxI64(Mem.getI64At(arrData(a), 0, i)) : boxFloat(Mem.getF64At(arrData(a), 0, i));
			Mem.setRefBarrier(nd, 8 * i, v);
		}
		a = Mem.getRef(slot, 0);
		Mem.setI32(Mem.addr(a), 4, AK_PTR);
		Mem.setRefBarrier(a, 8, nd);
	}

	@:hxmc.export("hx_aget_i_slow") @:hxmc.noGc static function agetI(a:Dynamic, i:Int):Int {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32: Mem.getI32At(d, 0, i);
			case AK_F64: f2i(Mem.getF64At(d, 0, i));
			case AK_I64: Mem.getI64At(d, 0, i).toInt();
			case _: unboxInt(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_l_slow") @:hxmc.noGc static function agetL(a:Dynamic, i:Int):I64 {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32: Mem.getI32At(d, 0, i);
			case AK_F64: f2l(Mem.getF64At(d, 0, i));
			case AK_I64: Mem.getI64At(d, 0, i);
			case _: unboxI64(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_f_slow") @:hxmc.noGc static function agetF(a:Dynamic, i:Int):Float {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32: Mem.getI32At(d, 0, i);
			case AK_F64: Mem.getF64At(d, 0, i);
			case AK_I64:
				var f:Float = cast Mem.getI64At(d, 0, i);
				f;
			case _: unboxFloat(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_p_slow") static function agetP(a:Dynamic, i:Int):Dynamic {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return null;
		return switch arrKind(a) {
			case AK_I32: boxInt(Mem.getI32At(arrData(a), 0, i));
			case AK_F64: boxFloat(Mem.getF64At(arrData(a), 0, i));
			case AK_I64: boxI64(Mem.getI64At(arrData(a), 0, i));
			case _: Mem.getRefAt(arrData(a), 0, i);
		}
	}

	// store v (of kind vk; AK_PTR: v is the address of a rooted slot) at i < length
	static function storeConv(slot:Ptr, i:Int, vk:Int, v:I64):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		var ak = arrKind(a);
		if (ak == AK_PTR) {
			var p:Dynamic = switch vk {
				case AK_I32: boxInt(v.toInt());
				case AK_F64: boxFloat(haxe.io.FPHelper.i64ToDouble(v.toInt(), (v >> 32).toInt()));
				case AK_I64: boxI64(v);
				case _: Mem.getRef(new Ptr(v), 0);
			}
			a = Mem.getRef(slot, 0);
			Mem.setRefBarrier(Mem.obj(arrData(a)), 8 * i, p);
			return;
		}
		if (vk == AK_PTR) {
			var p:Dynamic = Mem.getRef(new Ptr(v), 0);
			var t = Mem.addr(p).isNull() ? T_BOXINT : tindex(p);
			var fits = ak == AK_I32 ? (t == T_BOXINT || t == T_BOXBOOL) : ak == AK_F64 ? (t == T_BOXINT || t == T_BOXFLOAT || t == T_BOXBOOL) : (t == T_BOXINT
				|| t == T_BOXBOOL || t == T_BOXI64);
			if (!fits) {
				arrToPtr(slot);
				storeConv(slot, i, vk, v);
				return;
			}
			var d = arrData(a);
			if (ak == AK_I32) Mem.setI32At(d, 0, i, unboxInt(p)) else if (ak == AK_F64) Mem.setF64At(d, 0, i, unboxFloat(p)) else
				Mem.setI64At(d, 0, i, unboxI64(p));
			return;
		}
		if (vk != ak && !(vk == AK_I32 && (ak == AK_F64 || ak == AK_I64))) {
			arrToPtr(slot);
			storeConv(slot, i, vk, v);
			return;
		}
		var d = arrData(a);
		if (ak == AK_I32) Mem.setI32At(d, 0, i, v.toInt()) else if (ak == AK_F64) {
			if (vk == AK_I32) Mem.setF64At(d, 0, i, v.toInt()) else Mem.setI64At(d, 0, i, v);
		} else
			Mem.setI64At(d, 0, i, vk == AK_I32 ? (v.toInt() : I64) : v);
	}

	@:hxmc.export("hx_aset_slow") static function asetSlow(slot:Ptr, i:Int, vk:Int, v:I64):Void {
		if (i < 0) return;
		var a:Dynamic = Mem.getRef(slot, 0);
		if (!Mem.ult(i, arrLen(a))) {
			arrGrow(slot, i + 1);
			a = Mem.getRef(slot, 0);
			if (!Mem.ult(i, arrLen(a))) Mem.setI32(Mem.addr(a), 0, i + 1);
		}
		storeConv(slot, i, vk, v);
	}

	@:hxmc.export("hx_apush_slow") static function apushSlow(slot:Ptr, vk:Int, v:I64):Int {
		var a:Dynamic = Mem.getRef(slot, 0);
		var n = arrLen(a);
		while (n >= arrCap(a)) {
			arrGrow(slot, n + 1);
			a = Mem.getRef(slot, 0);
			n = arrLen(a);
		}
		Mem.setI32(Mem.addr(a), 0, n + 1);
		storeConv(slot, n, vk, v);
		return n;
	}
}
