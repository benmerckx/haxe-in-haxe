package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// sin, cos and tan, correctly rounded: the CORE-MATH project's
// src/binary64/cos/cos.c and tan/tan.c (commit dae5dd8, 2026-10-15) and
// sin/sin.c as of commit 8ea8ea35 (2026-02-21: the version that shares
// cos.c's and tan.c's algorithm and tables; its rewrite of 2026-09 is
// newer than this port) by Paul Zimmermann and Tom Hubrecht, MIT
// (hxmc/std/hxmc/rt/LICENSE.libm).
//
// A fast path in double-double arithmetic, with a rigorous error bound,
// rounds correctly unless the bound straddles a rounding boundary; then an
// accurate path with 128-bit significands (dint: in memory, 32 bytes: lo,
// hi, ex, sgn) decides. Rounding to nearest only (Haxe has no other mode).
// C's __builtin_fma is LibM.fm: the processor's fma, else LibM.fmaSoft
// (exact; where it computes the exact error of a product, a_mul, Dekker's
// product LibM.mulErr, exact too). The fast paths are specialized for both
// (hw, LibM.useHw).
@:keep @:allow(hxmc.rt)
class LibMTrig {
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

	static inline function nz(x:I64):Bool
		return !(x == 0);

	static inline function u64(hi:Int, lo:Int):I64
		return ((hi : I64) << 32) | (((lo : I64) << 32) >>> 32);

	static inline function ult(a:I64, b:I64):Bool
		return Mem.ult(a, b);

	static inline function clz(x:I64):Int
		return LibM.clz64(x);

	static inline function mulhi(a:I64, b:I64):I64
		return LibM.mulhi(a, b);

	// ---- the tables, in memory on first use (as LibM's)

	static var tabs:Ptr;

	static inline var O_T = 0; // 20 words
	static inline var O_S = 20; // 256 dints
	static inline var O_C = 1044; // 256 dints
	static inline var O_PS = 2068; // 6 dints
	static inline var O_PC = 2092; // 6 dints
	static inline var O_SC = 2116; // 256 * 3 doubles
	static inline var O_TINV = 2884; // 256 words
	static inline var O_ZERO = 3140; // the dints ZERO, MAGIC (2^-11), ONE
	static inline var O_MAGIC = 3144;
	static inline var O_ONE = 3148;
	static inline var NTAB = 3152;

	// dints: hi and lo (16 hex digits each), then ex << 1 | sgn (4)
	@:hxmc.noGc static function loadDints(t:Ptr, lit:String, at:Int):Void {
		var n = Std.int(Str.len(lit) / 36);
		for (i in 0...n) {
			var hi:I64 = 0, lo:I64 = 0, es = 0;
			for (k in 0...16) {
				hi = (hi << 4) | LibM.hexDigit(Str.unit(lit, i * 36 + k));
				lo = (lo << 4) | LibM.hexDigit(Str.unit(lit, i * 36 + 16 + k));
			}
			for (k in 0...4)
				es = (es << 4) | LibM.hexDigit(Str.unit(lit, i * 36 + 32 + k));
			setDint(t.add(8 * (at + 4 * i)), hi, lo, (es << 16) >> 17, es & 1);
		}
	}

	@:hxmc.noGc static function tab():Ptr {
		var t = tabs;
		if (!t.isNull()) return t;
		t = LibC.malloc(8 * NTAB);
		LibM.load(t, T, O_T, 16);
		loadDints(t, S, O_S);
		loadDints(t, C, O_C);
		loadDints(t, PS, O_PS);
		loadDints(t, PC, O_PC);
		LibM.load(t, SC, O_SC, 16);
		LibM.load(t, TINV, O_TINV, 16);
		setDint(t.add(8 * O_ZERO), 0, 0, -1076, 0);
		setDint(t.add(8 * O_MAGIC), (1 : I64) << 63, 0, -10, 0);
		setDint(t.add(8 * O_ONE), (1 : I64) << 63, 0, 1, 0);
		Atomic.fence();
		tabs = t;
		return t;
	}

	static inline function tw(t:Ptr, i:Int):I64
		return Mem.getI64(t, 8 * i);

	static inline function sc(t:Ptr, i:Int, j:Int):Float
		return Mem.getF64(t, 8 * (O_SC + 3 * i + j));

	static inline function dintAt(t:Ptr, o:Int, i:Int):Ptr
		return t.add(8 * (o + 4 * i));

	// ---- dint64_t: 128-bit significands (code copied from dint.h and pow.[ch])

	static inline function dLo(p:Ptr):I64
		return Mem.getI64(p, 0);

	static inline function dHi(p:Ptr):I64
		return Mem.getI64(p, 8);

	static inline function dEx(p:Ptr):Int
		return Mem.getI32(p, 16);

	static inline function dSgn(p:Ptr):Int
		return Mem.getI32(p, 24);

	static inline function setDint(p:Ptr, hi:I64, lo:I64, ex:Int, sgn:Int):Void {
		Mem.setI64(p, 0, lo);
		Mem.setI64(p, 8, hi);
		Mem.setI32(p, 16, ex);
		Mem.setI32(p, 24, sgn);
	}

	static inline function cpDint(r:Ptr, a:Ptr):Void
		setDint(r, dHi(a), dLo(a), dEx(a), dSgn(a));

	// 128-bit shifts of hi:lo by 0 <= s < 128 (the halves)
	static inline function shlHi(h:I64, l:I64, s:Int):I64
		return s == 0 ? h : s < 64 ? (h << s) | (l >>> (64 - s)) : l << (s - 64);

	static inline function shlLo(l:I64, s:Int):I64
		return s == 0 ? l : s < 64 ? l << s : 0;

	static inline function shrHi(h:I64, s:Int):I64
		return s == 0 ? h : s < 64 ? h >>> s : 0;

	static inline function shrLo(h:I64, l:I64, s:Int):I64
		return s == 0 ? l : s < 64 ? (l >>> s) | (h << (64 - s)) : h >>> (s - 64);

	// -1, 0, +1 as |a| <, =, > |b|
	@:hxmc.noGc static function cmpDintAbs(a:Ptr, b:Ptr):Int {
		if (dHi(a) == 0) return dHi(b) == 0 ? 0 : -1;
		if (dHi(b) == 0) return 1;
		var ea = dEx(a), eb = dEx(b);
		if (ea != eb) return ea > eb ? 1 : -1;
		var ah = dHi(a), bh = dHi(b);
		if (!(ah == bh)) return ult(ah, bh) ? -1 : 1;
		var al = dLo(a), bl = dLo(b);
		if (al == bl) return 0;
		return ult(al, bl) ? -1 : 1;
	}

	// r = a + b, with error bounded by 2 ulps (r may be a or b)
	@:hxmc.noGc static function addDint(t:Ptr, r:Ptr, a:Ptr, b:Ptr):Void {
		if (!nz(dHi(a) | dLo(a))) {
			cpDint(r, b);
			return;
		}
		switch cmpDintAbs(a, b) {
			case 0:
				if ((dSgn(a) ^ dSgn(b)) != 0) {
					cpDint(r, t.add(8 * O_ZERO));
					return;
				}
				cpDint(r, a);
				Mem.setI32(r, 16, dEx(r) + 1);
				return;
			case -1: // |A| < |B|: swap
				var tmp = a;
				a = b;
				b = tmp;
			case _:
		}
		// |A| > |B| thus a.ex >= b.ex
		var ah = dHi(a), al = dLo(a), bh0 = dHi(b), bl0 = dLo(b);
		var bh = bh0, bl = bl0;
		var k = dEx(a) - dEx(b);
		if (k > 0) {
			if (k < 128) {
				bl = shrLo(bh, bl, k);
				bh = shrHi(bh, k);
			} else {
				bh = 0;
				bl = 0;
			}
		}
		var ch:I64, cl:I64;
		var sgn = dSgn(a);
		var ex = dEx(a); // tentative exponent for the result
		if ((dSgn(a) ^ dSgn(b)) != 0) {
			// different signs: C = A - B (exact in the Sterbenz cases)
			cl = al - bl;
			ch = ah - bh - (ult(al, bl) ? 1 : 0);
			var sh = nz(ch) ? clz(ch) : 64 + clz(cl);
			if (sh > 0) {
				var xh = shlHi(ah, al, sh), xl = shlLo(al, sh);
				var yh:I64, yl:I64;
				if (k == 1) { // Sterbenz case
					yh = shlHi(bh0, bl0, sh - 1);
					yl = shlLo(bl0, sh - 1);
				} else {
					yh = shlHi(bh, bl, sh);
					yl = shlLo(bl, sh);
				}
				cl = xl - yl;
				ch = xh - yh - (ult(xl, yl) ? 1 : 0);
				ex -= sh;
				sh = clz(ch);
			}
			var nh = shlHi(ch, cl, sh);
			cl = shlLo(cl, sh);
			ch = nh;
			ex -= sh;
		} else {
			cl = al + bl;
			ch = ah + bh + (ult(cl, al) ? 1 : 0);
			if (ult(ch, ah) || (ch == ah && ult(cl, al))) { // C < A: carry out
				cl = (cl >>> 1) | (ch << 63);
				ch = ((1 : I64) << 63) | (ch >>> 1);
				ex++;
			}
		}
		setDint(r, ch, cl, ex, sgn);
	}

	// r = a * b, with error bounded by 6 ulps (r may be a or b)
	@:hxmc.noGc static function mulDint(r:Ptr, a:Ptr, b:Ptr):Void {
		var ah = dHi(a), al = dLo(a), bh = dHi(b), bl = dLo(b);
		var m1 = mulhi(ah, bl), m2 = mulhi(al, bh);
		var rl = ah * bh, rh = mulhi(ah, bh);
		var s = rl + m1;
		rh += ult(s, rl) ? 1 : 0;
		rl = s;
		s = rl + m2;
		rh += ult(s, rl) ? 1 : 0;
		rl = s;
		// rh starts with a 1
		var e = (rh >>> 63).toInt();
		if (e == 0) {
			rh = (rh << 1) | (rl >>> 63);
			rl = rl << 1;
		}
		setDint(r, rh, rl, dEx(a) + dEx(b) + e - 1, dSgn(a) ^ dSgn(b));
	}

	// r = a * b, assuming b.lo = 0, with error bounded by 2 ulps
	@:hxmc.noGc static function mulDint21(r:Ptr, a:Ptr, b:Ptr):Void {
		var ah = dHi(a), al = dLo(a), bh = dHi(b);
		var rl = ah * bh, rh = mulhi(ah, bh);
		var m = mulhi(al, bh);
		var s = rl + m;
		rh += ult(s, rl) ? 1 : 0;
		rl = s;
		var e = (rh >>> 63).toInt();
		if (e == 0) {
			rh = (rh << 1) | (rl >>> 63);
			rl = rl << 1;
		}
		setDint(r, rh, rl, dEx(a) + dEx(b) + e - 1, dSgn(a) ^ dSgn(b));
	}

	// a = b, a non-zero double
	@:hxmc.noGc static function dintFromd(a:Ptr, b:Float):Void {
		var u = bits(b);
		var e = ((u >>> 52) & 0x7ff).toInt();
		var m = (u & (((1 : I64) << 52) - 1)) + (e != 0 ? (1 : I64) << 52 : 0);
		e = e - 0x3fe;
		// |b| = 2^(e-52)*m
		var t = clz(m);
		setDint(a, m << t, 0, e - (t > 11 ? t - 12 : 0), b < 0.0 ? 1 : 0);
	}

	@:hxmc.noGc static function subnormalizeDint(a:Ptr):Void {
		if (dEx(a) > -1023) return;
		var ex = -(1011 + dEx(a));
		var ahi = dHi(a);
		var hi = ex < 64 ? ahi >>> ex : 0;
		var md = ex - 1 < 64 ? (ahi >>> (ex - 1)) & 1 : 0;
		var lo = nz(ex < 64 ? ahi & ((-1 : I64) >>> ex) : ahi) || nz(dLo(a));
		// to nearest
		hi += lo ? md : hi & md;
		hi = ex < 64 ? hi << ex : 0;
		if (!nz(hi)) setDint(a, (1 : I64) << 63, 0, dEx(a) + 1, dSgn(a)); else setDint(a, hi, 0, dEx(a), dSgn(a));
	}

