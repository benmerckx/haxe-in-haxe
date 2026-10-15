package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The math library of every target (Math's natives, `%` on floats), in
// Haxe so that results are the same everywhere, and the same as glibc's on
// Linux (the reference compiler's C library, see README.md "Testing"): the
// host's C library computes only exact functions (fmod, floor, ceil, sqrt).
//
// - exp, log, pow: ARM's optimized routines (exp.c, log.c, pow.c and their
//   tables), which glibc's are (glibc 2.28 and later). glibc runs its FMA
//   build on processors with FMA (x86-64 since Haswell, every ARM64), so
//   these are those routines as GCC compiles them with -mfma: the
//   operations it fuses (its .FMA in GIMPLE) are calls of `fma` here, and
//   results match glibc's bit for bit.
// - sin, cos, tan, asin, acos, atan, atan2: the CORE-MATH project's
//   correctly rounded functions (LibMTrig, LibMArc). glibc's are not
//   correctly rounded, but nearly always are (hxmc/test/Libm.hx counts the
//   differences).
// - fmod (`%`) on WebAssembly: musl's (exact, as any correct implementation).
// - fma: the processor's (x86-64 with FMA3, arm64), else exact in software
//   (Dekker's product and Boldo and Melquiond's emulation with rounding to
//   odd; musl's integer algorithm outside its range).
//
// The tables are hexadecimal bit patterns, decoded once into memory on
// first use. Licenses (MIT): hxmc/std/hxmc/rt/LICENSE.libm.
@:keep @:allow(hxmc.rt)
class LibM {
	// ---- bits

	static inline function bits(x:Float):I64 {
		var t = Mem.stack(8);
		Mem.setF64(t, 0, x);
		return Mem.getI64(t, 0);
	}

	static inline function ofBits(u:I64):Float {
		var t = Mem.stack(8);
		Mem.setI64(t, 0, u);
		return Mem.getF64(t, 0);
	}

	// a 64-bit constant from its two halves
	static inline function u64(hi:Int, lo:Int):I64
		return ((hi : I64) << 32) | (((lo : I64) << 32) >>> 32);

	static inline function nz(x:I64):Bool
		return !(x == 0);

	static inline function top12(x:Float):Int
		return (bits(x) >>> 52).toInt();

	// unsigned comparisons of 32-bit patterns
	static inline function ult(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	static inline function uge(a:Int, b:Int):Bool
		return !ult(a, b);

	static inline function inf():Float
		return ofBits((0x7ff : I64) << 52);

	// leading zeros of a non-zero 64-bit word
	@:hxmc.noGc static function clz64(x:I64):Int {
		var n = 0;
		if ((x >>> 32) == 0) {
			n += 32;
			x = x << 32;
		}
		if ((x >>> 48) == 0) {
			n += 16;
			x = x << 16;
		}
		if ((x >>> 56) == 0) {
			n += 8;
			x = x << 8;
		}
		if ((x >>> 60) == 0) {
			n += 4;
			x = x << 4;
		}
		if ((x >>> 62) == 0) {
			n += 2;
			x = x << 2;
		}
		if ((x >>> 63) == 0) n += 1;
		return n;
	}

	// the high 64 bits of the 128-bit product of unsigned a and b (the low
	// ones are a * b)
	@:hxmc.noGc static inline function mulhi(a:I64, b:I64):I64 {
		var al = (a << 32) >>> 32, ah = a >>> 32;
		var bl = (b << 32) >>> 32, bh = b >>> 32;
		var t = al * bl;
		var m1 = ah * bl + (t >>> 32);
		var m2 = al * bh + ((m1 << 32) >>> 32);
		return ah * bh + (m1 >>> 32) + (m2 >>> 32);
	}

	// ---- tables: hexadecimal words (`width` digits each) into memory, once
	// (a thread that loses the race builds a copy of its own: it is the
	// same, and published only when complete)

	@:hxmc.noGc static inline function hexDigit(c:Int):Int
		return c <= "9".code ? c - "0".code : c - "a".code + 10;

	@:hxmc.noGc static function load(t:Ptr, lit:String, at:Int, width:Int):Void {
		var n = Std.int(Str.len(lit) / width);
		for (i in 0...n) {
			var v:I64 = 0;
			for (k in 0...width)
				v = (v << 4) | hexDigit(Str.unit(lit, i * width + k));
			Mem.setI64(t, 8 * (at + i), v);
		}
	}

	static var tabs:Ptr;

	static inline var O_EXP_TAB = 0;
	static inline var O_LOG_TAB = 256;
	static inline var O_POW_TAB = 512;
	static inline var NTAB = 896;

	@:hxmc.noGc static function tab():Ptr {
		var t = tabs;
		if (!t.isNull()) return t;
		t = LibC.malloc(8 * NTAB);
		load(t, EXP_TAB, O_EXP_TAB, 16);
		load(t, LOG_TAB, O_LOG_TAB, 16);
		load(t, POW_TAB, O_POW_TAB, 16);
		Atomic.fence();
		tabs = t;
		return t;
	}

	static inline function td(t:Ptr, i:Int):Float
		return Mem.getF64(t, 8 * i);

	static inline function tl(t:Ptr, i:Int):I64
		return Mem.getI64(t, 8 * i);

	// ---- fma(a, b, c) = a * b + c rounded once

	static inline var SPLIT = 134217729.0; // 2^27 + 1

	// the error of p = a * b (rounded): a * b - p exactly (Dekker), when
	// |a|, |b| < 2^996 and their exponents sum to at least -969
	static inline function mulErr(a:Float, b:Float, p:Float):Float {
		var t = SPLIT * a;
		var ah = t - (t - a);
		var al = a - ah;
		t = SPLIT * b;
		var bh = t - (t - b);
		var bl = b - bh;
		return ((ah * bh - p) + ah * bl + al * bh) + al * bl;
	}

	// the error of s = a + b (rounded): a + b - s exactly (Knuth's TwoSum)
	static inline function sumErr(a:Float, b:Float, s:Float):Float {
		var z = s - a;
		return (a - (s - z)) + (b - z);
	}

	// the processor's fma when it has one (x86-64: checked once: 0 not yet,
	// 1 yes, 2 no), else fmaSoft
	static var fmaHw = 0;

	// (-D hxmc.fma: a tool that has Mem.fma, see hxmc.Main.CAPS; the results
	// are the same without it)
	@:hxmc.noGc public static inline function fma(a:Float, b:Float, c:Float):Float {
		#if (hxmc.fma)
		if (Mem.target() == 6) return fmaSoft(a, b, c);
		if (Mem.arm()) return Mem.fma(a, b, c);
		if (fmaHw == 1) return Mem.fma(a, b, c);
		return fmaFirst(a, b, c);
		#else
		return fmaSoft(a, b, c);
		#end
	}

	#if (hxmc.fma)
	@:hxmc.noGc static function fmaFirst(a:Float, b:Float, c:Float):Float {
		if (fmaHw == 0) fmaHw = Mem.hasFma() ? 1 : 2;
		return fmaHw == 1 ? Mem.fma(a, b, c) : fmaSoft(a, b, c);
	}
	#end

	// for the code specialized for the processor's fma (hw) and without it
	// (one copy each, chosen once per call by useHw: a call of fmaSoft that
	// the code may reach keeps its values in memory)
	@:hxmc.noGc static inline function useHw():Bool {
		#if (hxmc.fma)
		if (Mem.target() == 6) return false;
		if (Mem.arm()) return true;
		if (fmaHw == 0) fmaHw = Mem.hasFma() ? 1 : 2;
		return fmaHw == 1;
		#else
		return false;
		#end
	}

	static inline function fm(hw:Bool, a:Float, b:Float, c:Float):Float {
		#if (hxmc.fma)
		var r:Float;
		if (Mem.target() != 6) {
			if (hw) r = Mem.fma(a, b, c); else r = fmaSoft(a, b, c);
		} else
			r = fmaSoft(a, b, c);
		return r;
		#else
		return fmaSoft(a, b, c);
		#end
	}

	// a * b - p exactly, for p = a * b rounded
	static inline function me(hw:Bool, a:Float, b:Float, p:Float):Float {
		#if (hxmc.fma)
		var r:Float;
		if (Mem.target() != 6) {
			if (hw) r = Mem.fma(a, b, -p); else r = mulErr(a, b, p);
		} else
			r = mulErr(a, b, p);
		return r;
		#else
		return mulErr(a, b, p);
		#end
	}

	@:hxmc.noGc public static function fmaSoft(a:Float, b:Float, c:Float):Float {
		var ea = top12(a) & 0x7ff, eb = top12(b) & 0x7ff, ec = top12(c) & 0x7ff;
		// a and b normal below 2^996, their product in [2^-916, 2^1022),
		// |c| < 2^1022: Dekker's product is exact and nothing overflows
		if (ea >= 1 && ea <= 2018 && eb >= 1 && eb <= 2018 && ea + eb >= 1130 && ea + eb <= 3067 && ec <= 2044) {
			var p = a * b;
			var e = mulErr(a, b, p);
			var s = c + p;
			var t = sumErr(c, p, s);
			// v = t + e rounded to odd (Boldo and Melquiond: s + v rounded to
			// nearest is then a * b + c rounded once)
			var v = t + e;
			var w = sumErr(t, e, v);
			if (w != 0) {
				var bv = bits(v);
				if ((bv & 1) == 0) v = ofBits((w > 0) == (v > 0) ? bv + 1 : bv - 1);
			}
			// with s far from the subnormal range (or 0: then c = -p and the
			// result is e, exact)
			if (s == 0 || Math.abs(s) >= 1.1885959364297e-271) // 2^-900
				return s + v;
		}
		return fmaSlow(a, b, c);
	}

	// musl's fma (src/math/fma.c): exact with integers
	@:hxmc.noGc static function fmaNorm(x:Float, out:Ptr):Void {
		var ix = bits(x);
		var e = (ix >>> 52).toInt();
		var sign = e & 0x800;
		e &= 0x7ff;
		if (e == 0) {
			ix = bits(x * 9223372036854775808.0); // 0x1p63
			e = ((ix >>> 52) & 0x7ff).toInt();
			e = e != 0 ? e - 63 : 0x800;
		}
		ix = ix & (((1 : I64) << 52) - 1);
		ix = ix | ((1 : I64) << 52);
		ix = ix << 1;
		e -= 0x3ff + 52 + 1;
		Mem.setI64(out, 0, ix);
		Mem.setI32(out, 8, e);
		Mem.setI32(out, 12, sign);
	}

	@:hxmc.noGc static function fmaSlow(x:Float, y:Float, z:Float):Float {
		var n = Mem.stack(48);
		fmaNorm(x, n);
		fmaNorm(y, n.add(16));
		fmaNorm(z, n.add(32));
		var nxm = Mem.getI64(n, 0), nxe = Mem.getI32(n, 8), nxs = Mem.getI32(n, 12);
		var nym = Mem.getI64(n, 16), nye = Mem.getI32(n, 24), nys = Mem.getI32(n, 28);
		var nzm = Mem.getI64(n, 32), nze = Mem.getI32(n, 40), nzs = Mem.getI32(n, 44);
		var ZEROINFNAN = 0x7ff - 0x3ff - 52 - 1;
		if (nxe >= ZEROINFNAN || nye >= ZEROINFNAN) return x * y + z;
		if (nze >= ZEROINFNAN) {
			// z == 0: x * y, rounded once (musl adds z, which gives +0 for a
			// negative product that rounds to -0)
			if (nze > ZEROINFNAN) return x * y;
			return z;
		}
		// r = x*y
		var rlo = nxm * nym;
		var rhi = mulhi(nxm, nym);
		var zhi:I64 = 0, zlo:I64 = 0;
		// align exponents
		var e = nxe + nye;
		var d = nze - e;
		if (d > 0) {
			if (d < 64) {
				zlo = nzm << d;
				zhi = nzm >>> (64 - d);
			} else {
				zlo = 0;
				zhi = nzm;
				e = nze - 64;
				d -= 64;
				if (d == 0) {} else if (d < 64) {
					rlo = (rhi << (64 - d)) | (rlo >>> d) | (nz(rlo << (64 - d)) ? 1 : 0);
					rhi = rhi >>> d;
				} else {
					rlo = 1;
					rhi = 0;
				}
			}
		} else {
			zhi = 0;
			d = -d;
			if (d == 0) zlo = nzm; else if (d < 64) zlo = (nzm >>> d) | (nz(nzm << (64 - d)) ? 1 : 0); else zlo = 1;
		}
		// add
		var sign = nxs ^ nys;
		var samesign = (sign ^ nzs) == 0;
		var nonzero = true;
		if (samesign) {
			rlo = rlo + zlo;
			rhi = rhi + zhi + (Mem.ult(rlo, zlo) ? 1 : 0);
		} else {
			var t = rlo;
			rlo = rlo - zlo;
			rhi = rhi - zhi - (Mem.ult(t, rlo) ? 1 : 0);
			if (nz(rhi >>> 63)) {
				rlo = -rlo;
				rhi = -rhi - (nz(rlo) ? 1 : 0);
				sign = sign == 0 ? 1 : 0;
			}
			nonzero = nz(rhi);
		}
		// set rhi to the top 63 bits of the result (the last bit is sticky)
		if (nonzero) {
			e += 64;
			d = clz64(rhi) - 1;
			// d > 0
			rhi = (rhi << d) | (rlo >>> (64 - d)) | (nz(rlo << d) ? 1 : 0);
		} else if (nz(rlo)) {
			d = clz64(rlo) - 1;
			if (d < 0) rhi = (rlo >>> 1) | (rlo & 1); else rhi = rlo << d;
		} else {
			// exact +-0
			return x * y + z;
		}
		e -= d;
		// convert to double
		var i:I64 = rhi; // in [1<<62, (1<<63)-1]
		if (sign != 0) i = -i;
		var r:Float = cast i; // |r| in [0x1p62, 0x1p63]
		if (e < -1022 - 62) {
			// the result is subnormal before rounding
			if (e == -1022 - 63) {
				var c = 9223372036854775808.0; // 0x1p63
				if (sign != 0) c = -c;
				if (r == c) // the smallest normal after rounding
					return sign != 0 ? -2.2250738585072014e-308 : 2.2250738585072014e-308;
				// one bit is lost when scaled, add another top bit to only
				// round once at conversion if it is inexact
				if (nz(rhi << 53)) {
					i = (rhi >>> 1) | (rhi & 1) | ((1 : I64) << 62);
					if (sign != 0) i = -i;
					r = cast i;
					r = 2 * r - c; // remove the top bit
				}
			} else {
				// only round once when scaled
				d = 10;
				i = ((rhi >>> d) | (nz(rhi << (64 - d)) ? 1 : 0)) << d;
				if (sign != 0) i = -i;
				r = cast i;
			}
		}
		return scalbn(r, e);
	}

	// musl's scalbn
	@:hxmc.noGc static function scalbn(x:Float, n:Int):Float {
		var y = x;
		if (n > 1023) {
			y *= 8.98846567431158e307; // 0x1p1023
			n -= 1023;
			if (n > 1023) {
				y *= 8.98846567431158e307;
				n -= 1023;
				if (n > 1023) n = 1023;
			}
		} else if (n < -1022) {
			// make sure the final n < -53 to avoid double rounding in the
			// subnormal range
			y *= 2.004168360008973e-292; // 0x1p-1022 * 0x1p53
			n += 1022 - 53;
			if (n < -1022) {
				y *= 2.004168360008973e-292;
				n += 1022 - 53;
				if (n < -1022) n = -1022;
			}
		}
		return y * ofBits(((0x3ff + n) : I64) << 52);
	}

	// ---- exp (ARM: exp.c, exp_data.c; EXP_TABLE_BITS 7, EXP_POLY_ORDER 5)

	static inline var INVLN2N = 184.66496523378731; // 0x1.71547652b82fep+7
	static inline var NEGLN2HIN = -0.0054152123481117087; // -0x1.62e42fefap-8
	static inline var NEGLN2LON = -1.2864023111638346e-14; // -0x1.cf79abc9e3b3ap-47
	static inline var SHIFT = 6755399441055744.0; // 0x1.8p52
	static inline var EXP_C2 = 0.49999999999996786; // 0x1.ffffffffffdbdp-2
	static inline var EXP_C3 = 0.16666666666665886; // 0x1.555555555543cp-3
	static inline var EXP_C4 = 0.041666680841067401; // 0x1.55555cf172b91p-5
	static inline var EXP_C5 = 0.0083333358530595491; // 0x1.1111167a4d017p-7
	static inline var P1009 = 5.4861240687936887e303; // 0x1p1009
	static inline var PM1022 = 2.2250738585072014e-308; // 0x1p-1022
	static inline var SIGN_BIAS = 0x800 << 7;

	// scale * (1 + tmp) when it may overflow or underflow (the sign of
	// scale is in sbits, whose exponent may have overflowed into it)
	@:hxmc.noGc static function specialcase(tmp:Float, sbits:I64, ki:I64):Float {
		if (((ki >>> 31) & 1) == 0) {
			// k > 0, the exponent of scale might have overflowed by <= 460
			sbits = sbits - ((1009 : I64) << 52);
			var scale = ofBits(sbits);
			return fma(tmp, scale, scale) * P1009;
		}
		// k < 0, need special care in the subnormal range
		sbits = sbits + ((1022 : I64) << 52);
		var scale = ofBits(sbits);
		var st = tmp * scale;
		var y = scale + st;
		if (Math.abs(y) < 1.0) {
			// round y to the right precision before scaling it into the
			// subnormal range to avoid double rounding
			var one = y < 0.0 ? -1.0 : 1.0;
			var lo = st + (scale - y);
			var hi = y + one;
			lo = lo + (y + (one - hi));
			y = (hi + lo) - one;
			// fix the sign of 0
			if (y == 0.0) y = ofBits(sbits & ((1 : I64) << 63));
		}
		return y * PM1022;
	}

	// exp(x + xtail), negated when signBias is SIGN_BIAS (pow's exp_inline;
	// exp's own is the same with xtail = 0, after its special cases)
	@:hxmc.noGc static inline function expCore(hw:Bool, t:Ptr, x:Float, xtail:Float, hasTail:Bool, signBias:Int, abstop:Int):Float {
		// exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)]
		var z = fm(hw, x, INVLN2N, SHIFT);
		var ki = bits(z);
		var kd = z - SHIFT;
		var r = fm(hw, kd, NEGLN2HIN, x);
		r = fm(hw, kd, NEGLN2LON, r);
		if (hasTail) r = xtail + r;
		// 2^(k/N) ~= scale * (1 + tail)
		var idx = 2 * (ki & 127).toInt();
		var top = (ki + signBias) << 45;
		var tail = ofBits(tl(t, O_EXP_TAB + idx));
		// a valid scale only when -1023*N < k < 1024*N
		var sbits = tl(t, O_EXP_TAB + idx + 1) + top;
		// exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1)
		var r2 = r * r;
		var a = r + tail;
		a = fm(hw, r2, fm(hw, r, EXP_C3, EXP_C2), a);
		var tmp = fm(hw, r2 * r2, fm(hw, r, EXP_C5, EXP_C4), a);
		if (abstop == 0) return specialcase(tmp, sbits, ki);
		var scale = ofBits(sbits);
		return fm(hw, tmp, scale, scale);
	}

	@:hxmc.host("Math_exp") @:hxmc.noGc static function exp(x:Float):Float {
		var abstop = top12(x) & 0x7ff;
		if (ult(62, abstop - 969)) { // |x| < 0x1p-54 or |x| >= 512 or nan
			if (abstop - 969 < 0) return x + 1.0; // tiny x; 0 is common input
			if (abstop > 1032) { // |x| >= 1024
				if (bits(x) == bits(-inf())) return 0.0;
				if (abstop == 2047) return x + 1.0;
				return bits(x) < 0 ? 0.0 : inf(); // __math_uflow(0), __math_oflow(0)
			}
			// large x is special cased below
			abstop = 0;
		}
		return useHw() ? expCore(true, tab(), x, 0, false, 0, abstop) : expCore(false, tab(), x, 0, false, 0, abstop);
	}

	// ---- log (ARM: log.c, log_data.c; LOG_TABLE_BITS 7, LOG_POLY_ORDER 6,
	// LOG_POLY1_ORDER 12, HAVE_FAST_FMA)

	static inline var LN2HI = 0.69314718055989033; // 0x1.62e42fefa38p-1
	static inline var LN2LO = 5.4979230187083712e-14; // 0x1.ef35793c7673p-45
	static inline var LOG_A0 = -0.50000000000000011; // -0x1.0000000000001p-1
	static inline var LOG_A1 = 0.33333333331825593; // 0x1.555555551305bp-2
	static inline var LOG_A2 = -0.24999999996229549; // -0x1.fffffffeb459p-3
	static inline var LOG_A3 = 0.20000304511814496; // 0x1.999b324f10111p-3
	static inline var LOG_A4 = -0.16667054827627667; // -0x1.55575e506c89fp-3
	static inline var LOG_B0 = -0.5;
	static inline var LOG_B1 = 0.3333333333333352; // 0x1.5555555555577p-2
	static inline var LOG_B2 = -0.24999999999998432; // -0x1.ffffffffffdcbp-3
	static inline var LOG_B3 = 0.19999999999320328; // 0x1.999999995dd0cp-3
	static inline var LOG_B4 = -0.16666666669929706; // -0x1.55555556745a7p-3
	static inline var LOG_B5 = 0.14285715076560868; // 0x1.24924a344de3p-3
	static inline var LOG_B6 = -0.12499997863982555; // -0x1.fffffa4423d65p-4
	static inline var LOG_B7 = 0.11110712032936046; // 0x1.c7184282ad6cap-4
	static inline var LOG_B8 = -0.10000486757818193; // -0x1.999eb43b068ffp-4
	static inline var LOG_B9 = 0.091819940061954666; // 0x1.78182f7afd085p-4
	static inline var LOG_B10 = -0.083283630622893415; // -0x1.5521375d145cdp-4

	@:hxmc.host("Math_log") @:hxmc.noGc static function log(x:Float):Float {
		var ix = bits(x);
		var top = (ix >>> 48).toInt();
		// 1 - 0x1p-4 <= x < 1 + 0x1.09p-4: close to 1
		if (Mem.ult(ix - u64(0x3fee0000, 0), u64(0x3ff10900, 0) - u64(0x3fee0000, 0))) {
			// fix the sign of zero with downward rounding when x == 1
			if (ix == u64(0x3ff00000, 0)) return 0;
			return useHw() ? logNear1(true, x) : logNear1(false, x);
		}
		if (ult(32735, top - 0x0010)) {
			// x < 0x1p-1022 or inf or nan
			if (ix << 1 == 0) return -inf(); // __math_divzero(1)
			if (ix == bits(inf())) return x; // log(inf) == inf
			if ((top & 0x8000) != 0 || (top & 0x7ff0) == 0x7ff0) return (x - x) / (x - x); // __math_invalid
			// subnormal: normalize it
			ix = bits(x * 4503599627370496.0); // 0x1p52
			ix = ix - ((52 : I64) << 52);
		}
		return useHw() ? logMain(true, ix) : logMain(false, ix);
	}

	@:hxmc.noGc static inline function logNear1(hw:Bool, x:Float):Float {
		var r = x - 1.0;
		var r2 = r * r;
		var r3 = r * r2;
		var a = fm(hw, LOG_B3, r2, fm(hw, LOG_B2, r, LOG_B1));
		var b = fm(hw, LOG_B6, r2, fm(hw, LOG_B5, r, LOG_B4));
		var c = fm(hw, LOG_B10, r3, fm(hw, LOG_B9, r2, fm(hw, LOG_B8, r, LOG_B7)));
		var p = fm(hw, fm(hw, c, r3, b), r3, a);
		var w = fm(hw, r, 134217728.0, r); // 0x1p27
		var rhi = fm(hw, -r, 134217728.0, w);
		var rlo = r - rhi;
		w = rhi * rhi;
		var hi = fm(hw, w, LOG_B0, r);
		var lo = fm(hw, w, LOG_B0, r - hi);
		lo = fm(hw, LOG_B0 * rlo, r + rhi, lo);
		return hi + fm(hw, p, r3, lo);
	}

	@:hxmc.noGc static inline function logMain(hw:Bool, ix:I64):Float {
		// x = 2^k z; where z is in range [OFF,2*OFF) and exact
		var t = tab();
		var tmp = ix - u64(0x3fe60000, 0);
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt(); // arithmetic shift
		var iz = ix - (tmp & ((0xfff : I64) << 52));
		var invc = td(t, O_LOG_TAB + 2 * i);
		var logc = td(t, O_LOG_TAB + 2 * i + 1);
		var z = ofBits(iz);
		// log(x) = log1p(z/c-1) + log(c) + k*Ln2
		var r = fm(hw, z, invc, -1.0);
		var kd:Float = k;
		// hi + lo = r + log(c) + k*Ln2
		var w = fm(hw, LN2HI, kd, logc);
		var hi = r + w;
		var lo = fm(hw, LN2LO, kd, (w - hi) + r);
		// log(x) = lo + (log1p(r) - r) + hi
		var r2 = r * r;
		var a = fm(hw, LOG_A0, r2, lo);
		var p = fm(hw, fm(hw, LOG_A4, r, LOG_A3), r2, fm(hw, LOG_A2, r, LOG_A1));
		return fm(hw, r * r2, p, a) + hi;
	}

	// ---- pow (ARM: pow.c, pow_log_data.c; POW_LOG_TABLE_BITS 7,
	// POW_LOG_POLY_ORDER 8, HAVE_FAST_FMA)

	static inline var POW_A0 = -0.5;
	static inline var POW_A1 = -0.66666666666666785; // -0x1.555555555556p-1
	static inline var POW_A2 = 0.50000000000000067; // 0x1.0000000000006p-1
	static inline var POW_A3 = 0.79999999953239764; // 0x1.999999959554ep-1
	static inline var POW_A4 = -0.66666666634877392; // -0x1.555555529a47ap-1
	static inline var POW_A5 = -1.1429096284595011; // -0x1.2495b9b4845e9p+0
	static inline var POW_A6 = 1.0000415263675542; // 0x1.0002b8b263fc3p+0

	// log(x) for the bits ix of x (normalized), hi in the result and its
	// tail at `tail`
	@:hxmc.noGc static inline function logInline(hw:Bool, t:Ptr, ix:I64, tail:Ptr):Float {
		var tmp = ix - u64(0x3fe69555, 0);
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt(); // arithmetic shift
		var iz = ix - (tmp & ((0xfff : I64) << 52));
		var z = ofBits(iz);
		var kd:Float = k;
		// log(x) = k*Ln2 + log(c) + log1p(z/c-1)
		var invc = td(t, O_POW_TAB + 3 * i);
		var logc = td(t, O_POW_TAB + 3 * i + 1);
		var logctail = td(t, O_POW_TAB + 3 * i + 2);
		// r = z/c - 1 is exactly representable
		var r = fm(hw, z, invc, -1.0);
		// k*Ln2 + log(c) + r
		var t1 = fm(hw, kd, LN2HI, logc);
		var t2 = r + t1;
		var lo1 = fm(hw, kd, LN2LO, logctail);
		var lo2 = r + (t1 - t2);
		var ar = r * POW_A0;
		var ar2 = r * ar;
		var ar3 = r * ar2;
		// k*Ln2 + log(c) + r + A[0]*r*r
		var hi = t2 + ar2;
		var lo3 = fm(hw, r, ar, -ar2);
		var lo4 = ar2 + (t2 - hi);
		// p = log1p(r) - r - A[0]*r*r
		var q = fm(hw, ar2, fm(hw, ar2, fm(hw, r, POW_A6, POW_A5), fm(hw, r, POW_A4, POW_A3)), fm(hw, r, POW_A2, POW_A1));
		var lo = fm(hw, ar3, q, lo4 + (lo3 + (lo1 + lo2)));
		var y = hi + lo;
		Mem.setF64(tail, 0, lo + (hi - y));
		return y;
	}

	// 0 if not an integer, 1 if odd, 2 if even (iy: a non-zero finite double)
	@:hxmc.noGc static function checkint(iy:I64):Int {
		var e = ((iy >>> 52) & 0x7ff).toInt();
		if (e < 0x3ff) return 0;
		if (e > 0x3ff + 52) return 2;
		if (nz(iy & (((1 : I64) << (0x3ff + 52 - e)) - 1))) return 0;
		if (nz(iy & ((1 : I64) << (0x3ff + 52 - e)))) return 1;
		return 2;
	}

	// 0, infinity or nan
	static inline function zeroinfnan(i:I64):Bool
		return !Mem.ult(i * 2 - 1, bits(inf()) * 2 - 1);

	// a signaling NaN
	static inline function issignaling(x:Float):Bool
		return Mem.ult(u64(0xfff00000, 0), (bits(x) ^ u64(0x00080000, 0)) * 2);

	@:hxmc.host("Math_pow") @:hxmc.noGc static function pow(x:Float, y:Float):Float {
		var signBias = 0;
		var ix = bits(x), iy = bits(y);
		var topx = top12(x), topy = top12(y);
		if (uge(topx - 0x001, 0x7ff - 0x001) || uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) {
			// x < 0x1p-1022 or inf or nan, or |y| < 0x1p-65 or |y| >= 0x1p63 or nan
			if (zeroinfnan(iy)) {
				if (iy * 2 == 0) return issignaling(x) ? x + y : 1.0;
				if (ix == u64(0x3ff00000, 0)) return issignaling(y) ? x + y : 1.0;
				if (Mem.ult(bits(inf()) * 2, ix * 2) || Mem.ult(bits(inf()) * 2, iy * 2)) return x + y;
				if (ix * 2 == u64(0x3ff00000, 0) * 2) return 1.0;
				if (Mem.ult(ix * 2, u64(0x3ff00000, 0) * 2) == ((iy >>> 63) == 0)) return 0.0; // |x|<1 && y==inf or |x|>1 && y==-inf
				return y * y;
			}
			if (zeroinfnan(ix)) {
				var x2 = x * x;
				if (nz(ix >>> 63) && checkint(iy) == 1) x2 = -x2;
				return nz(iy >>> 63) ? 1 / x2 : x2;
			}
			// x and y are non-zero finite
			if (nz(ix >>> 63)) {
				// finite x < 0
				var yint = checkint(iy);
				if (yint == 0) return (x - x) / (x - x); // __math_invalid
				if (yint == 1) signBias = SIGN_BIAS;
				ix = ix & u64(0x7fffffff, 0xffffffff);
				topx &= 0x7ff;
			}
			if (uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) {
				// signBias == 0 here because y is not odd
				if (ix == u64(0x3ff00000, 0)) return 1.0;
				if ((topy & 0x7ff) < 0x3be) {
					// |y| < 2^-65, x^y ~= 1 + y*log(x)
					return Mem.ult(u64(0x3ff00000, 0), ix) ? 1.0 + y : 1.0 - y;
				}
				return Mem.ult(u64(0x3ff00000, 0), ix) == (topy < 0x800) ? inf() : 0.0; // __math_oflow(0), __math_uflow(0)
			}
			if (topx == 0) {
				// normalize subnormal x so its exponent becomes negative
				ix = bits(x * 4503599627370496.0); // 0x1p52
				ix = ix & u64(0x7fffffff, 0xffffffff);
				ix = ix - ((52 : I64) << 52);
			}
		}
		return useHw() ? powCore(true, ix, y, signBias) : powCore(false, ix, y, signBias);
	}

	@:hxmc.noGc static inline function powCore(hw:Bool, ix:I64, y:Float, signBias:Int):Float {
		var t = tab();
		var lop = Mem.stack(8);
		var hi = logInline(hw, t, ix, lop);
		var lo = Mem.getF64(lop, 0);
		var ehi = y * hi;
		var elo = fm(hw, y, lo, fm(hw, y, hi, -ehi));
		// exp_inline (ehi, elo, signBias)
		var abstop = top12(ehi) & 0x7ff;
		if (ult(62, abstop - 969) && (abstop - 969 < 0 || abstop > 1032)) return powEdge(ehi, signBias, abstop);
		// large x is special cased in expCore
		if (ult(62, abstop - 969)) abstop = 0;
		return expCore(hw, t, ehi, elo, true, signBias, abstop);
	}

	// exp_inline's results for tiny and huge x
	@:hxmc.noGc static function powEdge(ehi:Float, signBias:Int, abstop:Int):Float {
		if (abstop - 969 < 0) {
			// tiny x; 0 is common input
			var one = ehi + 1.0;
			return signBias != 0 ? -one : one;
		}
		// inf and nan are handled already: __math_uflow, __math_oflow
		var neg = signBias != 0;
		if (bits(ehi) < 0) return neg ? ofBits((1 : I64) << 63) : 0.0;
		return neg ? -inf() : inf();
	}

	// ---- fmod (`%`): musl's (exact), on WebAssembly (the C library's on the
	// other targets: exact too; floor and ceil are WebAssembly instructions)

	#if (hxmc.target == "wasm32-wasi")
	@:hxmc.export("fmod") @:hxmc.noGc public static function fmod(x:Float, y:Float):Float {
		var ux = bits(x), uy = bits(y);
		var ex = ((ux >>> 52) & 0x7ff).toInt();
		var ey = ((uy >>> 52) & 0x7ff).toInt();
		var sx = ux >>> 63;
		var uxi = ux;
		if ((uy << 1) == 0 || y != y || ex == 0x7ff) return (x * y) / (x * y);
		if (Mem.ult(ux << 1, uy << 1) || (ux << 1) == (uy << 1)) {
			if ((ux << 1) == (uy << 1)) return 0 * x;
			return x;
		}
		// normalize x and y
		if (ex == 0) {
			var i = uxi << 12;
			while ((i >>> 63) == 0) {
				ex--;
				i = i << 1;
			}
			uxi = uxi << (-ex + 1);
		} else {
			uxi = uxi & ((-1 : I64) >>> 12);
			uxi = uxi | ((1 : I64) << 52);
		}
		if (ey == 0) {
			var i = uy << 12;
			while ((i >>> 63) == 0) {
				ey--;
				i = i << 1;
			}
			uy = uy << (-ey + 1);
		} else {
			uy = uy & ((-1 : I64) >>> 12);
			uy = uy | ((1 : I64) << 52);
		}
		// x mod y
		while (ex > ey) {
			var i = uxi - uy;
			if ((i >>> 63) == 0) {
				if (i == 0) return 0 * x;
				uxi = i;
			}
			uxi = uxi << 1;
			ex--;
		}
		var i = uxi - uy;
		if ((i >>> 63) == 0) {
			if (i == 0) return 0 * x;
			uxi = i;
		}
		while ((uxi >>> 52) == 0) {
			uxi = uxi << 1;
			ex--;
		}
		// scale result
		if (ex > 0) {
			uxi = uxi - ((1 : I64) << 52);
			uxi = uxi | ((ex : I64) << 52);
		} else
			uxi = uxi >>> (-ex + 1);
		uxi = uxi | (sx << 63);
		return ofBits(uxi);
	}

	// WebAssembly has instructions for these (wasm.LinkWasm)
	#end

	// ---- the tables (ARM's exp_data.c, log_data.c, pow_log_data.c)

	// 256 words
	static inline var EXP_TAB = "00000000000000003ff00000000000003c9b3b4f1a88bf6e3feff63da9fb3335bc7160139cd8dc5d3fefec9a3e778061bc905e7a108766d13fefe315e86e7f853c8cd2523567f6133fefd9b0d3158574bc8bce8023f98efa3fefd06b29ddf6de3c60f74e61e6c8613fefc74518759bc83c90a3e45b33d3993fefbe3ecac6f3833c979aa65d837b6d3fefb5586cf9890f3c8eb51a92fdeffc3fefac922b7247f73c3ebe3d702f9cd13fefa3ec32d3d1a2bc6a033489906e0b3fef9b66affed31bbc9556522a2fbd0e3fef9301d0125b51bc5080ef8c4eea553fef8abdc06c31ccbc91c923b9d5f4163fef829aaea92de03c80d3e3e95c55af3fef7a98c8a58e51bc801b15eaa593483fef72b83c7d517bbc8f1ff055de323d3fef6af9388c8dea3c8b898c3f1353bf3fef635beb6fcb75bc96d99c7611eb263fef5be084045cd43c9aecf73e3a2f603fef54873168b9aabc8fe782cb86389d3fef4d5022fcd91d3c8a6f4144a6c38d3fef463b88628cd63c807a05b0e4047d3fef3f49917ddc963c968efde3a8a8943fef387a6e7562383c875e18f274487d3fef31ce4fb2a63f3c80472b981fe7f23fef2b4565e27cddbc96b87b3f71085e3fef24dfe1f563813c82f7e16d09ab313fef1e9df51fdee1bc3d219b1a6fbffa3fef187fd0dad9903c8b3782720c0ab43fef1285a6e4030b3c6e149289cecb8f3fef0cafa93e2f563c834d754db0abb63fef06fe0a31b7153c864201e2ac744c3fef0170fc4cd8313c8fdd395dd3f84a3feefc08b26416ffbc86a3803b8e5b043feef6c55f929ff1bc924aedcc4b50683feef1a7373aa9cbbc9907f81b512d8e3feeecae6d05d866bc71d1e83e9436d23feee7db34e59ff7bc991919b3ce1b153feee32dc313a8e53c859f48a72a4c6d3feedea64c123422bc9312607a28698a3feeda4504ac801cbc58a78f4817895b3feed60a21f72e2abc7c2c9b67499a1b3feed1f5d950a8973c4363ed60c2ac113feece086061892d3c9666093b0664ef3feeca41ed1d00573c6ecce1daa103793feec6a2b5c13cd03c93ff8e3f0f12303feec32af0d7d3de3c7690cebb7aafb03feebfdad5362a273c931dbdeb54e0773feebcb299fddd0dbc8f94340071a38e3feeb9b2769d2ca7bc87deccdc93a3493feeb6daa2cf6642bc78dec6bd0f385f3feeb42b569d4f82bc861246ec7b5cf63feeb1a4ca5d920f3c93350518fdd78e3feeaf4736b527da3c7b98b72f8a9b053feead12d497c7fd3c9063e1e21c54093feeab07dd4854293c34c7855019c6ea3feea9268a5946b73c9432e62b64c0353feea76f15ad2148bc8ce44a6199769f3feea5e1b976dc09bc8c33c53bef4da83feea47eb03a5585bc845378892be9ae3feea34634ccc320bc93cedd785658583feea238825522253c5710aa807e19643feea155d44ca973bc93b3efbf5e22283feea09e667f3bcdbc6a12ad8734b9823feea012750bdabfbc6367efb86da9ee3fee9fb23c651a2fbc80dc3d54e088513fee9f7df9519484bc781f647e5a3ecf3fee9f75e8ec5f74bc86ee4ac08b7db03fee9f9a48a58174bc8619321e55e68a3fee9feb564267c93c909ccb5e09d4d33feea0694fde5d3fbc7b32dcb94da51d3feea11473eb01873c94ecfd5467c06b3feea1ed0130c1323c65ebe1abd66c553feea2f336cf4e62bc88a1c52fb3cf423feea427543e1a12bc9369b6f13b37343feea589994cce13bc805e843a19ff1e3feea71a4623c7adbc94d450d872576e3feea8d99b4492ed3c90ad675b0e8a003feeaac7d98a66993c8db72fc1f0eab43feeace5422aa0dbbc65b6609cc5e7ff3feeaf3216b5448c3c7bf68359f35f443feeb1ae99157736bc93091fa71e3d833feeb45b0b91ffc6bc5da9b88b6c1e293feeb737b0cdc5e5bc6c23f97c90b9593feeba44cbc8520fbc92434322f4f9aa3feebd829fde4e50bc85ca6cd7668e4b3feec0f170ca07ba3c71affc2b91ce273feec49182a3f0903c6dd235e10a73bb3feec86319e32323bc87c504226222633feecc667b5de5653c8b1c86e3e231d53feed09bec4a2d33bc91bbd1d3bcbb153feed503b23e255d3c90cc319cee31d23feed99e1330b3583c8469846e735ab33feede6b5579fdbfbc82dfcd978e9db43feee36bbfd3f37a3c8c1a7792cb33873feee89f995ad3adbc907b8f4ad1d9fa3feeee07298db666bc55c3d956dcaeba3feef3a2b84f15fbbc90a40e3da6f6403feef9728de5593abc68d6f438ad93343feeff76f2fb5e47bc91eee26b588a353fef05b030a1064a3c74ffd70a5fddcd3fef0c1e904bc1d2bc91bdfbfa9298ac3fef12c25bd71e093c736eae30af0cb33fef199bdd85529c3c8ee3325c9ffd943fef20ab5fffd07a3c84e08fd10959ac3fef27f12e57d14b3c63cdaf384e1a673fef2f6d9406e7b53c676b2c6c9219683fef3720dcef9069bc808a1883ccb5d23fef3f0b555dc3fabc8fad5d3ffffa6f3fef472d4a07897cbc900dae3875a9493fef4f87080d89f23c74a385a63d07a73fef5818dcfba487bc82919e2040220f3fef60e316c983983c8e5a50d5c192ac3fef69e603db32853c843a59ac016b4b3fef7321f301b460bc82d52107b43e1f3fef7c97337b9b5fbc892ab93b470dc93fef864614f5a1293c74b604603a88d33fef902ee78b3ff63c83c5ec519d72713fef9a51fbc74c83bc8ff7128fd391f03fefa4afa2a490dabc8dae98e223747d3fefaf482d8e67f13c8ec3bc41aa20083fefba1bee615a273c842b94c3a9eb323fefc52b376bba973c8a64a931d185ee3fefd0765b6e4540bc8e37bae43be3ed3fefdbfdad9cbe143c77893b4d91cd9d3fefe7c1819e90d83c5305c14160cc893feff3c22b8f71f1";
	// 256 words
	static inline var LOG_TAB = "3ff734f0c3e0de9fbfd7cc7f79e690003ff713786a2ce91fbfd76feec20d00003ff6f26008fab5a0bfd713e31351e0003ff6d1a61f138c7dbfd6b85b382878003ff6b1490bc5b4d1bfd65d55908078003ff69147332f0cbabfd602d0761800003ff6719f18224223bfd5a8ca869090003ff6524f99a51ed9bfd54f43560350003ff63356aa8f24c4bfd4f637c36b40003ff614b36b9ddc14bfd49da7fda850003ff5f66452c65c4cbfd445923989a8003ff5d867b5912c4fbfd3edf439b0b8003ff5babccb5b90debfd396ce448f70003ff59d61f2d91a78bfd3401e17bda0003ff5805612465687bfd2e9e2ef4680003ff56397cee76bd3bfd2941b3830e0003ff54725e2a77f93bfd23ec58cda88003ff52aff42064583bfd1e9e1292790003ff50f22dbb2bddfbfd1956d2b48f8003ff4f38f4734ded7bfd141679ab9f8003ff4d843cfde2840bfd0edd094ef98003ff4bd3ec078a3c8bfd09aa518db10003ff4a27fc3e0258abfd047e65263b8003ff4880524d48434bfcfeb224586f0003ff46dce1b192d0bbfcf474a7517b0003ff453d9d3391854bfcea4443d1030003ff43a2744b4845abfce020d44e9b0003ff420b54115f8fbbfcd60a22977f0003ff40782da3ef4b1bfccc001049590003ff3ee8f5d57fe8fbfcc2029568910003ff3d5d9a00b4ce9bfcb81178d8110003ff3bd60c010c12bbfcae2c9ccd3d0003ff3a5242b75dab8bfca45402e1290003ff38d22cd9fd002bfc9a877681df0003ff3755bc5847a1cbfc90c6d694830003ff35dce49ad36e2bfc87120a645c0003ff34679984dd440bfc7d68fb41430003ff32f5cceffcb24bfc73cb83c6270003ff3187775a10d49bfc6a39a9b3760003ff301c8373e3990bfc60b3154b7a0003ff2eb4ebb95f841bfc5737d762430003ff2d50a0219a9d1bfc4dc7b8fc230003ff2bef9a8b7fd2abfc4462c51d200003ff2a91c7a0c1babbfc3b08abc8300003ff293726014b530bfc31b996b4900003ff27dfa5757a1f5bfc2875490a440003ff268b39b1d3bbfbfc1f3b9f879a0003ff2539d838ff5bdbfc160c8252ca0003ff23eb7aac9083bbfc0ce7f57f720003ff22a012ba940b6bfc03cdc49fea0003ff2157996cc4132bfbf57bdbc4b80003ff201201dd2fc9bbfbe3708964040003ff1ecf4494d480bbfbd17983ef940003ff1d8f5528f6569bfbbf9674ed8a0003ff1c52311577e7cbfbadc79202f60003ff1b17c74cb26e9bfb9c0c3e72880003ff19e010c2c1ab6bfb8a646b372c0003ff18ab07bb670bdbfb78d01b3ac00003ff1778a25efbcb6bfb674f1453800003ff1648d354c31dabfb55e0e6d8780003ff151b990275fddbfb4485cdea1e0003ff13f0ea432d24cbfb333d94d6aa0003ff12c8b7210f9dabfb22079f8c560003ff11a3028ecb531bfb10e46986220003ff107fbda8434afbfaffa6c6ad200003ff0f5ee0f4e6bb3bfadda8d4a7740003ff0e4065d2a9fcebfabbcece48500003ff0d244632ca521bfa9a1894012c0003ff0c0a77ce2981abfa788583302c0003ff0af2f83c636d1bfa5715e67d680003ff09ddb98a01339bfa35c8a496580003ff08cabaf52e7dfbfa149e3641540003ff07b9f2f4e28fbbf9e72c082eb80003ff06ab58c358f19bf9a55f1525280003ff059eea5ecf92cbf963d62cf8180003ff04949cdd12c90bf9228fb8caa00003ff038c6c6f0ada9bf8c317b20f900003ff02865137932a9bf8419355daa00003ff0182427ea7348bf781203c2ec00003ff008040614b195bf600409792400003fefe01ff726fa1a3f6feff3849000003fefa11cc261ea743f87dc41353d00003fef6310b081992e3f93cea3c4c280003fef25f63ceeadcd3f9b9fc1148900003feee9c8039113e73fa1b0d8ce1100003feeae8078cbb1ab3fa58a5bd001c0003fee741aa29d0c9b3fa95c8340d880003fee3a91830a99b53fad276aef5780003fee01e009609a563fb07598e598c0003fedca01e577bb983fb253f5e30d20003fed92f20b7c91033fb42edd8b3800003fed5cac66fb5cce3fb606598757c0003fed272caa5ede9d3fb7da76356a00003fecf26e3e6b2ccd3fb9ab434e1c60003fecbe6da2a779023fbb78c7bb0d60003fec8b266d37086d3fbd431332e720003fec5894bd5d58043fbf0a3171de60003fec26b533bb9f8c3fc067152b9140003febf583eeece73f3fc147858292b0003febc4fd75db96c13fc2266ecdca30003feb951e0c864a283fc303d7a6c550003feb65e2c5ef3e2c3fc3dfc33c3310003feb374867c9888b3fc4ba366b7a80003feb094b211d304a3fc5933928d1f0003feadbe885f2ef7e3fc66acd2418f0003feaaf1d31603da23fc740f8ec6690003fea82e63fd358a73fc815c0f51af0003fea5740ef09738b3fc8e92954f680003fea2c2a90ab4b273fc9bb3602f840003fea01a01393f2d13fca8bed1c2c00003fe9d79f24db3c1b3fcb5b515c01d0003fe9ae2505c7b1903fcc2967ccbcc0003fe9852ef297ce2f3fccf635d54860003fe95cbaeea44b753fcdc1bd3446c0003fe934c69de748383fce8c01b8cfe0003fe90d4f2f6752e63fcf5509c01790003fe8e6528effd79d3fd00e6c121fb8003fe8bfce9fcc007c3fd071b80e93d0003fe899c0dabec30e3fd0d46b9e8670003fe87427aa2317fb3fd13687334bd0003fe84f00acb39a083fd1980d672348003fe82a49e8653e553fd1f8ffe0cc80003fe8060195f402603fd2595fd76368003fe7e22563e0a3293fd2b9300914a8003fe7beb377dcb5ad3fd31872104360003fe79baa679725c23fd377266dec18003fe77907f21706573fd3d54ffbaf30003fe756cadbd6130c3fd432eee32fe000";
	// 384 words
	static inline var POW_TAB = "3ff6a00000000000bfd62c82f2b9c8003cfab424283756803ff6800000000000bfd5d1bdbf580800bd1ca508d8e0f7203ff6600000000000bfd5767717455800bd2362a4d5b6506d3ff6400000000000bfd51aad872df800bce684e49eb067d53ff6200000000000bfd4be5f95777800bd041b6993293ee03ff6000000000000bfd4618bc21c60003d13d82f484c84cc3ff5e00000000000bfd404308686a8003cdc42f3ed820b3a3ff5c00000000000bfd3a64c556948003d20b1c6865194603ff5a00000000000bfd347dd9a9880003d25594dd4c580923ff5800000000000bfd2e8e2bae120003d267b1e99b72bd83ff5600000000000bfd2895a13de88003d15ca14b6cfb03f3ff5600000000000bfd2895a13de88003d15ca14b6cfb03f3ff5400000000000bfd22941fbcf7800bd165a242853da763ff5200000000000bfd1c898c1699800bd1fafbc68e754043ff5000000000000bfd1675cababa8003d1f1fc63382a8f03ff4e00000000000bfd1058bf9ae4800bd26a8c4fd055a663ff4c00000000000bfd0a324e2739000bd0c6bee7ef4030e3ff4a00000000000bfd0402594b4d000bcf036b89ef42d7f3ff4a00000000000bfd0402594b4d000bcf036b89ef42d7f3ff4800000000000bfcfb9186d5e40003d0d572aab993c873ff4600000000000bfcef0adcbdc60003d2b26b79c86af243ff4400000000000bfce27076e2af000bd172f4f543fff103ff4200000000000bfcd5c216b4fc0003d21ba91bbca681b3ff4000000000000bfcc8ff7c79aa0003d27794f689f84343ff4000000000000bfcc8ff7c79aa0003d27794f689f84343ff3e00000000000bfcbc286742d90003d194eb0318bb78f3ff3c00000000000bfcaf3c94e80c0003cba4e633fcd90663ff3a00000000000bfca23bc1fe2b000bd258c64dc46c1ea3ff3a00000000000bfca23bc1fe2b000bd258c64dc46c1ea3ff3800000000000bfc9525a9cf45000bd2ad1d904c1d4e33ff3600000000000bfc87fa06520d0003d2bbdbf7fdbfa093ff3400000000000bfc7ab890210e0003d2bdb9072534a583ff3400000000000bfc7ab890210e0003d2bdb9072534a583ff3200000000000bfc6d60fe719d000bd10e46aa3b2e2663ff3000000000000bfc5ff3070a79000bd1e9e439f1050393ff3000000000000bfc5ff3070a79000bd1e9e439f1050393ff2e00000000000bfc526e5e3a1b000bd20de8b90075b8f3ff2c00000000000bfc44d2b6ccb80003d170cc16135783c3ff2c00000000000bfc44d2b6ccb80003d170cc16135783c3ff2a00000000000bfc371fc201e90003cf178864d27543a3ff2800000000000bfc29552f81ff000bd248d301771c4083ff2600000000000bfc1b72ad52f6000bd2e80a41811a3963ff2600000000000bfc1b72ad52f6000bd2e80a41811a3963ff2400000000000bfc0d77e7cd090003d0a699688e85bf43ff2400000000000bfc0d77e7cd090003d0a699688e85bf43ff2200000000000bfbfec9131dbe000bd2575545ca333f23ff2000000000000bfbe27076e2b00003d2a342c2af0003c3ff2000000000000bfbe27076e2b00003d2a342c2af0003c3ff1e00000000000bfbc5e548f5bc000bd1d0c57585fbe063ff1c00000000000bfba926d3a4ae0003d253935e85baac83ff1c00000000000bfba926d3a4ae0003d253935e85baac83ff1a00000000000bfb8c345d631a0003d137c294d2f56683ff1a00000000000bfb8c345d631a0003d137c294d2f56683ff1800000000000bfb6f0d28ae56000bd269737c93373da3ff1600000000000bfb51b073f0620003d1f025b61c65e573ff1600000000000bfb51b073f0620003d1f025b61c65e573ff1400000000000bfb341d7961be0003d2c5edaccf913df3ff1400000000000bfb341d7961be0003d2c5edaccf913df3ff1200000000000bfb16536eea380003d147c5e768fa3093ff1000000000000bfaf0a30c01180003d2d599e83368e913ff1000000000000bfaf0a30c01180003d2d599e83368e913ff0e00000000000bfab42dd711980003d1c827ae5d6704c3ff0e00000000000bfab42dd711980003d1c827ae5d6704c3ff0c00000000000bfa77458f632c000bd2cfc4634f2a1ee3ff0c00000000000bfa77458f632c000bd2cfc4634f2a1ee3ff0a00000000000bfa39e87b9fec0003cf502b7f526feaa3ff0a00000000000bfa39e87b9fec0003cf502b7f526feaa3ff0800000000000bf9f829b0e780000bd2980267c7e09e43ff0800000000000bf9f829b0e780000bd2980267c7e09e43ff0600000000000bf97b91b07d58000bd288d5493faa6393ff0400000000000bf8fc0a8b0fc0000bcdf1e7cf6d3a69c3ff0400000000000bf8fc0a8b0fc0000bcdf1e7cf6d3a69c3ff0200000000000bf7fe02a6b100000bd19e23f0dda40e43ff0200000000000bf7fe02a6b100000bd19e23f0dda40e43ff0000000000000000000000000000000000000000000003ff0000000000000000000000000000000000000000000003fefc000000000003f80101575890000bd10c76b999d2be83fef8000000000003f90205658938000bd23dc5b06e2f7d23fef4000000000003f98492528c90000bd2aa0ba325a0c343fef0000000000003fa0415d89e740003d0111c05cf1d7533feec000000000003fa466aed42e0000bd2c167375bdfd283fee8000000000003fa894aa149fc000bd197995d05a267d3fee4000000000003faccb73cdddc000bd1a68f247d828073fee2000000000003faeea31c006c000bd0e113e4fc93b7b3fede000000000003fb1973bd1466000bd25325d560d9e9b3feda000000000003fb3bdf5a7d1e0003d2cc85ea5db4ed73fed6000000000003fb5e95a4d97a000bd2c69063c5d1d1e3fed4000000000003fb700d30aeac0003cec1e8da99ded323fed0000000000003fb9335e5d5940003d23115c3abd47da3fecc000000000003fbb6ac88dad6000bd1390802bf768e53feca000000000003fbc885801bc40003d2646d1c65aacd33fec6000000000003fbec739830a2000bd2dc068afe645e03fec4000000000003fbfe89139dbe000bd2534d64fa10afd3fec0000000000003fc1178e8227e0003d21ef78ce2d07f23febe000000000003fc1aa2b7e23f0003d2ca78e443899343feba000000000003fc2d1610c8680003d039d6ccb81b4a13feb8000000000003fc365fcb01590003cc62fa8234b72893feb4000000000003fc4913d8333b0003d25837954fdb6783feb2000000000003fc527e5e4a1b0003d2633e8e5697dc73feae000000000003fc6574ebe8c10003d19cf8b2c3c2e783feac000000000003fc6f0128b757000bd25118de59c21e13feaa000000000003fc7898d85445000bd1c6610709143053fea6000000000003fc8beafeb390000bd073d54aae92cd13fea4000000000003fc95a5adcf700003d07f22858a0ff6f3fea0000000000003fca93ed3c8ae000bd287243505621693fe9e000000000003fcb31d8575bd000bd0c358d4eace1aa3fe9c000000000003fcbd087383be000bd2d4bc4595412b63fe9a000000000003fcc6ffbc6f01000bcf1ec72c5962bd23fe96000000000003fcdb13db0d49000bd2aff2af715b0353fe94000000000003fce530effe710003cc212276041f4303fe92000000000003fcef5ade4dd0000bcca211565bb8e113fe90000000000003fcf991c6cb3b0003d1bcbecca0cdf303fe8c000000000003fd07138604d58003cf89cdb16ed4e913fe8a000000000003fd0c42d676160003d27188b163ceae93fe88000000000003fd1178e8227e800bd2c210e63a5f01c3fe86000000000003fd16b5ccbacf8003d2b9acdf7a516813fe84000000000003fd1bf99635a68003d2ca6ed5147bdb73fe82000000000003fd214456d0eb8003d0a87deba46baea3fe7e000000000003fd2bef07cdc90003d2a9cfa4a5004f43fe7c000000000003fd314f1e1d36000bd28e27ad3213cb83fe7a000000000003fd36b6776be10003d116ecdb0f177c83fe78000000000003fd3c252773330003d183b54b606bd5c3fe76000000000003fd419b423d5e8003d08e436ec90e09d3fe74000000000003fd4718dc271c800bd2f27ce0967d6753fe72000000000003fd4c9e09e173000bd2e20891b0ad8a43fe70000000000003fd522ae0738a0003d2ebe708164c7593fe6e000000000003fd57bf753c8d0003d1fadedee5d40ef3fe6c000000000003fd5d5bddf596000bd0a0b2a08a465dc";
}