	// a rounded to a double
	@:hxmc.noGc static function dintTod(a:Ptr):Float {
		subnormalizeDint(a);
		var ahi = dHi(a), sgn = dSgn(a), ex = dEx(a);
		var r = ofBits((ahi >>> 11) | ((0x3ff : I64) << 52));
		var rd = 0.0;
		if (((ahi >>> 10) & 1) == 1) rd += 1.1102230246251565e-16; // 0x1p-53
		if (nz(ahi & 0x3ff) || nz(dLo(a))) rd += 5.5511151231257827e-17; // 0x1p-54
		if (sgn != 0) rd = -rd;
		r = ofBits(bits(r) | ((sgn : I64) << 63));
		r += rd;
		var e:Float;
		if (ex > -1022) { // a normal double
			if (ex > 1024) {
				if (ex == 1025) {
					r = r * 2.0;
					e = 8.9884656743115795e307; // 0x1p+1023
				} else {
					r = 1.7976931348623157e308;
					e = 1.7976931348623157e308;
				}
			} else
				e = ofBits(((ex + 1022) & 0x7ff : I64) << 52);
		} else {
			if (ex < -1073) {
				if (ex == -1074) {
					r = r * 0.5;
					e = ofBits(1); // 0x1p-1074
				} else {
					r = ofBits(1);
					e = ofBits(1);
				}
			} else
				e = ofBits((1 : I64) << (ex + 1073));
		}
		return r * e;
	}

	// X normalized: X.hi has its most significant bit set (if X <> 0)
	@:hxmc.noGc static function normalize(x:Ptr):Void {
		var hi = dHi(x), lo = dLo(x);
		if (nz(hi)) {
			var cnt = clz(hi);
			if (cnt != 0) {
				hi = (hi << cnt) | (lo >>> (64 - cnt));
				lo = lo << cnt;
			}
			setDint(x, hi, lo, dEx(x) - cnt, dSgn(x));
		} else if (nz(lo)) {
			var cnt = clz(lo);
			setDint(x, lo << cnt, 0, dEx(x) - 64 - cnt, dSgn(x));
		}
	}

	// Y = sin2pi(X), for 0 <= X < 2^-11, where X2 approximates X^2;
	// relative error bounded by 2^-124.648
	@:hxmc.noGc static function evalPS(t:Ptr, y:Ptr, x:Ptr, x2:Ptr):Void {
		mulDint21(y, x2, dintAt(t, O_PS, 5)); // degree 11
		addDint(t, y, y, dintAt(t, O_PS, 4)); // degree 9
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PS, 3)); // degree 7
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PS, 2)); // degree 5
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PS, 1)); // degree 3
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PS, 0)); // degree 1
		mulDint(y, y, x); // multiply by X
	}

	// Y = cos2pi(X), for 0 <= X < 2^-11, where X2 approximates X^2;
	// error bounded by 2^-125.999
	@:hxmc.noGc static function evalPC(t:Ptr, y:Ptr, x2:Ptr):Void {
		mulDint21(y, x2, dintAt(t, O_PC, 5)); // degree 10
		addDint(t, y, y, dintAt(t, O_PC, 4)); // degree 8
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PC, 3)); // degree 6
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PC, 2)); // degree 4
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PC, 1)); // degree 2
		mulDint(y, y, x2);
		addDint(t, y, y, dintAt(t, O_PC, 0)); // degree 0
	}

	// X = X/(2pi) mod 1, with relative error < 2^-126.67; X normalized at
	// input and output
	@:hxmc.noGc static function reduce(t:Ptr, x:Ptr):Void {
		var e = dEx(x);
		var xh = dHi(x);
		if (e <= 1) { // |X| < 2
			// multiply by T[0]/2^64 + T[1]/2^128
			var tiny = xh * tw(t, O_T + 1);
			var lo = mulhi(xh, tw(t, O_T + 1));
			var ul = xh * tw(t, O_T + 0);
			lo += ul;
			var hi = mulhi(xh, tw(t, O_T + 0)) + (ult(lo, ul) ? 1 : 0);
			setDint(x, hi, lo, e, dSgn(x));
			normalize(x);
			e = e - dEx(x);
			// put the upper e bits of tiny into X.lo
			if (e != 0) Mem.setI64(x, 0, dLo(x) | (tiny >>> (64 - e)));
			return;
		}
		// now 2 <= e <= 1024
		var i = e < 127 ? 0 : ((e - 127 + 64 - 1) >> 6); // ceil((e-127)/64)
		// 0 <= i <= 15
		var u = tw(t, O_T + i + 3);
		var c0 = xh * u;
		var c1 = mulhi(xh, u);
		u = tw(t, O_T + i + 2);
		var l = xh * u;
		c1 += l;
		var c2 = mulhi(xh, u) + (ult(c1, l) ? 1 : 0);
		u = tw(t, O_T + i + 1);
		l = xh * u;
		c2 += l;
		var c3 = mulhi(xh, u) + (ult(c2, l) ? 1 : 0);
		u = tw(t, O_T + i);
		l = xh * u;
		c3 += l;
		var c4 = mulhi(xh, u) + (ult(c3, l) ? 1 : 0);
		var f = e - 64 * i; // hi*T[i]/2^128 is multiplied by 2^f
		var hi:I64, lo:I64, tiny:I64;
		if (f < 64) {
			hi = (c4 << f) | (c3 >>> (64 - f));
			lo = (c3 << f) | (c2 >>> (64 - f));
			tiny = (c2 << f) | (c1 >>> (64 - f));
		} else if (f == 64) {
			hi = c3;
			lo = c2;
			tiny = c1;
		} else { // 65 <= f <= 127: only when e >= 65
			var g = f - 64; // 1 <= g <= 63
			// an extra term
			var v = mulhi(xh, tw(t, O_T + i + 4));
			c0 += v;
			var carry = ult(c0, v);
			if (carry) c1 += 1;
			if (carry && c1 == 0) c2 += 1;
			if (carry && c1 == 0 && c2 == 0) c3 += 1;
			hi = (c3 << g) | (c2 >>> (64 - g));
			lo = (c2 << g) | (c1 >>> (64 - g));
			tiny = (c1 << g) | (c0 >>> (64 - g));
		}
		setDint(x, hi, lo, 0, dSgn(x));
		normalize(x);
		// put the upper -ex bits of tiny into the low bits of lo
		var ex = dEx(x);
		if (ex < 0) Mem.setI64(x, 0, dLo(x) | (tiny >>> (64 + ex)));
	}

	// for 0 <= X < 1: X = i/2^11 + X' with 0 <= X' < 2^-11, exactly; returns i
	@:hxmc.noGc static function reduce2(x:Ptr):Int {
		if (dEx(x) <= -11) return 0;
		var sh = 64 - 11 - dEx(x);
		var hi = dHi(x);
		var i = (hi >>> sh).toInt();
		Mem.setI64(x, 8, hi & (((1 : I64) << sh) - 1));
		normalize(x);
		return i;
	}

	// out[0] + out[1] = c1/2^64 + c0/2^128
	@:hxmc.noGc static function setDd(out:Ptr, c1:I64, c0:I64):Void {
		var h:Float, l:Float;
		if (nz(c1)) {
			var e = clz(c1);
			if (e != 0) {
				c1 = (c1 << e) | (c0 >>> (64 - e));
				c0 = c0 << e;
			}
			var f:I64 = 0x3fe - e;
			h = ofBits((f << 52) | ((c1 << 1) >>> 12));
			c0 = (c1 << 53) | (c0 >>> 11);
			if (nz(c0)) {
				var g = clz(c0);
				if (g != 0) c0 = c0 << g;
				l = ofBits(((f - 53 - g) << 52) | ((c0 << 1) >>> 12));
			} else
				l = 0;
		} else if (nz(c0)) {
			var e = clz(c0);
			var f:I64 = 0x3fe - 64 - e;
			c0 = c0 << (e + 1); // most significant bit shifted out
			// the upper 52 bits of c0 into h
			h = ofBits((f << 52) | (c0 >>> 12));
			// the lower 12 bits of c0 into l
			c0 = c0 << 52;
			if (nz(c0)) {
				var g = clz(c0);
				c0 = c0 << (g + 1);
				l = ofBits(((f - 64 - g) << 52) | (c0 >>> 12));
			} else
				l = 0;
		} else {
			h = 0;
			l = 0;
		}
		Mem.setF64(out, 0, h);
		Mem.setF64(out, 8, l);
	}

	static inline var CH = 0.15915494309189535; // 0x1.45f306dc9c883p-3
	static inline var CL = -9.8393383375912429e-18; // -0x1.6b01ec5417056p-57

	// For x > 0x1.7137449123ef6p-26 (sin) or 0x1.6a09e667f3bccp-27 (cos),
	// 0x1.d12ed0af1a27ep-27 (tan), returns i and sets out[0] = h,
	// out[1] = l with i/2^11 + h + l approximating frac(x/(2pi)), and, for
	// sin and cos, out[2] = a bound of the absolute error. tan's version
	// (tan) also takes the next word of 1/(2pi) into account.
	@:hxmc.noGc static inline function reduceFast(hw:Bool, t:Ptr, out:Ptr, x:Float, tan:Bool):Int {
		var h:Float, l:Float;
		if (x <= 6.2831853071795853) { // 0x1.921fb54442d17p+2: x < 2*pi
			// | CH+CL - 1/(2pi) | < 2^-110.523
			h = CH * x;
			l = LibM.me(hw, CH, x, h); // exact
			l = LibM.fm(hw, CL, x, l);
			Mem.setF64(out, 16, 4.5548243184758128e-32 * h); // 0x1.d9p-105: error < 2^-104.116 * h
		} else { // x > 0x1.921fb54442d17p+2
			var u = bits(x);
			var e = ((u >>> 52) & 0x7ff).toInt(); // 1025 <= e <= 2046
			var m = ((1 : I64) << 52) | (u & (((1 : I64) << 52) - 1));
			var c0:I64, c1:I64, c2:I64;
			// x = m/2^53 * 2^(e-1022)
			if (e <= 1074) { // 1025 <= e <= 1074: 2^2 <= x < 2^52
				var t1 = tw(t, O_T + 1), t0 = tw(t, O_T + 0);
				var ul = m * t1;
				c0 = tan ? ul + mulhi(m, tw(t, O_T + 2)) : ul;
				c1 = mulhi(m, t1) + (tan && ult(c0, ul) ? 1 : 0);
				ul = m * t0;
				c1 += ul;
				c2 = mulhi(m, t0) + (ult(c1, ul) ? 1 : 0);
				e = 1075 - e; // 1 <= e <= 50: the low bits of c2 that contribute to frac(x/(2pi))
			} else { // 1075 <= e <= 2046, 2^52 <= x < 2^1024
				var i = ((e - 1138 + 63) >> 6); // ceil((e-1138)/64), 0 <= i <= 15
				var ti = tw(t, O_T + i + 2);
				var ul = m * ti;
				c0 = tan ? ul + mulhi(m, tw(t, O_T + i + 3)) : ul;
				c1 = mulhi(m, ti) + (tan && ult(c0, ul) ? 1 : 0);
				ti = tw(t, O_T + i + 1);
				ul = m * ti;
				c1 += ul;
				c2 = mulhi(m, ti) + (ult(c1, ul) ? 1 : 0);
				c2 += m * tw(t, O_T + i);
				e = 1139 + (i << 6) - e; // 1 <= e <= 64
			}
			if (e == 64) {
				c0 = c1;
				c1 = c2;
			} else {
				c0 = (c1 << (64 - e)) | (c0 >>> e);
				c1 = (c2 << (64 - e)) | (c1 >>> e);
			}
			setDd(out, c1, c0);
			h = Mem.getF64(out, 0);
			l = Mem.getF64(out, 8);
			Mem.setF64(out, 16, 1.3286588589133007e-23); // 0x1.01p-76
		}
		// floor (h * 2^11), 0 <= h < 1
		var y = h * 2048.0;
		var i = (y + 4503599627370496.0) - 4503599627370496.0;
		if (i > y) i -= 1;
		h = h - i * 0.00048828125; // exact
		Mem.setF64(out, 0, h);
		Mem.setF64(out, 8, l);
		return (cast i : Int); // 0 <= i < 2048
	}

	static inline var PSF1 = 6.2831853071795862; // 0x1.921fb54442d18p+2: PSfast, degree 1 (h+l)
	static inline var PSF1L = 2.4492937487389357e-16; // 0x1.1a62645446203p-52
	static inline var PSF3 = -41.341702240399762; // -0x1.4abbce625be53p+5
	static inline var PSF5 = 81.605249298319492; // 0x1.466bc678d8d63p+6
	static inline var PSF7 = -76.770831258583385; // -0x1.331554ca19669p+6
	static inline var PCF0L = -1.0396311785461432e-23; // -0x1.923015cp-77: PCfast, degree 0 (1+l)
	static inline var PCF2 = -19.739208802178716; // -0x1.3bd3cc9be45dep+4
	static inline var PCF4 = 64.939394007293487; // 0x1.03c1f080ad892p+6
	static inline var PCF6 = -85.411886468174686; // -0x1.55a5c590f9e6ap+6

	// The common part of sin_fast, cos_fast and tan_fast: for R = i/2^11 + h
	// + l (0 <= i < 256, 0 <= h+l < 2^-11), out[0..3] = sin2pi(h+l) (evalPSfast)
	// and out[4..5] = cos2pi(h+l) (evalPCfast), double-doubles, after
	// h -= SC[i][0]; and with tan, a fast_two_sum of h and l first
	@:hxmc.noGc static inline function evalFast(hw:Bool, t:Ptr, out:Ptr, i:Int, h:Float, l:Float, tan:Bool):Void {
		// the SC[] table evaluates at i/2^11 + SC[i][0]
		h -= sc(t, i, 0);
		if (tan) {
			var s = h + l;
			l = l - (s - h);
			h = s;
		}
		// uh + ul approximates (h+l)^2
		var uh = h * h;
		var ul = LibM.me(hw, h, h, uh);
		ul = LibM.fm(hw, h + h, l, ul);
		// evalPSfast: sin2pi(h+l)
		var p = LibM.fm(hw, LibM.fm(hw, PSF7, uh, PSF5), uh, PSF3);
		var ph = p * uh; // s_mul (p, uh, ul)
		var pl = LibM.fm(hw, p, ul, LibM.me(hw, p, uh, ph));
		var s = PSF1 + ph; // fast_two_sum (PSfast[0], ph)
		var e = ph - (s - PSF1);
		pl += PSF1L + e;
		var sh = s * h; // d_mul (s, pl, h, l)
		var sl = LibM.fm(hw, s, l, LibM.fm(hw, pl, h, LibM.me(hw, s, h, sh)));
		// evalPCfast: cos2pi(h+l)
		p = LibM.fm(hw, LibM.fm(hw, PCF6, uh, PCF4), uh, PCF2);
		ph = p * uh;
		pl = LibM.fm(hw, p, ul, LibM.me(hw, p, uh, ph));
		s = 1.0 + ph;
		e = ph - (s - 1.0);
		pl += PCF0L + e;
		Mem.setF64(out, 0, sh);
		Mem.setF64(out, 8, sl);
		Mem.setF64(out, 16, s);
		Mem.setF64(out, 24, pl);
	}

	// out[0] + out[1] = sin |x| (is_sin) or cos |x| (not is_sin) from the
	// reduction of |x| (sin_fast and cos_fast); returns the error bound
	// (hw: with the processor's fma; one copy each, chosen once per call)
	@:hxmc.noGc static function sinCosFastHw(t:Ptr, out:Ptr, x:Float, isCos:Bool):Float
		return sinCosFast(true, t, out, x, isCos);

	@:hxmc.noGc static function sinCosFastSoft(t:Ptr, out:Ptr, x:Float, isCos:Bool):Float
		return sinCosFast(false, t, out, x, isCos);

	@:hxmc.noGc static inline function sinCosFast(hw:Bool, t:Ptr, out:Ptr, x:Float, isCos:Bool):Float {
		var neg = 0, isSin = 1;
		var absx = x;
		if (x < 0) {
			absx = -x;
			if (!isCos) neg = 1;
		}
		if (isCos) isSin = 0;
		var i = reduceFast(hw, t, out, absx, false);
		var h = Mem.getF64(out, 0), l = Mem.getF64(out, 8), err1 = Mem.getF64(out, 16);
		// i >= 2^10: pi <= x <= 2pi, sin(pi+x) = -sin(x), cos(pi+x) = -cos(x)
		neg = neg ^ (i >> 10);
		i = i & 0x3ff;
		// i >= 2^9: pi/2 <= x <= pi, sin(pi/2+x) = cos(x), cos(pi/2+x) = -sin(x)
		isSin = isSin ^ (i >> 9);
		if (isCos) neg = neg ^ (i >> 9);
		i = i & 0x1ff;
		// i >= 2^8: sin(pi/2-x) = cos(x), cos(pi/2-x) = sin(x)
		if ((i & 0x100) != 0) {
			isSin = isSin ^ 1;
			i = 0x1ff - i;
			h = 0.00048828125 - h; // 0x1p-11 - h: exact
			l = -l;
		}
		evalFast(hw, t, out, i, h, l, false);
		var sh = Mem.getF64(out, 0), sl = Mem.getF64(out, 8), ch = Mem.getF64(out, 16), cl = Mem.getF64(out, 24);
		var sgn = isCos ? 1.0 : (neg != 0 ? -1.0 : 1.0);
		var a = sgn * sc(t, i, 2), b = sgn * sc(t, i, 1);
		var err:Float;
		if (isSin != 0) {
			var h1 = a * sh; // s_mul (a, sh, sl)
			var l1 = LibM.fm(hw, a, sl, LibM.me(hw, a, sh, h1));
			var h2 = b * ch; // s_mul (b, ch, cl)
			var l2 = LibM.fm(hw, b, cl, LibM.me(hw, b, ch, h2));
			h = h2 + h1; // fast_two_sum (h2, h1)
			l = h1 - (h - h2);
			l += l1 + l2;
			err = 2.2565487110446595e-21; // 0x1.55p-69
		} else {
			var h1 = a * ch; // s_mul (a, ch, cl)
			var l1 = LibM.fm(hw, a, cl, LibM.me(hw, a, ch, h1));
			var h2 = b * sh; // s_mul (b, sh, sl)
			var l2 = LibM.fm(hw, b, sl, LibM.me(hw, b, sh, h2));
			h = h1 - h2; // fast_two_sum (h1, -h2)
			l = -h2 - (h - h1);
			l += l1 - l2;
			err = 2.5477162866633252e-21; // 0x1.81p-69
		}
		if (isCos && neg != 0) {
			h = -h;
			l = -l;
		}
		Mem.setF64(out, 0, h);
		Mem.setF64(out, 8, l);
		return err + err1;
	}

	// sin |x| or cos |x| with 128-bit arithmetic (sin_accurate, cos_accurate)
	@:hxmc.noGc static function sinCosAccurate(t:Ptr, x:Float, isCos:Bool):Float {
		var absx = x > 0 ? x : -x;
		var w = Mem.stack(128);
		var dx = w, du = w.add(32), dv = w.add(64), dx2 = w.add(96);
		dintFromd(dx, absx);
		reduce(t, dx);
		// |X - x/(2pi) mod 1| < 2^-126.67*X, with 0 <= X < 1
		var neg = !isCos && x < 0 ? 1 : 0, isSin = isCos ? 0 : 1;
		// X = i/2^11 + r with 0 <= r < 2^11
		var i = reduce2(dx); // exact
		if ((i & 0x400) != 0) { // pi <= x < 2*pi: sin(x) = -sin(x-pi), cos(x) = -cos(x-pi)
			neg = neg ^ 1;
			i = i & 0x3ff;
		}
		if ((i & 0x200) != 0) { // pi/2 <= x < pi: sin(x) = cos(x-pi/2), cos(x) = -sin(x-pi/2)
			if (isCos) neg = neg ^ 1;
			isSin = isSin ^ 1;
			i = i & 0x1ff;
		}
		if ((i & 0x100) != 0) { // pi/4 <= x < pi/2: sin(x) = cos(pi/2-x), cos(x) = sin(pi/2-x)
			isSin = isSin ^ 1;
			Mem.setI32(dx, 24, 1); // negate X
			addDint(t, dx, t.add(8 * O_MAGIC), dx); // X -> 2^-11 - X
			i = 0x1ff - i;
		}
		// 0 <= i < 256 and 0 <= X < 2^-11
		mulDint(dx2, dx, dx); // X2 approximates X^2
		evalPC(t, du, dx2); // cos2pi(X)
		evalPS(t, dv, dx, dx2); // sin2pi(X)
		if (isSin != 0) {
			// sin2pi(R) ~ sin2pi(i/2^11)*cos2pi(X)+cos2pi(i/2^11)*sin2pi(X)
			mulDint(du, dintAt(t, O_S, i), du);
			mulDint(dv, dintAt(t, O_C, i), dv);
		} else {
			// cos2pi(R) ~ cos2pi(i/2^11)*cos2pi(X)-sin2pi(i/2^11)*sin2pi(X)
			mulDint(du, dintAt(t, O_C, i), du);
			mulDint(dv, dintAt(t, O_S, i), dv);
			Mem.setI32(dv, 24, 1 - dSgn(dv)); // negate V
		}
		addDint(t, du, du, dv);
		// the total error is bounded by |U| * 2^-122.650: less than 41 ulps of U.lo
		var err:I64 = 41;
		var ulo = dLo(du), uhi = dHi(du);
		var lo0 = ulo - err;
		var hi0 = uhi - (ult(ulo, lo0) ? 1 : 0);
		var lo1 = ulo + err;
		var hi1 = uhi + (ult(lo1, ulo) ? 1 : 0);
		// check the upper 54 bits are equal
		if (!((hi0 >>> 10) == (hi1 >>> 10))) {
			// the hard-to-round cases that need it (all others pass)
			var ax = Math.abs(x);
			if (!isCos) {
				if (ax == 1.788139343261814e-06) // 0x1.e0000000001c2p-20
					return x > 0 ? 1.7881393432608611e-06 + 2.0876201503470484e-44 : -1.7881393432608611e-06 - 2.0876201503470484e-44;
				if (ax == 5.3193726483265414e+255) // 0x1.6ac5b262ca1ffp+849 (68 identical bits after the round bit)
					return x > 0 ? 1.0 + -1.098476220074687e-37 : -1.0 - -1.098476220074687e-37;
			} else {
				if (ax == 1.7881393432617211e-07) return 0.99999999999998401 + 1.5323198707391886e-43;
				if (ax == 3.5762786865234566e-07) return 0.99999999999993605 + 9.8068471727308299e-42;
				if (ax == 7.1525573730470275e-07) return 0.9999999999997442 + 6.2763821905477882e-40;
				if (ax == 1.0728836059570827e-06) return 0.99999999999942446 + 7.1491915889209496e-39;
				if (ax == 1.430511474609497e-06) return 0.99999999999897682 + 4.0168846019507311e-38;
			}
		}
		if (neg != 0) Mem.setI32(du, 24, 1 - dSgn(du));
		return dintTod(du);
	}

	@:hxmc.host("Math_sin") @:hxmc.noGc static function sin(x:Float):Float {
		var u = bits(x);
		var e = ((u >>> 52) & 0x7ff).toInt();
		if (e == 0x7ff) return x - x; // NaN, +Inf and -Inf
		// |x| <= 0x1.7137449123ef6p-26: sin(x) rounds to x (to nearest)
		if (!ult(u64(0x3e571374, 0x49123ef6), u & u64(0x7fffffff, 0xffffffff))) return x;
		var t = tab();
		var out = Mem.stack(32);
		var err = LibM.useHw() ? sinCosFastHw(t, out, x, false) : sinCosFastSoft(t, out, x, false);
		var h = Mem.getF64(out, 0), l = Mem.getF64(out, 8);
		var left = h + (l - err), right = h + (l + err);
		if (left == right) return left;
		return sinCosAccurate(t, x, false);
	}

	@:hxmc.host("Math_cos") @:hxmc.noGc static function cos(x:Float):Float {
		var u = bits(x);
		var e = ((u >>> 52) & 0x7ff).toInt();
		if (e == 0x7ff) return x - x; // NaN, +Inf and -Inf
		var ax = Math.abs(x);
		// |x| <= 0x1.6a09e667f3bccp-27: cos(x) rounds to 1 (to nearest)
		if (!ult(u64(0x3e46a09e, 0x667f3bcc), u & u64(0x7fffffff, 0xffffffff))) return 1.0;
		var t = tab();
		var out = Mem.stack(32);
		var err = LibM.useHw() ? sinCosFastHw(t, out, ax, true) : sinCosFastSoft(t, out, ax, true);
		var h = Mem.getF64(out, 0), l = Mem.getF64(out, 8);
		var left = h + (l - err), right = h + (l + err);
		if (left == right) return left;
		return sinCosAccurate(t, ax, true);
	}

	// ---- tan

	// r = 1/a, a <> 0, with error bounded by 4.003 ulps
	@:hxmc.noGc static function invDint(t:Ptr, r:Ptr, a:Ptr):Void {
		var h = dHi(a); // 2^63 <= h < 2^64
		// a 64-bit inverse t of h, with t*h ~ 2^127
		var i = ((h >>> 55) & 0xff).toInt();
		var x = tw(t, O_TINV + i);
		// three Newton iterations: e = 2^127 - h*x (exact, 0 <= e < 2^119),
		// x += (x * (e >> s1)) >> s2
		for (k in 0...3) {
			var pl = h * x, ph = mulhi(h, x);
			// e = 2^127 - (ph:pl)
			var el = -pl;
			var eh = ((1 : I64) << 63) - ph - (nz(pl) ? 1 : 0);
			var s1 = k == 0 ? 55 : k == 1 ? 47 : 31;
			var s2 = k == 0 ? 72 : k == 1 ? 80 : 96;
			// e >> s1 fits in 64 bits (e < 2^119, 2^111, 2^95)
			var es = shrLo(eh, el, s1);
			var qh = mulhi(x, es); // (x * es) >> s2, s2 >= 64
			x += qh >>> (s2 - 64);
		}
		var q = Mem.stack(32);
		setDint(r, x, 0, 1 - dEx(a), 1);
		// Newton's iteration: r -> r + r*(1-a*r)
		mulDint21(q, a, r); // -a*r, error <= 2 ulps
		Mem.setI32(r, 24, 0); // restore the sign
		addDint(t, q, t.add(8 * O_ONE), q); // 1-a*r, error <= 2 ulps
		mulDint(q, r, q); // r*(1-a*r), error <= 6 ulps
		addDint(t, r, r, q); // error <= 2 ulps
	}

	// r = b/a, a <> 0, with relative error < 2^-123.67
	@:hxmc.noGc static function divDint(t:Ptr, r:Ptr, b:Ptr, a:Ptr):Void {
		invDint(t, r, a);
		mulDint(r, r, b);
	}

	// out[0] + out[1] = tan(x), returning the error bound; for |x| >
	// 0x1.d12ed0af1a27ep-27 (tan_fast)
	@:hxmc.noGc static function tanFastHw(t:Ptr, out:Ptr, x:Float):Float
		return tanFast(true, t, out, x);

	@:hxmc.noGc static function tanFastSoft(t:Ptr, out:Ptr, x:Float):Float
		return tanFast(false, t, out, x);

	@:hxmc.noGc static inline function tanFast(hw:Bool, t:Ptr, out:Ptr, x:Float):Float {
		var neg = x < 0 ? 1 : 0, isTan = 1;
		var absx = x < 0 ? -x : x;
		var i = reduceFast(hw, t, out, absx, true);
		var h = Mem.getF64(out, 0), l = Mem.getF64(out, 8);
		// i >= 2^10: tan(pi+x) = tan(x)
		i = i & 0x3ff;
		// i >= 2^9: tan(pi/2+x) = -cot(x)
		isTan = isTan ^ (i >> 9);
		neg = neg ^ (i >> 9);
		i = i & 0x1ff;
		// i >= 2^8: tan(pi/2-x) = cot(x)
		if ((i & 0x100) != 0) {
			isTan = isTan ^ 1;
			i = 0x1ff - i;
			h = 0.00048828125 - h; // exact
			l = -l;
		}
		// i = 0 and h < 2^-37: the slow path
		if (i == 0 && h < 7.2759576141834259e-12) return 1.0;
		evalFast(hw, t, out, i, h, l, true);
		var sh = Mem.getF64(out, 0), sl = Mem.getF64(out, 8), ch = Mem.getF64(out, 16), cl = Mem.getF64(out, 24);
		var s2 = sc(t, i, 2), s1 = sc(t, i, 1);
		// h1 + l1 ~ sin2pi(R)
		var sh0 = s2 * sh;
		var sl0 = LibM.fm(hw, s2, sl, LibM.me(hw, s2, sh, sh0));
		var ch0 = s1 * ch;
		var cl0 = LibM.fm(hw, s1, cl, LibM.me(hw, s1, ch, ch0));
		var h1 = ch0 + sh0;
		var l1 = sh0 - (h1 - ch0);
		l1 += sl0 + cl0;
		// h2 + l2 ~ cos2pi(R)
		var ch2 = s2 * ch;
		var cl2 = LibM.fm(hw, s2, cl, LibM.me(hw, s2, ch, ch2));
		var sh2 = s1 * sh;
		var sl2 = LibM.fm(hw, s1, sl, LibM.me(hw, s1, sh, sh2));
		var h2 = ch2 - sh2;
		var l2 = -sh2 - (h2 - ch2);
		l2 += cl2 - sl2;
		// fast_div: h + l = (bh + bl) / (ah + al), Karp and Markstein
		var bh = h1, bl = l1, ah = h2, al = l2;
		if (isTan == 0) {
			bh = h2;
			bl = l2;
			ah = h1;
			al = l1;
		}
		var y = 1.0 / ah;
		h = bh * y;
		var eh = LibM.fm(hw, ah, -h, bh);
		var el = LibM.fm(hw, al, -h, bl);
		l = y * (eh + el);
		if (neg != 0) {
			h = -h;
			l = -l;
		}
		Mem.setF64(out, 0, h);
		Mem.setF64(out, 8, l);
		return h * 1.4928955695357043e-20; // 0x1.1ap-66
	}

	// tan(x) with 128-bit arithmetic (tan_accurate)
	@:hxmc.noGc static function tanAccurate(t:Ptr, x:Float):Float {
		var absx = x > 0 ? x : -x;
		var w = Mem.stack(256);
		var dx = w, du = w.add(32), dv = w.add(64), dx2 = w.add(96), dsn = w.add(128), duu = w.add(160), dvv = w.add(192), dcs = w.add(224);
		dintFromd(dx, absx);
		reduce(t, dx);
		var isTan = 1, neg = x < 0 ? 1 : 0;
		var i = reduce2(dx); // exact
		i = i & 0x3ff; // pi <= x < 2*pi: tan(x) = tan(x-pi)
		if ((i & 0x200) != 0) { // pi/2 <= x < pi: tan(x) = -1/tan(x-pi/2)
			isTan = 0;
			neg = neg ^ 1;
			i = i & 0x1ff;
		}
		if ((i & 0x100) != 0) { // pi/4 <= x < pi/2: tan(x) = 1/tan(pi/2-x)
			isTan = isTan ^ 1;
			Mem.setI32(dx, 24, 1); // negate X
			addDint(t, dx, t.add(8 * O_MAGIC), dx); // X -> 2^-11 - X
			i = 0x1ff - i;
		}
		mulDint(dx2, dx, dx);
		evalPC(t, du, dx2); // cos2pi(X)
		evalPS(t, dv, dx, dx2); // sin2pi(X)
		// sin2pi(R) ~ sin2pi(i/2^11)*cos2pi(X)+cos2pi(i/2^11)*sin2pi(X)
		mulDint(duu, dintAt(t, O_S, i), du);
		mulDint(dvv, dintAt(t, O_C, i), dv);
		addDint(t, dsn, duu, dvv);
		// cos2pi(R) ~ cos2pi(i/2^11)*cos2pi(X)-sin2pi(i/2^11)*sin2pi(X)
		mulDint(du, dintAt(t, O_C, i), du);
		mulDint(dv, dintAt(t, O_S, i), dv);
		Mem.setI32(dv, 24, 1 - dSgn(dv)); // negate V
		addDint(t, dcs, du, dv);
		// S/C or C/S
		if (isTan != 0) divDint(t, du, dsn, dcs); else divDint(t, du, dcs, dsn);
		// total relative error < 2^-121.578: less than 86 ulps
		var err:I64 = 86;
		var ulo = dLo(du), uhi = dHi(du);
		var lo0 = ulo - err;
		var hi0 = uhi - (ult(ulo, lo0) ? 1 : 0);
		var lo1 = ulo + err;
		var hi1 = uhi + (ult(lo1, ulo) ? 1 : 0);
		if (!((hi0 >>> 10) == (hi1 >>> 10))) {
			var ax = Math.abs(x);
			// 78 and 72 identical bits after the round bit
			if (ax == 4.4703483581541778e-07)
				return x > 0 ? 4.4703483581544753e-07 + 2.6469779601696883e-23 : -4.4703483581544753e-07 - 2.6469779601696883e-23;
			if (ax == 8.9406967163076408e-07)
				return x > 0 ? 8.9406967163100231e-07 + -7.8285755638033317e-45 : -8.9406967163100231e-07 - -7.8285755638033317e-45;
		}
		if (neg != 0) Mem.setI32(du, 24, 1 - dSgn(du));
		return dintTod(du);
	}

	@:hxmc.host("Math_tan") @:hxmc.noGc static function tan(x:Float):Float {
		var u = bits(x);
		var e = ((u >>> 52) & 0x7ff).toInt();
		if (e == 0x7ff) return x - x; // NaN, +Inf and -Inf
		// |x| <= 0x1.d12ed0af1a27ep-27: tan(x) rounds to x (to nearest)
		if (!ult(u64(0x3e4d12ed, 0x0af1a27e), u & u64(0x7fffffff, 0xffffffff))) return x;
		var t = tab();
		var out = Mem.stack(32);
		var err = LibM.useHw() ? tanFastHw(t, out, x) : tanFastSoft(t, out, x);
		var h = Mem.getF64(out, 0), l = Mem.getF64(out, 8);
		var left = h + (l - err), right = h + (l + err);
		if (left == right) return left;
		return tanAccurate(t, x);
	}

	// ---- the tables (cos.c, tan.c; sin.c's are cos.c's)

	// 20
	static inline var T = "28be60db9391054a7f09d5f47d4d377036d8a5664f10e4107f9458eaf7aef1586dc91b8e909374b801924bba827464873f877ac72c4a69cfba208d7d4baed1213a671c09ad17df904e64758e60d4ce7d272117e2ef7e4a0ec7fe25fff7816603fbcbc462d6829b47db4d9fb3c9f2c26dd3d18fd9a797fa8b5d49eeb1faf97c5ecf41ce7de294a4ba9afed7ec47e357421580cc11bf1edaeafc33ef0826bd0d87";
	// 256 dints
	static inline var S = "000000000000000000000000000000000100c90fc5f66525d257480f7956b6470765fff0c90f87f3380388d5cb3ff35bd4d81baafff296cb587284b81770b767005691b9d9d1fff4c90e8fe6f63c2330f1d7d06db39ea9fcfff4fb514b55ccbe541ad784e031f9af76d6fff496c9b5df1877e9b5f91ee371d6467dcafff6afea690fd5912ef3f56e3c87ae3c56dffff6c90aafbd1b33efc9c539edcbfda0cf2cfff6e22a7a6729d8e453850021e392744a4ffff6fb49b98e8e7807f600b21ccebc9caac3fff68a342eda160bf5aede5b1068d174be9cfff896c32baca2ae68b437b2dd49d5fca3c0fff8a351cb7fc30bc889b56007d16d4ad5a3fff8afe00694866a1b44cd34d2751c2e1da7fff8bc6dd52c3a342eb5f10bfca3d6464012fff8c8fb2f886ec09f376a17954b2b7c5171fff8d5880deafc18b53473d1472472f4a390fff8e214689606bf1676438b4a73aecd2541fff8eea037cc04764844c4e92d01a2f42935fff8fb2b73cfc106ff68f0a0e36a000c7350fff883db0a7231831d8f60e782313f6161affffa8a2009a6b84d940277724a2b2a669bc4fffa9064b3a76a22640c56e0a8b0d177b55dfffa96a9049670cfae65f77574094d3c35c4fffa9cecf8962d14c82250ffe4f5caa7f1fafffaa3308bc93904ad69dec1b7f2768bdafafffaa973ba526a6850d976f8c63986598c79fffaafb68054d520c60bfdd2fc0936594c2dfffab5f8d9f3cd8945d6924bef13600f9852fffabc3ac352ead90abeeb13e106732687f1fffac27c389609850433b228a03916371f6ffffac8bd35e14da15f0ec7396c894bbf7389fffacefdb7592542e1e96b47b8c44e5b037efffad53db9224ae01bca7337412cf70716cbfffadb7d3761c7b263b6bb286d23e11c8337fffae1bc2e3cf616a7ac31883b30137c6e62fffae7fa99d983ee098feeb8f9c33340a2f2fffaee38765d74fe4897ed16b994af6c18aefffaf475bfef2551f5b914e1a5488eaeab96fffafab272b54b9871a2704729ae56d78a37fffa8077456b7dc2d9673eac8308f1113e5efffc8395023dd418e919db1f70118c9c2198fffc86b26de5933c2e8ec5a9decdfaad4db5fffc89cf8676d7abb55b97965c9860c34e44fffc8cec4a05f12739e8dcdca90cc73b116afffc9008b6a763de75b7a6e3df5975cca9dafffc9324ca6fe9a04b4e899c4de737feec22fffc964083747309d113000a89a11e07c1fefffc995bdfca28b53a5449c4863de522b217fffc9c76dd866c689dcce7bc08111d0bfca4fffc9f917abeda4498dff3ff913a4aadb85efffca2abb58949f2ced7a5dbee6084ee1260fffca5c58bfbcfd4436a69fcb11e19f58619fffca8defc2cbe2f8fcc0cd12a1f6ab6b095fffcabf80432a65ef1908c95c4c91179176bfffcaf10a22459fe32a63feef3bb58b1f10dfffcb228d418ec1869ad16031a34d4fc855dfffcb5409827b25591f0cd73fb5d8d45d302fffcb857ec684627fa4c187e26d290714d70fffcbb6ecef285f98a3abddd8a0365d6b1d3fffcbe853dde9658dc60dfe1b074e22fc666fffcc19b3744e3262dcdad5a41de48f6b26ffffcc4b0b93e20c0213fdab4e426409b23a0fffcc7c5c1e34d3055b25cc8c00e4fccd850fffccada4f4db157cf77fa6171200ab2efc3fffccdee5f96e21b332c65a3132adfb7dfd5fffcd101f0d8c18ed1c1aadb580a1eba209ffffcd415012d802284f0df4005ef6a64aa02fffcd7278eaf9dcd5b551779df36d1cc8912fffcda399779eb391377cbabaeb97af8e8aafffcdd4b19a78aed6515ece7f445cecf1e28fffce05c1353f27b17e50ebc61ade6ca83cdfffce36c829aeba6e72026a0eecdb4f16266fffce67c65989594312382b0aecadf808123fffce98bba6965ef725fb91caf23416e7e80fffcec9a7f2a2a188aeb7244ee20f591983bfffcefa8b1f8084ccdfc1050cdf22f34182ffffcf2b650f080d0da8d587f3fa044e2d27dfffcf5c35a316f1a3c80643720de93ba81bdfffcf8cfcbd90af8d57a4221dc4ba772598dfffcfbdba405e9c00ccad24d3023da491920fffcfee6e0d6ff6fc5a48b74fe2508ab8fc2fffc80f8c035cfee8d76fd958d68e8b49e6bfffe827dc071bfed6ffafb4c92369f0cf008fffe8402702f5b30f2a9cb07b25a7b0372a7fffe8586ce7ededc809d9d3dc689006896f4fffe870ada70ba4e6d49009d52755ece3f70fffe888e93158fb3bb04984156f553344306fffe8a11f77e349bc245a66d1d936c38c329fffe8b9506bbb28bb922575f33366be0afeffffe8d17bfdf47921ac8cb590d74f64e77c9fffe8e9a21fa66d9ee8df2be3ecae62789d4fffe901c2c1eb93dee39632b9cff5cfee724fffe919ddd5e1ddb8b33609c464b3dd676ecfffe931f34caaaa5d23a6a1ff8bfe6396e28fffe94a03176acf82d45ae4ba773da6bf754fffe9620d274aa290339e06a955a5b8e301dfffe97a116d7601c3515fc8b7184b21f2d50fffe9920fdb1c5d5783d9dd1eedf18a2e4dffffe9aa086170c0a8d869ffa0d23f3c26c62fffe9c1faf1a9db554afdab6b478577e7be5fffe9d9e77d020a5bbe6db895384528d0d60fffe9f1cdf4b76138b0298dbd3555ebcdefefffea09ae4a0bb300a192f895f44a303cc0bfffea21886e449b78316d29d23a624acd00cfffea395c52ab8829dfc2be036401ba87cc2fffea5129e88dc17976a82d9495ead5be348fffea68f1213c73b512417218792857f4c5afffea80b1ee0cb823c273269f4702b88324afffea986c40579e11c0a8e3bdf8085321556fffeab020097a33da341c1654b64a0081b46fffeac7cd3ad58fee7f0811f953984eff83efffeadf73c5ced9db0f39a5318ac6fe94e4dfffeaf7139bcf5349ac69fe5f4ea48965e2cfffeb0eacae4461013ed63c66682bae74898fffeb263eee9f93e3088695a5332090bb09bfffeb3dca4e56b1e54bb992d96e5021e3c37fffeb554ebee3bf0b58e971f4da709ad4378fffeb6ccc31c5065afee35ebacd79f209137fffeb8442987d22cf5769cc3ef36746de3b8fffeb9bb1e4930848eadcdb0531c4e58484bfffebb31a07920c7b25655b92083658bb897fffebca7af309efd71820a4b0d21fc5036a5fffebe1d4988ee67380cd1f90f79f46c7e01fffebf926e9b9a0f212791a1b5eb79658c67fffec1071d8275561f9b721853f8e528a934fffec27b55579c81f96dcdc2bd470675104dfffec3ef1535754b168d3122c2a59efddc37fffec5625c36af6a222ff4ff2895ab6ebe89fffec6d5297645257e8d14d24739de27e2e9fffec8477c0f7bde8a98004ce0246ad4fa74fffec9b9531de49eb9684319e5ad5b0dcb84fffecb2aadbd5ca47af5faa3dfe675a65ee2fffecc9b8b0a0deff5d42e663b3c7555a6c3fffece0bea206fcf91923c540a9eec47af38fffecf7bca1d476c516da81290bdbaad62e4fffed0eb2a1da855fefdb9302788604e88f1fffed25a093ef50f2482721fc87ba1d42456fffed3c8669edf98d68087967926fdcecec4fffed536415b69fe4c541df22346611c6b4bfffed6a39892e6e047643090d44db12c418cfffed8106b63fa0048a0a573f2aa90434ba5fffed97cb8ed98cb93f52e349483e3fb2a6afffedae8804f0ae6015b362cb974182e3030fffedc53c0a7eab49b353ccca3982328ed8bfffeddbe791825e8099e1a5bd9269d408d7efffedf28a8bffe06ca56cce2634be2bf54dffffee0924ec008f734fd8aa895d5bf3e84eafffee1fb6a3931894b38f7a1f9bd9ba13b6bfffee363fa4cb80054827b32c72e31824e51fffee4cbfe1c329c453ad40e9e6b989f89e5fffee63374c98e22f0b42872ce1bfc7ad1cdfffee79a5d770e6905dcf1b65cc5fd780262fffee900b7474edad637431626c10485bddafffeea66815d4304e6c80cc39cfcc29960b1fffeebcbbadc371c4aaa1d90f780ae951140fffeed3062e7d086c6f0c71debc372b6f9d4fffeee9478a40e62bf862a24164daec85ccbfffeeff7fb354a0eecb1527233b40d3432bbfffef15ae9c037b1d8f06c48e9e3420b0f1efffef2bd4369e6c126d37f232aee178c6323fffef41f0757c2889e843c7f10db458c337cfffef58034af92b102a793fa6107c4327527fffef6e0ca977bc6ac45e1079824233fef46fffef840c835ffbfed66a9a56012067c570cfffef9a02cb1fe833a0d08da894471de1a18fffefafef732b66d17420343fbf4a7d42af3fffefc5d26dfc4d5cfda27c07c911290b8d1fffefdbabae12696eea402377c3799c052fafffeff17b25f38907dad0a9c6ba50490539ffffe803a06415c1705256f53873e2f1477ff000080e7e43a61f5b6cb5ca183dc973abc220000819572af6decac849fba97fdf0c4d24c00008242b1357110d3726fb2123fedfa6e22000082ef9f618dc5b70e91a965931f1a200a0000839c3cc917ff6cb4bfd79717f2880abf00008448890195846099246efcff30cb064a000084f483a0be2f040351917cac857fd5f5000085a02c3c7c2f5ca5327888fe4b62687b0000864b826aec4c74e585043222c9bdd18d000086f685c25e25acf57e0b9b07548471a2000087a135d95473ec894e091160e24307120000884b9246854ab50b4f14c8afe4560291000088f59aa0da591421b892ca8361d8c84c0000899f4e7f712a765ec88302a31afce54a00008a48ad799b6759f3660558a02136130a00008af1b726df15e13c545f7d79ead8fa1900008b9a6b1ef6da450221a6675f51580bc400008c42c8f9d2372644101a5adbcb9ffb4300008cead04f95cdbf664d49cbaf15aecd8000008d9280b89b9df49bde2d43c6b67a7cbe00008e39d9cd73464364bba4cfecbff5486700008ee0db26e24390f8af0e2345f3bd24b400008f87845de430d7779311a82459aa0f720000902dd50bab06b1b7b144016c7a30b39a000090d3ccc99f5ac58b09d1072e09b72292000091796b31609f0c546714fe6925b78cc40000921eafdcc560f9c533d0a284a8c954ad000092c39a65db88809d1f8481e704e4a767000093682a66e896f544b17821911e71c16e0000940c5f7a69e5ce1c0001489a97671a42000094b0393b14e54156d6c7af02d5c16fd900009553b743d75ac03fac0106650f4ef023000095f6d92fd79f4fbad9f8e1a446e973b9000096999e9a74ddbde3a7a7556c3b33abc10000973c071f4750b49cc0a03934f0cce19b000097de125a2080a8edd243aa0843a2c1440000987fbfe70b81a70819cec845ac87a5c6000099210f624d30facbc4b992a37fb9b9bd000099c200686472b4a81ab42d43235757b600009a6292960a6f0ab07e92c655656e6b8500009b02c58832cf95c0698b94f50326a04300009ba298dc0bfc6a889a5614e8ffbeac6f00009c420c2eff590e5fc7fd954194e6d8aa00009ce11f1eb18147b13e93627de8fd577900009d7fd1490285c9e3e25e39549638ae6800009e1e224c0e28bc942cad377d5c9c35d800009ebc11c62c1a1dfbcc141e10c6460c8b00009f599f55f0340061a88d5f46834bbf8d00009ff6ca9a2ab6a26d22cc118a0c118aa00000a0939331e88462377cec6df5bea167cf0000a12ff8bc735d8af671acea2819360c350000a1cbfad9521bfd1b166c36e7bb3c402f0000a267992848eeb0c03b5167ee359a234e0000a302d349599512439443372e20d4377c0000a39da8dcc39a38e50ca9a8a720d4c69c0000a4381983048ff747bf623cf5301a2dde0000a4d224dcd849c5b023d251cc8d7975cc0000a56bca8b391785db189d39ffe11aaa2b0000a6050a2f600020498c33ebf3aa8501fb0000a69de36ac4fbfadc9b3ad6e4022183d90000a73655df1f2f489e149f6e75993468a30000a7ce612e652432916b2a39f856a697810000a86604facd04d9693463a2c2e6e9cc550000a8fd40e6ccd52ffd6cc14c4f53e2e82d0000a99414951aacae5ed147625fda929af80000aa2a7fa8acefdd63b714ee81b53b4b9d0000aac081c4ba89ba8ae1b3dfc4dbda9bfd0000ab561a8cbb24f410f17cee69b0d2ecde0000abeb49a46764fd151becda8089c1a94c0000ac800eafb91ef9a9f86ba0dde982fb590000ad146952eb9282af44bf16268608db960000ada859327ba241519d30d4cfeb04f1fb0000ae3bddf3280c620d3d538178654225650000aecef739f1a2df10f74d099042e8f3260000af61a4ac1b83a1dea89a9b8f726b95bf0000aff3e5ef2b507c068c679e67fc462d510000b085baa8e966f6dae4cad00d5c94bcd20000b117227f6117f9f98d8be132d576e6140000b1a81d18e0df488924784f32c3e3e5bd0000b238aa1bfa9ad5078cc7d4bd05ffd5ae0000b2c8c92f83c1eb87ac9f7ebbc469ef590000b35879fa959c323c5d6635109164f7400000b3e7bc248d78802ea156468ef6c18c600000b4768f550ce389fd4a85350f69018c550000";
	// 256 dints
	static inline var C = "800000000000000000000000000000000002ffffb10b10e80e953031437d7eccb9df0000fffec42c7454926b38e310779edfec680000fffd3964bc6275ba69fff9ae0dedb0470000fffb10b4dc96dabbb47903f7a19f8ee20000fff84a1e29de85718cc193c5d508e13f0000fff4e5a25a8d095b43366df666fd54ff0000fff0e343865bbb135428ed0647c9e5d10000ffec4304266865d956575523669617320000ffe704e71533c50853aa9423bb0adc210000ffe128ef8e9fc17a7d209f32d42d864e0000ffdaaf212fed72db4fd8f038449ec4360000ffd3977ff7bae4e9664649b4d541b9c50000ffcbe2104600a0a95595ca3f421ae09c0000ffc38ed6dc0ef98b1c676208aa3be5450000ffba9dd8dc8b1e83ccfed60a91097c480000ffb10f1bcb6bef1d421e8edaaf59453e0000ffa6e2a58df6947dd2c665c2da3e78440000ff9c187c6abade6a1e1862cca089938b0000ff90b0a7098f64432dabd3195a05710f0000ff84ab2c738d6a03519c314973ccae6b0000ff780814130c893c3ea4f30adda3016f0000ff6ac765b39e1e191b9d5851979f28fb0000ff5ce9298208786750a7bb6a6ee3b0f10000ff4e6d680c41d0a90f668633f1ab858a0000ff3f542a416b0134b085c1828f69296a0000ff2f9d7971ca036427e31939e2eec09c0000ff1f495f4ec430d7f5971326a3540ea90000ff0e57e5ead848d11f1901544271c3f80000fefcc917b99839a5e0abd3a9b64df7250000feea9cff8fa2ae54ec34413e87ef27400000fed7d3a8a29c603b2f88b949a72ff96c0000fec46d1e89292cf041390efdc726e9ef0000feb0696d3ae4f04db7b6cc53c3abc8170000fe9bc8a1105c22a5d3af6ee4f2101c200000fe868ac6c3043b2e0b4f70c910505e100000fe70afeb6d33d6a22907cf2b3f6feac20000fe5a381c8a1aa224d54faa364b7da8f60000fe432367f5b90a6287b8875373a818a40000fe2b71dbecd7aefc008598c2c429caf70000fe1323870cfe9a3d90cd1d959db674ef0000fdfa3878546c3d289bfe5c51e91cbdcd0000fde0b0bf220c2fd4e276d247626a23fd0000fdc68c6b356db62f499ddb331d19539d0000fdabcb8caeba091bfac7397cc07a64700000fd906e340eaa6401d6e270740a1869770000fd747472367dd6c561beb8cd2696fc780000fd57de5867eedc396c696582f346fd910000fd3aabf84528b50beae6bd951c1dabbe0000fd1cdd63d0bc8735863b87258f11ad7e0000fcfe72ad6d9641f2a06fab9f9d1067090000fcdf6be7def1464ca4e064308f4999f40000fcbfc926484cd43aa3e22b4d38917e730000fc9f8a7c2d603c605d582cac7cb4391c0000fc7eaffd720ed67302880268f2e629550000fc5d39be5a5bbc4b1c0d254b6c8da4bd0000fc3b27d38a5d49ab256778ffcb5c17690000fc187a52063060c29433b49289417ea20000fbf5314f31eb737525aafd7fdba12c5f0000fbd14ce0d191516e7190c94899dff1b80000fbaccd1d0903bb09e63ae8632b84473c0000fb87b21a5bf5b91775df66f0ec3dd4590000fb61fbefadddb98561ce9d5ef5a814870000fb3baab441e770f7b4b54683879c9c170000fb14be7fbae581562172a361fd2a722f0000faed376a1b42e5592079880c450348ac0000fac5158bc4f4211f4a188aa367f90ab10000fa9c58fd796837d410655ecd5cc771d80000fa7301d8597966711fe196a53fb5b2370000fa491035e55da3a3d24377c77a591e240000fa1e842ffc96e4e0431c393c7f62da650000f9f35de0dde328abba5dbf4510eddc8f0000f9c79d63272c46284504ae08d19b29800000f99b42d1d57781eb78685d850f80ecdc0000f96e4e4844d4e82a80e8c17bf80e8f020000f940bfe2304e6c45c0e2a1352ed7f2920000f91297bbb1d6cdbe68fc6e4d6a920bd20000f8e3d5f1423842a09701914c7f8fbcd70000f8b47a9fb902e76cac9f07f54ff5bc140000f88485e44c7af48ab36a9dfaadafc1e10000f853f7dc9186b952c7adc6b4988891bb0000f822d0a67b9c5cb5a776175bd284fe050000f7f110605caf6390a76f7efc19aed41c0000f7beb728e51dfcb8730785813f78aa1e0000f78bc51f239e12c6214cffcee9dd33ca0000f7583a62852a23b24becad887680c1970000f7241712d4edde49f99107e50d6313300000f6ef5b503c32858950ca117eb18beed70000f6ba073b424b19e82c791f59cc1ffc230000f6841af4cc8048a4ce8c455197cdf8a70000f64d969e1dfc2119119d358de04939560000f6167a58d7b590269dc7e5954c5a8f240000f5dec646f85ba1c6c8c615e72768d6b50000f5a67a8adc4088caed0dd4bf62edd13f0000f56d97473d446cda275a2bbb2bab6c8a0000f5341c9f32bffeb98da64484aaa0febc0000f4fa0ab6316ed2ec163c5c7f03b718c50000f4bf61b00b5982b7890ac4aafa6a37bf0000f48421b0efbf939bf8f9d3b87d11fd520000f4484add6b01254b667e06866c07c3690000f40bdd5a6688662f5019794a1f5896e50000f3ced94d28b2ce8a18ef535a7ffa7a3d0000f3913edb54ba224250f29b4b49f31c370000f3530e2aea9d39660d981acdcf6bc3e40000f314476247088f74a5486bdc455d56a20000f2d4eaa8233e997d431be53f92ece9e60000f294f82394ffe320ebadcdbf915e8f6c0000f2546ffc0e72f286af0eed81e8c51e550000f21352595e0bf350e7112e89103cc0c70000f1d19f63ae7428a2844e6a35ddc2b7130000f18f5743867126438f6bac72988088b00000f14c7a21c8cbd0f42730081c758fb42b0000f1090827b43725fd67127db35b2873160000f0c5017ee336ca0fc4e557b119ef31850000f08066514c055f7e973ea9903ed5125f0000f03b36c9407aa3e8992d39ec5c561d280000eff573116df1555d62aef7b55319d1d40000efaf1b54dd2cdf0ff03a18a5e16ab6410000ef682fbef23ecda6767c0e8ad33bc0850000ef20b07b6c6c0b37e2398bf0eeb28cde0000eed89db66611e30786f8c20fb664b01b0000ee8ff79c548acd0fa1d2c3d018a9279f0000ee46be5a0813016b7872773830d368be0000edfcf21cabacd3b1fee6a1eebfa13b4a0000edb29311c504d65211815196b9fbf5df0000ed67a1673455c6017289102076a125e50000ed1c1d4b344c3d4fddffe98c4f8aa0310000ecd006ec59ea306fa8392eb238578ab00000ec835e79946a31457e610231ac1d61810000ec3624222d227bd10278047ae3dd08890000ebe85815c767cb001e99ccb9adc62ca60000eb99fa84606ff5ff0dae311e656e06610000eb4b0b9e4f34561739e39c6c2ab3655d0000eafb8b944453f52f3383bbb5156bf1d70000eaab7a9749f584fe24db98ad3a0647a10000ea5ad8d8c3a91f054a0ca5ea449b1c830000ea09a68a6e49cd6215ad45b4a1b5e8230000e9b7e3de5fdedc8bcd24d4bd1056c8260000e9659107077cf60f89a92b199adfbafa0000e912ae372d27045dacb1c26a06e5ae020000e8bf3ba1f1aedfbbf8972affb3d98e1f0000e86b397ace95c46f9fec1e78c43761860000e816a7f595ec9232bfe8378abfb87b6f0000e7c187467233d508dbfb0fe56c6f80fe0000e76bd7a1e63b9786125129529d48a92f0000e715993ccd02fe9ce2ba81b9ce96e02e0000e6becc4c5997af0682fcedb4c6434d760000e667710616f4fc59dd2a3e32c38599600000e60f879fe7e2e1e57613b68f6ab031300000e5b7105006d4c5609b695cd67c93bd790000e55e0b4d05c803885a7c210a3a15e7ea0000e50478cdce2246bce1f5a58c802925540000e4aa5909a08fa7b4122785ae67f5515d0000e44fac3814e0985620d63b5b9e3cd6ac0000e3f4729119e798d956992551ae074e990000e398ac4cf556b7320d1197dc12c631760000e33c59a4439cd8ec36563e2ffad8351a0000e2df7acff7c2cf83d6fe4dd22e60a4a20000e28210095b483751fd39138aa2d508ed0000e224198a0e002123e0521df01a1be6f50000e1c5978c05ed8691f4e8a8372f8c58100000e1668a498f1f892ce2f9d4600f4d03250000e106f1fd4b8d7c966ba8a9d9ba8778990000e0a6cee232f2bb9c6d6c98fe798179460000e046213392aa486c55ff6038a51973670000dfe4e92d0d8a37f5720588ff6547d8840000df83270a9bbee890ab01350f013d78dd0000df20db088aa6040464a58b2f103485dd0000debe05637ca94cfb4b19aa71fec3ae6d0000de5aa6586919380504248f15548f69ca0000ddf6be249c075037d597b10a016766590000dd924d05b620678a739c45b982193b5e0000dd2d5339ac8692fd49c6e0ea76cbcaac0000dcc7d0fec8aaf2aab2069fd0b482b4e80000dc61c693a82745d5aca8017e375b64e50000dbfb34373c974b0eccb7fd40d543f4a10000db941a28cb71ec872c19b63253da43fc0000db2c78a7ede238a95a98479cbef2ecbc0000dac44ff490a027105b267c1bcff0ab620000da5ba04ef3c929f4e257bde73d83dc1a0000d9f269f7aab88c2928e81dcb6dab91ac0000d988ad2f9bdf9bbbc4e4dc69fc2fff6f0000d91e6a38009da15a1bb35ad6d2e74b670000d8b3a1526517a48b1ed1a8ff78f1b6320000d84852c0a80ffcdb24b9fe00663574a40000d7dc7ec4fabdb011ced12d2899b803db0000d77025a1e0a39d8b0cb78e80e67ba1b80000d703479a2f6776cc6cb3bfd65b38562b0000d695e4f10ea88570083f082b570611d70000d627fde9f7d63e7e7afbefc05e9f7d990000d5b992c8b606a3517190b755535d4f180000d54aa3d165cc70187d00ae97abaa40960000d4db3148750d1819f630e8b6dac83e690000d46b3b72a2d68fc9dc4663a3168698d20000d3fac294ff34e4d0b77d4f6bd0ee85910000d389c6f4eb07a41ca8faac741a6394dc0000d31848d817d70e16eeeaddb72f00e0dd0000d2a6488487a919184300fd1c1ce507e50000d233c6408cd64236981ba7e42537275f0000d1c0c252c9de2c86da7485a5aeffeb4c0000d14d3d02313c0eed744fea20e8abef920000d0d93696053af09877a18eb13d2ecde50000d064af55d7c9b43e6b8a685f6cb61c210000cfefa7898a4ef23cdaf200dd81212d100000cf7a1f794d7ca1b1dfcb60445c1bf9730000cf04176da12390ac04d27090f10c454e0000ce8d8faf5406ab8bf5babff66def78920000ce16888783ae13b393e391861a0346840000cd9f023f9c3a059e23af31db7179a4aa0000cd26fd2158358e7d649474e36b8db9d30000ccae7976c069117783e907fbd7aaf0b00000cc35778a2bac9ca1f839ce18e08bfb500000cbbbf7a63eba0dd570cbb7f3343451be0000cb41fa15ebff07772293661be51140ab0000cac77f24736eb553d9944be1631846d80000ca4c871d625361a95328edeb3e6784de0000c9d1124c931fda7a8335241be16932250000c95520fe2d40a74b83b0e96e1249c2b00000c8d8b37ea4ed0f620b562c00b34ee7710000c85bca1abaf7f0a765862939b83382e00000c7de651f7ca0674902b31bc86877fd2c0000c76084da43624634d5c149509e9059f10000c6e22998b4c6608ecfe6c1b1a6b4e2a40000c66353a8c232a43ce993503baf5afb410000c5e40358a8ba05a743da25d99267326b0000c56438f6f0ec3cca0ab4906075507e740000c4e3f4d26ea553b6dd40950cf1ed92fa0000c463373a40dd06a39dd768f30ca8e85c0000c3e2007dd175f5a4a87e78136665cdb20000c36050ecd50ca8308ac9e1386e4cbabb0000c2de28d74ac6628b74c8f010d986a9e00000c25b888d7c1fcd38b7041e9bc8c18b0d0000c1d8705ffcbb6e90bdf0715cb8b20bd70000c154e09faa2ff69a17858573216e0a220000c0d0d99dabd65d442bda5328933c854a0000c04c5bab7297d3226dd06968e0ed19570000bfc7671ab8bb84c6e4e62d86dd136e780000bf41fc3d81b430db0d46655d6b0124550000bebc1b6619ed91162715ef03f85433550000be35c4e71699963029d7f7b67d43b1770000bdaef913557d76f0ac85320f528d6d5d0000bd27b83dfcbe92792ea36923d5d8e2130000bca002ba7aaf25ea4a48496734be336d0000bc17d8dc859ad583727c405ffc73af560000bb8f3af81b93095cfce8d84068e825b60000bb062961823b1ddc5120e35e1c1a250c0000ba7ca46d4694680233201477347447d80000b9f2ac703cca0db339db32d0144400240000b96841bf7ffcb21a9de1e3b22b8bf4db0000b8dd64b0720df647a726f4f0828585c90000b8521598bb6bce261c041d1ea5fb3fdb0000b7c654ce4adba9f22e7a35723f3ed0350000b73a22a7554574487f86f63bb23f496a0000b6ad7f7a557e64f2eb2d28ef943dc88c0000b6206b9e0c13a892ea7c015f12b987f70000b592e7697f14dd4a737dd2824b608d130000";
	// 6 dints
	static inline var PS = "c90fdaa22168c234c4c6628b80dc1cd10006a55de7312df295f55dc72f712aa57db4000da335e33bad570e923f33be0021aa54d2000e9969667315ec2d9de59d6ab8509a2025000fa83c1a43bf1c64857d5f8f76fa7d74ed000cf16ab2898eae62f9a7f0339113b8b3c50009";
	// 6 dints
	static inline var PC = "8000000000000000000000000000000000029de9e64df22ef2d256e26cd9808c1949000b81e0f840dad61d9a9980f00630cb655e000eaae9e3f1e5ffcfe2a508509534006249000ff0fa83448dd1e0940e0603ce7044eeba000cd368f6f4207cfe490ec63157807ebffa000b";
	// 768
	static inline var SC = "000000000000000000000000000000003ff0000000000000bdcc0f6c000000003f6921f892b900fe3feffff621623fa0bdc9c7935e0000003f7921f0ea27ce013fefffd8858eca2ebddd14d1ac0000003f82d96af779b0bb3fefffa72c986392bdedba8f6a8000003f8921d1ce2d0a1c3fefff62169dddaa3dfa6b7cdf0000003f8f6a29bdb737703fefff0943c024193deb49618d0000003f92d936d1506f3d3feffe9cb44829c0bdc398d6fc0000003f95fd4d1e21de6d3feffe1c687174b1be0e9e9a8c8000003f99215597791e0a3feffd886097afcfbdf34e844c0000003f9c454f2e9480c73feffce09ce95933bdf989a8a40000003f9f693709b94f923feffc251dfbac0c3e104a9b990000003fa146860e69a5713feffb55e40a5c43bdb56947c00000003fa2d865748774ad3feffa72efff95d1bdcc3487680000003fa46a396d34121a3feff97c420a84513df9e805520000003fa5fc00e6e4c65c3feff871dacd87613dd3f11d740000003fa78dbaa97099eb3feff753bb18af953dec039af40000003fa91f65fc0abc0a3feff621e370ca7a3dc53e1f800000003faab101bf74ac2e3feff4dc54b001813e2114a6490000003fac428d7de920e93feff3830f2e90433e0adf0ef40000003fadd40723a3cdfb3feff21614b9d9adbe1d21f5918000003faf656e1e9e59cd3feff09565e83d77be14f54d708000003fb07b612d6be0783fefef0102c634e3be11efec9a0000003fb1440118ba7bd03fefed58ecf342da3e2cc17ba88000003fb20c96cf0a7eed3fefeb9d24646fa63de121dbe40000003fb2d5209628edf03fefe9cdacf99cffbdd9ecf6100000003fb39d9f103bf7f73fefe7ea854e6b08be004ede8e0000003fb466116c629e5c3fefe5f3af4ee201be01821cec0000003fb52e773c9920c73fefe3e92c0e41083e0cdec7260000003fb5f6d02131f0b23fefe1cafc7f1a24be0edece4d0000003fb6bf1b2653648c3fefdf99233c230cbe02aa4d1c0000003fb787585bc45f0f3fefdd53a01d11d93dfd4615920000003fb84f871e32cf683fefdafa74f164823e2f0cbd728000003fb917a71d3d29563fefd88da29f302ebe158324700000003fb9dfb6c9865b063fefd60d2e14a6b1be12e81bf40000003fbaa7b706bfdbba3fefd3791484ff50be313941418000003fbb6fa680a05c273fefd0d15a4b84713e171098ff0000003fbc3785eba12b423fefce15fceddccfbdfc3519e80000003fbcff53302f05903fefcb4703b969e13e42f522a50000003fbdc70fb84af16e3fefc8646987fc1dbdeae9bed80000003fbe8eb7f8a589e23fefc56e3b91ca3a3e1f8868b20000003fbf564e87d2330f3fefc264701f9a09be2b07985f8000003fc00ee8835051f43fefbf47105f74393e1cbdaa940000003fc072a05e1d4d8e3fefbc16172a9e363e337c5b908000003fc0d64df9619f0d3fefb8d18b635327be3068b5fc8000003fc139f09bc617f53fefb5797351da85be28ea66818000003fc19d8919fa4ec83fefb20dc7da8aff3e36278ceb8000003fc2011719d50b873fefae8e8bd4427fbe2096df840000003fc264993433763a3fefaafbcbfca3563e29b2534f0000003fc2c810967bbf703fefa7557d8d987e3dd215b4e00000003fc32b7bfa25c91b3fefa39bac71954bbe194db8910000003fc38edb9d29b39d3fef9fce56700a6d3e27727f7b8000003fc3f22f7c3cce3a3fef9bed7b8c8d8cbe20cb33038000003fc45576971dd5303fef97f925d53c83be090711060000003fc4b8b175c71e223fef93f14feb80223e262741e78000003fc51bdfa7ea30d53fef8fd5fe3efac83e3f8e16d0c000003fc57f00e80e6e123fef8ba733a1ceb1be076acbca0000003fc5e2143b7bc1c23fef8764fad5e9bfbe10a0f73a0000003fc6451a764117463fef830f4ad232d83e3ca11d1bc000003fc6a8135d7bd1433fef7ea625eb5af7be202f23628000003fc70afd740711913fef7a299d3f182a3e2b34dcb80000003fc76dda08544b5c3fef7599a1ac7ecd3df161ff400000003fc7d0a7bf2d4aba3fef70f64322da74be0c49b8b40000003fc83366ddb3de233fef6c3f7e7c27073e221da8510000003fc8961743b142903fef6775552a6ba23e1ac63eda0000003fc8f8b8510985883fef6297cef0cdd63e427ef489c000003fc95b4a5b9f2ceb3fef5da6e78205513e1ae893700000003fc9bdcc079001463fef58a2b0689c823e2eb48c7e0000003fca203e4a4f950e3fef538b1d392049be2bfd282f0000003fca829ffaad0d793fef4e603d51f1aa3e27ccf6380000003fcae4f1fa80e1b53fef492204c5ef9ebe32435c578000003fcb4732b72ebc863fef43d0890e1e723e10293fec0000003fcba9634155f8663fef3e6bbb6c2ea4be27bb1f920000003fcc0b82461f65e03fef38f3ae6f9afc3e227aaebc0000003fcc6d906faacf653fef3368589e17a2be42e2bcd50000003fcccf8c3f74a6c93fef2dc9cfb5fa74be16f070ac0000003fcd31773ba218a83fef2817fd4d045b3e2469adfc0000003fcd935004779e573fef2252f59c122d3df4f51c180000003fcdf5164301377a3fef1c7abdeaa3ef3e278e44da0000003fce56ca4202807c3fef168f51c5d5d53df49bb5f80000003fceb86b4a1b7e9b3fef1090bc4b6800be367ba5410000003fcf19f9369d5e933fef0a7effdc937f3e2c0cab950000003fcf7b74ab7219d23fef045a1219e594be12b77e320000003fcfdcdc0ca3288d3feefe220cf5c751bdee0d8cb00000003fd01f18054c83623feef7d6e54c347dbe2ecd5b9c0000003fd04fb7f6d35d683feef178a6f9a9873e2eb24de50000003fd0804e1d369ff23feeeb074934fdf03e14a897c40000003fd0b0d9d7b0d0423feee482e14bcde03e1336c3760000003fd0e15b555e7bec3feeddeb6908ca8cbe03952d900000003fd111d25efd48b83feed740e7eb8dd63e0fc2a5d40000003fd1423ef5c7e1bd3feed0835dc24e893e2a88ed370000003fd172a0eb8361da3feec9b2d0ec8288be48ca4cb94000003fd1a2f7b10b6d703feec2cf55d6117c3e401445240000003fd1d3446fd0cd3f3feebbd8c1d62f96be3abf810c0000003fd203855b85f89a3feeb4cf574541323e35d4c5d58000003fd233bbcca405613feeadb2e40746cabe2a1b0c580000003fd263e685b1d7143feea68396d87754be277c8dac0000003fd294061d2eb6113fee9f41597393c83e1915540e0000003fd2c41a580014cf3fee97ec348fb87fbe3abb6d9b0000003fd2f422b2d0990c3fee90843c55b996be3b8ee5d58000003fd3241f8cea28363fee890962268c49be31cd29828000003fd35410a83962663fee817baf85c094bdfe216af00000003fd383f5e08283e23fee79db2a188b0abe024afc300000003fd3b3cef6993c0b3fee7227dbf82004be0aa1657c0000003fd3e39be47672243fee6a61c62d5274be1c5b65fa0000003fd4135c898485bb3fee6288ee07fea53df23e89780000003fd44310de3c284b3fee5a9d54bbd26cbe22b1d77a0000003fd472b8976d498d3fee529f06cb187dbe0daaa3480000003fd4a253cb97efd13fee4a8e007231a2be3322f5708000003fd4d1e2260c34223fee426a500f6e333e264758e80000003fd50163eca0b3373fee3a33e996b7223e312486278000003fd530d89a17e0073fee31eae3fb917bbe46c3416cc000003fd5603fcf8cd8a33fee298f502a579b3e2ab481ff0000003fd58f9a896aa2093fee2121016e14fcbe26eb838b0000003fd5bee77aaf890b3fee18a032eb4df5bdfd159b800000003fd5ee2734efeef53fee100ccaa6bd78bdda42e4a00000003fd61d595bedeabc3fee0766d944915ebe143d0dc00000003fd64c7dd5cc0cd13fedfeae63903034be48c7bdb70000003fd67b9453ca21223fedf5e378482eae3e11c0ead60000003fd6aa9d844c980a3feded05f6a23a523e07d526000000003fd6d99867e90d923fede4160e97b2e23e3924e0368000003fd7088555d3c8163feddb13afb14e37be174b7c3e0000003fd73763c09fba093fedd1fef5335416be17943ad00000003fd766340685c9823fedc8d7ccf2567a3e279dd6140000003fd794f5f7522b883fedbf9e402aa5c33e17b64f320000003fd7c3a939c32d813fedb652607e0db1be32bea5ce8000003fd7f24db825141c3fedacf43268b5b03e1733c0240000003fd820e3b8bf15a03feda383a7aed887be4eac0fc94000003fd84f6a51d077b33fed9a00efd845373e4aca37338000003fd87de2f4704f983fed906bbf17f4dabe1910c4f00000003fd8ac4b7dc0d9863fed86c4862b5d6ebe033bb8600000003fd8daa52b4dc0413fed7d0b0374a559be469e15070000003fd908ef408ad2203fed733f5e71c3bc3e4cffacf08000003fd9372ab7784d363fed696161d786c9be58629d9f0000003fd965552b0849ab3fed5f7190eeae233e141500000000003fd99371687c64f33fed556f5155d9ddbe4bd37aad8000003fd9c17cf40715cb3fed4b5b2caf83863e5d02cde70000003fd9ef79ea4d995d3fed4134ac5eb246be110547ac0000003fda1d653d9adf5e3fed36fc7d291602be401a1a228000003fda4b40f9c0120b3fed2cb22b45236b3e23ce2bac0000003fda790ce2056b9a3fed2255c3ae11a5bdfccb4a600000003fdaa6c828db4ea83fed17e774d4e3e23e25db4b000000003fdad47321f298473fed0d672bc0b1223e232f6a6e0000003fdb020d7a285e233fed02d4fb84d3343e5cf8e39bc000003fdb2f97c27f74943fecf830c2248c5e3e18927bb00000003fdb5d10129a750a3feced7af22cb105be33dec3c10000003fdb8a77f8d0bbc53fece2b32e50d6cdbe326ba5360000003fdbb7cf08f0290d3fecd7d98fcf3b1e3e223c568e0000003fdbe51524e3aa533fecccee1da3d56ebe2f3b3af00000003fdc1249c1f5f2f63fecc1f0f95e1e24be31286a470000003fdc3f6d2ef7054b3fecb6e20ff37e813e2641214e0000003fdc6c7f594003d93fecabc165bf1b603e40cda7c90000003fdc997ff2bffccb3feca08f0dee434cbe35557ac90000003fdcc66e7b42e8f13fec954b28bca62e3e3555eb620000003fdcf34bccc567a13fec89f57f6e20f3be34e0e3610000003fdd2016cbb5e39a3fec7e8e59999e1f3e2446da1e0000003fdd4cd039d0ed053fec731585f970eb3e2103d3280000003fdd797767638dec3fec678b3174afe13e35814d600000003fdda60c7ae9dc223fec5bef522be6fbbe25e2321e0000003fddd28f054cbb3f3fec5042052c8c42be2a259ffe0000003fddfeff548546313fec44833611bc7dbe04f28d800000003fde2b5d34665b353fec38b2f278ea7ebdbde571000000003fde57a86d137f203fec2cd1493d05c23e2e0d8d140000003fde83e0ffb7bfb43fec20de3a08ea07be312a858e0000003fdeb0067e48baf43fec14d9e2bd511e3e49a174030000003fdedc19997a44313fec08c413089b2e3e268c86360000003fdf0819163d1bc03febfc9d21568f323e24cc5eb80000003fdf3405a482e11d3febf064dd580fc9be4fce7cd80000003fdf5fde8f3f11d43febe41b798f6b97be2af816900000003fdf8ba4c98a98163febd7c0b1a7f14b3de6e39e200000003fdfb7575d1ea7503febcb54cac5dde53e330f92560000003fdfe2f665dcd1683febbed7bd1e17b03e0626de200000003fe00740ca0d5fbb3febb2499f9fe7a33e15cc70300000003fe01cfc8afeea0e3feba5aa650dd495bdf6191e600000003fe032ae54fe40573feb98fa2065a5e6be06b148500000003fe0485624c328c83feb8c38d39737bcbe211fbc3a0000003fe05df3e66a716d3feb7f668a580fd0be40eca7f00000003fe07387825589ec3feb728352c44517be68073bc9e000003fe089109ef1284d3feb658f630112edbe49dcf0ad0000003fe09e9051603e293feb588a13ab750fbe206ea9f00000003fe0b405820e78e73feb4b740d3cc07bbe136a8d0c0000003fe0c9704a1ea4e53feb3e4d40f5524d3e163d1f300000003fe0ded0bc01a5333feb3115a3a628af3e5f3181f14000003fe0f4270e4787bf3feb23cd1314c779be2f269b780000003fe109723e75c5cf3feb167430cfebdb3e41d84dc08000003fe11eb36bc9db523feb090a4915ee88be408e60068000003fe133e9ba0061d83feafb8fe69a65273e4cda72ab0000003fe14915d557a7c93feaee049bc0aee0be1f32f9500000003fe15e36dfb6bb553feae068f69916993e3138092d0000003fe1734d6f34d7f03fead2bc96c1e1f53e56b382dd4000003fe188595ae376a53feac4ff962bdb6dbe3f12fafa0000003fe19d59f592a5873feab7326685eb57be32909e5a0000003fe1b2500aed7ac63feaa954823cf815be6d66a8978000003fe1c73aa0150cf93fea9b668fb0503f3e4311ea860000003fe1dc1b7db74db13fea8d675d9c6cc8be041c02b80000003fe1f0f08a1a06a43fea7f5853bb4309be5ca1f4ed0000003fe205ba572112713fea71391146958fbe3910ce770000003fe21a7988f8326b3fea63092626202f3e62bfadbee000003fe22f2dc71afab63fea54c8cd9fd0d9be45f1c02a8000003fe243d5df4afb933fea4678dbbe5e73be1db12b900000003fe2587347f493a43fea38184db0df23be17b29e000000003fe26d05490f2f613fea29a7a2f40b49be2b3ddca40000003fe2818be69306293fea1b26d8f070d73e2e1127440000003fe2960730ff2bcd3fea0c95e3df5e0ebe352697660000003fe2aa76dafcbbf43fe9fdf4fae1df6fbe309777e10000003fe2bedb1b6b4e153fe9ef43f6cbe1623e3ae2051f0000003fe2d333e4617f253fe9e082e148680ebe436f6ced8000003fe2e780cb47180e3fe9d1b207f383c3be323fdc6b0000003fe2fbc23fba2f443fe9c2d1197130a73debc540e00000003fe30ff7fd6d967d3fe9b3e0478b961bbe3cfb4ed70000003fe32421da0bf0e93fe9a4dfb1c893263e555802aec000003fe3384042a92b1d3fe995cf06920d113e360719e40000003fe34c52608e3a923fe986aee6d6837ebe1cbf2e480000003fe36058ac8863b63fe9777ef832c9863e49061c320000003fe374533ab707d03fe9683f2ad7e2ecbe4da84dfe0000003fe3884160f9488f3fe958f000fdd50a3e292e8a740000003fe39c23eba6b22a3fe94990dd9cee51be2bff5d9a0000003fe3affa20756bdd3fe93a225056084a3db4c462000000003fe3c3c4498e98eb3fe92aa41fbb951cbe3e4613e90000003fe3d782261dff623fe91b167e92d7063e10eb29640000003fe3eb33ed579bbe3fe90b794146043cbe260abec20000003fe3fed94c834d8a3fe8fbcca95834793e469549770000003fe4127281ddac033fe8ec10850835533e2a16fec20000003fe425ff1f8412353fe8dc452ca328d3be427bcdd30000003fe4397f44aa44f23fe8cc6a8771e165be360dded40000003fe44cf317a563db3fe8bc8076122736be59a8f405c000003fe4605a2b02d7053fe8ac875232f3ef3e432777dc0000003fe473b532bc5a673fe89c7e8713120cbe51418a7b0000003fe4870306ca20e23fe88c670a0ea774be3fed182e0000003fe49a44886b53403fe87c401fdf05e53e486144d80000003fe4ad796ea1410c3fe86c0a04dbacc53de1bc2e600000003fe4c0a14640d2af3fe85bc51aa114c2be3f53d2fe0000003fe4d3bc5aaa8cd53fe84b7121b30a13be12e100a00000003fe4e6cab91556be3fe83b0e0e6b6cccbe2fa58c620000003fe4f9cc1c69fdde3fe82a9c1c1ab4633debb491e00000003fe50cc09fdcbd923fe81a1b3342f8583e3a1154100000003fe51fa82c3aa0293fe8098b67ea85093e4ab0a5d30000003fe53282b20b96b63fe7f8ecc7919530be3cba04380000003fe5454fe43a7d7c3fe7e83f96af78a0be20dd83a40000003fe5581033a815733fe7d783712e20ecbe3e9a82990000003fe56ac33fbb82533fe7c6b8acf90fa63e2225c4aa0000003fe57d6939d4b5133fe7b5df1da18065be482e66e00000003fe59001b9e64d793fe7a4f72157cfdf3e551a6a354000003fe5a28d5b36d5973fe794002a7c90233e513917f40000003fe5b50b4e10bec13fe782faf6dc7ba23e149310cc0000003fe5c77bc15ab4ef3fe771e75c43942e3e124d493c0000003fe5d9dee9de49db3fe760c529bc17b0be504638f70000003fe5ec347044e0f43fe74f94b0af9720be23f41b280000003fe5fe7cb834600c3fe73e55936a5160be1a5f6f5c0000003fe610b7515d15623fe72d083b8214eb3e319fb2e00000003fe622e459eafbc13fe71bac8c7b0592be356d2c2b0000003fe6350396fe4e623fe70a42bec51665be33c156c20000003fe64715385bed933fe6f8caa4969708be2f23e5760000003fe659191d2fd57f3fe6e7445d74f7113e11e4be380000003fe66b0f41d484c43fe6d5afecd4938dbe4397cc8d8000003fe67cf76eac73df3fe6c40d89625f63be3202f6860000003fe68ed1e09905513fe6b25cf728c350";
	// 256
	static inline var TINV = "ff00ff00ff00ff02fe03f80fe03f80fffd08e5500fd08e56fc0fc0fc0fc0fc11fb18856506ddaba7fa232cf252138ac1f92fb2211855a867f83e0f83e0f83e11f74e3fc22c700f76f6603d980f6603dbf57403d5d00f5742f4898d5f85bb3952f3a0d52cba872338f2b9d6480f2b9d66f1d48bcee0d399fcf0f0f0f0f0f0f0f2f00f00f00f00f010ef2eb71fc4345239ee500ee500ee5010ed7303b5cc0ed731ec979118f3fc4da3ebbdb2a5c1619c8deae56403ab959010ea0ea0ea0ea0ea10e939651fe2d8d35de865ac7b7603a198e79372e225fe30dae6c2b4481cd8568ae5f36cb00e5f36cce525982af70c880fe45932d7dc52100fe38e38e38e38e38fe2c4a6886a4c2e11e1fc780e1fc780e3e135a9c97500e137e070381c0e070383dfac1f74346c5760dee95c4ca037ba58de27eb2c41f3d9d2dd67c8a60dd67c8bdca8f158c7f91ab9dbeb61eed19c5959db2f171df770291ada740da740da740fd9ba4256c0366e92d901b2036406c80fd84a598ec9151f44d79435e50d79435fd6df43fca482f00ed62b80d62b80d62cd578e97c3f5fe552d4c77b03531dec0ed4173289870ac52ed3680d3680d3680ed2ba083b445250acd20d20d20d20d20ed161543e28e50275d0b69fcbd2580d0cd00d00d00d00d00ecf6474a8819ec8eacebcf8bb5b4169ccce168a7725080ce2cd712752a886d243cccccccccccccccecc29786c7607f99fcb8727c065c393e1cae5d85f1bbd6c96ca4587e6b74f032ac9a633fcd967300dc907da4e871146adc86a78900c86a78ac7ce0c7ce0c7ce0dc73293d789b9f839c6980c6980c6980dc5fe740317f9d00dc565c87b5f9d4d1cc4ce07b00c4ce07cc4372f855d824ca6c3a13de60495c774c30c30c30c30c30dc2780613c0309e02c1e4bbd595f6e948c152500c152500c2c0c0c0c0c0c0c0c1c0300c0300c0300dbfa02fe80bfa02ffbf112a8ad278e8debe82fa0be82fa0bfbdf59c91700bdf5abd69104707661aa3bcdd535db1cc5b7cbc52640bc52640bdbbc8408cd63069a1bb3ee721a54d880cbab656100bab6562ba2e8ba2e8ba2e8cb9a7862a0ff46588b92143fa36f5e02fb89bc36ce3e0453bb81702e05c0b8171b79300b79300b794b70fbb5a19be3659b68d31340e4307d9b60b60b60b60b60cb58a485518d1e7e4b509e68a9b948220b48a39d44685fe97b40b40b40b40b40cb38cf9b00b38cf9bb30f63528917c80cb2927c29da5519d0b21642c8590b2165b19ab5c45606f00cb11fd3b80b11fd3cb0a59b418d749d54b02c0b02c0b02c0bafb321a1496fdf0faf3addc680af3adeaec33e1f671529a5ae4c415c9882b931add5e6323fd48a87ad602b580ad602b6aceb0f891e6551bcac7691840ac76919ac02b00ac02b00acab8f69e28359cd12ab1cbdd3e2970f60aaaaaaaaaaaaaaabaa392f35dc17f00ba9c84a47a07f5638a957fab5402a55ffa8e83f5717c0a8e9a87917088e262b70a80a80a80a80a80ba79c7b16ea64d422a72f05397829cbc2a6c21df6e1625c80a655c4392d7b73a8a5e9f6ed347f0721a57eb50295fad40ba513fd6bb00a5140a4a9cf1d96833751a44029100a440291a3d70a3d70a3d70ba36e71a2cb033129a3065e3fae7cd0e0a29ecf163bb6500aa237c32b16cfd772a1d139855f7268eea16b312ea8fc377da105a932f2ca891fa0a0a0a0a0a0a0a1a03c1688732b30329fd809fd809fd80a9f747a152d7836d09f1165e7254813e29eaecc8d53ae2ddf9e4cad23dd5f3a209deb06c9194aa4169d89d89d89d89d8a9d2921c3d64113089cc8e160c3fb19b99c69169b30446dfa9c09c09c09c09c0a9baade8e4a2f6e109b4c6f9ef03a3caa9aee72fcf957c10f9a90e7d95bc609a99a33cd67009a33ce99d722dabde58f06997ae76b50efd00a991f1a515885fb3798c3bac74f5db00a9868c809868c8099980e4156201301c897b425ed097b425f975a750ff68a58af97012e025c04b80a96a850096a850097964fda6c0964fda795f7cc72d1b887e995a02568095a02579548e4979e0829fd94f2094f2094f209949b92ddc02526e5944580944580944693efd1c50e726b7c939a85c40939a85c93459be6b009345a92f113840497889c929cebf48bbd90e5924924924924924991f5bcb8bb02d9cd91a2b3c4d5e6f809915009150091500990fdbc090fdbc09190abcc0242af3009905a38633e06c43b90090090090090098fb823ee08fb823f8f67a1e3fdc261798f1779d9fdc3a2198ec7ab397255e41d8e78356d1408e7838e2917e0e702c6ce8dda5202376948098d8be33f95d715908d3dcb08d3dcb08d8cf008cf008cf0098ca29c046514e0238c55841c815ed5ca8c08c08c08c08c098bbc50c8deb420c08b70344a139bc75b8b246a87e19008b28ad8f2fba93868238a8dcd1feeae465c8a42f8705669db4689f87469a23920e089ae4089ae4089ae89645c4f6e055dec891ac73ae9819b5088d180cd3a4133d78888888888888889883fddf00883fddf87f78087f78087f887af6fd5992d0d408767ab5f34e47ef1872032ac1300872086d905447a34acc6869222b1acf1ce96864b8a7de6d1d60886053c345a0b847385bf37612cee3c9b85797b917765ab89853408534085340884eedd357c1b008584a9f9c8084a9f9d84655d9bab2f1008842108421084210883dcf94dc7570ce1839930523fbe33688355ace3c897db1083126e978d4fdf3b82cf750393ac3319828cbfbeb9a020a3824a4e60b3262bc5820820820820820881c635bc123fdf8e81848da8faf0d277814327e3b94f462f810204081020408180c121b28bd1ba98808080808080808180402010080402018000000000000000";
}
