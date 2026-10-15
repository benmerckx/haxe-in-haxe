package hxmc.rt;

import hxmc.I64;
import hxmc.rt.LibM.fma;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// asin, acos, atan and atan2, correctly rounded: the CORE-MATH project's
// src/binary64/asin/asin.c, acos/acos.c, atan/atan.c and atan2/atan2.c
// (with atan2/tint.h; commit dae5dd8, 2026-10-15) by Alexei Sibidanov and
// Paul Zimmermann, MIT (hxmc/std/hxmc/rt/LICENSE.libm).
// Rounding to nearest only; the exceptions flags and errno are not kept.
// C's __builtin_fma is LibM.fma, or LibM.fm in the fast paths, specialized
// for the processor's fma and without it (hw, LibM.useHw), all exact; the
// expressions keep C's order of evaluation (the code is correctly rounded
// with or without contraction: none here). atan2's accurate path computes with 192-bit significands
// (tint: in memory, 32 bytes: h, m, l, then ex and sgn as 32-bit words).
@:keep @:allow(hxmc.rt)
class LibMArc {
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

	static inline function copysign(m:Float, s:Float):Float
		return ofBits((bits(m) & u64(0x7fffffff, 0xffffffff)) | (bits(s) & ((1 : I64) << 63)));

	// round to nearest, ties to even, for 0 <= x < 2^52
	static inline function roundeven(x:Float):Float
		return (x + 4503599627370496.0) - 4503599627370496.0;

	// ---- the tables, in memory on first use (as LibM's)

	static var tabs:Ptr;

	static inline var O_ASIN_CC = 0; // 33 * 8
	static inline var O_ACOS_CC = 264; // 33 * 8
	static inline var O_ASIN_OFF = 528; // 2 * 2
	static inline var O_SPI64 = 532; // 33 * 2
	static inline var O_CPOLY = 598; // 5 * 2
	static inline var O_ASIN_DB = 608; // 29 * 3
	static inline var O_ATAN_A = 695; // 129 * 2
	static inline var O_ATAN_DB = 953; // 12 * 3
	static inline var O_T2 = 989; // 65
	static inline var O_F2 = 1054; // 65 * 2
	static inline var O_O8 = 1184; // 8 * 2
	static inline var O_ATAN_C = 1200; // 31 * 3 (integers)
	static inline var O_P = 1293; // 30 tints
	static inline var O_Q = 1413; // 30 tints
	static inline var O_TZERO = 1533; // the tints ZERO, ONE, PI, PI/2
	static inline var O_TONE = 1537;
	static inline var O_TPI = 1541;
	static inline var O_TPI2 = 1545;
	static inline var NTAB = 1549;

	// tints: h, m, l (16 hex digits each), then ex << 1 | sgn (4)
	@:hxmc.noGc static function loadTints(t:Ptr, lit:String, at:Int):Void {
		var n = Std.int(Str.len(lit) / 52);
		for (i in 0...n) {
			var h:I64 = 0, m:I64 = 0, l:I64 = 0, es = 0;
			for (k in 0...16) {
				h = (h << 4) | LibM.hexDigit(Str.unit(lit, i * 52 + k));
				m = (m << 4) | LibM.hexDigit(Str.unit(lit, i * 52 + 16 + k));
				l = (l << 4) | LibM.hexDigit(Str.unit(lit, i * 52 + 32 + k));
			}
			for (k in 0...4)
				es = (es << 4) | LibM.hexDigit(Str.unit(lit, i * 52 + 48 + k));
			setT(t.add(8 * (at + 4 * i)), h, m, l, (es << 16) >> 17, es & 1);
		}
	}

	@:hxmc.noGc static function tab():Ptr {
		var t = tabs;
		if (!t.isNull()) return t;
		t = LibC.malloc(8 * NTAB);
		LibM.load(t, ASIN_CC, O_ASIN_CC, 16);
		LibM.load(t, ACOS_CC, O_ACOS_CC, 16);
		LibM.load(t, ASIN_OFF, O_ASIN_OFF, 16);
		LibM.load(t, SPI64, O_SPI64, 16);
		LibM.load(t, CPOLY, O_CPOLY, 16);
		LibM.load(t, ASIN_DB, O_ASIN_DB, 16);
		LibM.load(t, ATAN_A, O_ATAN_A, 16);
		LibM.load(t, ATAN_DB, O_ATAN_DB, 16);
		LibM.load(t, T2, O_T2, 16);
		LibM.load(t, F2, O_F2, 16);
		LibM.load(t, O8, O_O8, 16);
		LibM.load(t, ATAN_C, O_ATAN_C, 4);
		loadTints(t, P, O_P);
		loadTints(t, Q, O_Q);
		setT(t.add(8 * O_TZERO), 0, 0, 0, -1076, 0);
		setT(t.add(8 * O_TONE), (1 : I64) << 63, 0, 0, 1, 0);
		setT(t.add(8 * O_TPI), u64(0xc90fdaa2, 0x2168c234), u64(0xc4c6628b, 0x80dc1cd1), u64(0x29024e08, 0x8a67cc74), 2, 0);
		setT(t.add(8 * O_TPI2), u64(0xc90fdaa2, 0x2168c234), u64(0xc4c6628b, 0x80dc1cd1), u64(0x29024e08, 0x8a67cc74), 1, 0);
		Atomic.fence();
		tabs = t;
		return t;
	}

	static inline function td(t:Ptr, i:Int):Float
		return Mem.getF64(t, 8 * i);

	static inline function tw(t:Ptr, i:Int):I64
		return Mem.getI64(t, 8 * i);

	// ---- double-double helpers (the out parameters at o[0], o[1])

	// asin.c's and acos.c's polydd: c (n rows of h, l) at word offset `c`,
	// evaluated at xh + xl; *l in and out at o
	@:hxmc.noGc static function polydd(t:Ptr, xh:Float, xl:Float, n:Int, c:Int, o:Ptr):Float {
		var i = n - 1;
		var l = Mem.getF64(o, 0);
		var c0 = td(t, c + 2 * i);
		var ch = c0 + l; // fasttwosum (c[i][0], *l)
		var e = l - (ch - c0);
		var cl = td(t, c + 2 * i + 1) + e;
		while (--i >= 0) {
			// muldd (xh, xl, ch, cl)
			var ahhh = ch * xh;
			cl = (cl * xh + ch * xl) + fma(ch, xh, -ahhh);
			ch = ahhh;
			// fastsum (c[i][0], c[i][1], ch, cl)
			var a = td(t, c + 2 * i);
			var sh = a + ch;
			var sl = ch - (sh - a);
			cl = (td(t, c + 2 * i + 1) + cl) + sl;
			ch = sh;
		}
		Mem.setF64(o, 0, cl);
		return ch;
	}

	// ---- asin

	@:hxmc.host("Math_asin") @:hxmc.noGc static function asin(x:Float):Float {
		var ixu = bits(x);
		var ax = ixu << 1;
		if (!ult(ax, u64(0x7fe00000, 0))) { // |x| >= 1
			if (ax == u64(0x7fe00000, 0)) return x * 1.5707963267948966 + x * 6.123233995736766e-17; // |x| = 1
			if (ult(u64(0xffe00000, 0), ax)) return x + x; // nan
			return (x - x) / (x - x); // |x| > 1
		}
		// |x| < 0x1.7137449123ef6p-26: asin(x) rounds as x + x*2^-55
		if (ult(ax, u64(0x7cae26e8, 0x92247dec))) return fma(2.7755575615628914e-17, x, x);
		return LibM.useHw() ? asinCore(true, x, ixu, ax) : asinCore(false, x, ixu, ax);
	}

	// (hw: with the processor's fma; LibM.useHw)
	@:hxmc.noGc static inline function asinCore(hw:Bool, x:Float, ixu:I64, ax:I64):Float {
		var t:Float, z:Float, zl:Float, jd:Float, f0h:Float, f0l:Float, eps:Float;
		var tb = tab();
		if (ult(u64(0x7fc00000, 0), ax)) { // |x| > 0.5
			var k = (ixu >>> 63).toInt();
			f0h = td(tb, O_ASIN_OFF + 2 * k);
			f0l = td(tb, O_ASIN_OFF + 2 * k + 1);
			// asin(x) = pi/2 - 2*asin(sqrt((1-x)/2))
			t = 2 - 2 * Math.abs(x);
			jd = roundeven(t * 32.0);
			z = copysign(Math.sqrt(t), -x);
			zl = LibM.fm(hw, z, z, -t) * ((-0.5 / t) * z);
			t = 0.25 * t - jd * 0.0078125;
			eps = Math.abs(z * t) * 3.5475095083725705e-16;
		} else { // |x| <= 0.5
			f0h = 0;
			f0l = 0;
			t = x * x;
			jd = roundeven(t * 128.0);
			t = LibM.fm(hw, x, x, -0.0078125 * jd);
			z = x;
			zl = 0;
			eps = Math.abs(z * t) * 3.2526065174565133e-16;
		}
		// asin(z + zl) = (z + zl)*(cc[j][0] + (cc[j][1] + t*Poly(t, cc[j]+2)))
		var c = O_ASIN_CC + 8 * (cast jd : Int);
		var t2 = t * t;
		var d = t * ((td(tb, c + 2) + t * td(tb, c + 3)) + t2 * ((td(tb, c + 4) + t * td(tb, c + 5)) + t2 * (td(tb, c + 6) + t * td(tb, c + 7))));
		var fh = td(tb, c), fl = td(tb, c + 1) + d;
		// muldd (z, zl, fh, fl)
		var ahhh = fh * z;
		fl = (fl * z + fh * zl) + LibM.fm(hw, fh, z, -ahhh);
		fh = ahhh;
		// fastsum (f0h, f0l, fh, fl)
		var sh = f0h + fh;
		var sl = fh - (sh - f0h);
		fl = (f0l + fl) + sl;
		fh = sh;
		var lb = fh + (fl - eps), ub = fh + (fl + eps);
		if (lb != ub) return asinRefine(tb, x, lb);
		return lb;
	}

	// the common start of as_asin_refine and as_acos_refine: with x =
	// sin(phi), v + dv such that phi = pi/64*jf + asin(v + dv), from the
	// rotation by the table s; o[0] = dv
	@:hxmc.noGc static function rotate(tb:Ptr, x:Float, jf:Int, o:Ptr):Float {
		// ch + cl approximates sqrt(1-x^2)
		var s2 = x * x, dx2 = fma(x, x, -s2);
		var c2h = 1.0 + -s2; // fasttwosum (1.0, -s2)
		var c2l = -s2 - (c2h - 1.0);
		c2l -= dx2;
		var s = c2h + c2l; // fasttwosum (c2h, c2l)
		c2l = c2l - (s - c2h);
		c2h = s;
		var ch = Math.sqrt(c2h);
		var cl = (c2l - fma(ch, ch, -c2h)) * (0.5 / ch);
		// sin(pi/64*j) in the double-double format (smallest term first)
		var chT = td(tb, O_SPI64 + 2 * (32 - jf) + 1), clT = td(tb, O_SPI64 + 2 * (32 - jf));
		var shT = td(tb, O_SPI64 + 2 * jf + 1), slT = td(tb, O_SPI64 + 2 * jf);
		var ax = Math.abs(x);
		var dsh = ax - shT, dsl = -slT;
		var dch = ch - chT, dcl = cl - clT;
		var magic = 0.09375;
		var scT = fma(shT, dch, magic) - magic;
		var dSc = fma(shT, dch, -scT);
		var csT = fma(chT, dsh, magic) - magic;
		var dCs = fma(chT, dsh, -csT);
		var v = csT - scT;
		var dv = (chT * dsl + clT * dsh) - (shT * dcl + slT * dch) - (dSc - dCs);
		var w = v + dv; // fasttwosum (v, dv)
		dv = dv - (w - v);
		Mem.setF64(o, 0, dv);
		return w;
	}

	// asin(v + dv)/(v + dv) - 1 ... : fh + fl = (v + dv) * P(v^2), the
	// refinement polynomial of both (sgn: the sign v and dv take first)
	@:hxmc.noGc static function refinePoly(tb:Ptr, v:Float, dv:Float, sgn:Float, o:Ptr):Float {
		// v2 + dv2 = (v + dv)^2: muldd (v, dv, v, dv)
		var v2 = v * v;
		var dv2 = (dv * v + v * dv) + fma(v, v, -v2);
		v *= sgn;
		dv *= sgn;
		var fl = v2 * (0.022372159104814857 + v2 * (0.017352737142070387 + v2 * 0.013992707164303743));
		Mem.setF64(o, 0, fl);
		var fh = polydd(tb, v2, dv2, 5, O_CPOLY, o);
		fl = Mem.getF64(o, 0);
		// muldd (v, dv, fh, fl)
		var ahhh = fh * v;
		fl = (fl * v + fh * dv) + fma(fh, v, -ahhh);
		Mem.setF64(o, 0, fl);
		return ahhh;
	}

	@:hxmc.noGc static function asinRefine(tb:Ptr, x:Float, phi:Float):Float {
		var o = Mem.stack(8);
		var jf:Int = cast roundeven(Math.abs(phi) * 20.371832715762604);
		var v = rotate(tb, x, jf, o);
		var dv = Mem.getF64(o, 0);
		var sgn = copysign(1.0, x), jt = jf * sgn;
		var fh = refinePoly(tb, v, dv, sgn, o);
		var fl = Mem.getF64(o, 0);
		var ph = jt * 0.04908738521234035, pl = 1.684469643174416e-16 * jt, ps = -3.917809439666406e-31 * jt;
		// pl = fastsum (fh, fl, pl, ps, &ps)
		var sh = fh + pl;
		var sl = pl - (sh - fh);
		ps = (fl + ps) + sl;
		pl = sh;
		var s = ph + pl; // fasttwosum (ph, pl)
		pl = pl - (s - ph);
		ph = s;
		s = pl + ps; // fasttwosum (pl, ps)
		ps = ps - (s - pl);
		pl = s;
		s = ph + pl;
		pl = pl - (s - ph);
		ph = s;
		s = pl + ps;
		ps = ps - (s - pl);
		pl = s;
		var th = bits(ph), tl = bits(pl);
		var tn = (th & ((0x7ff : I64) << 52)) - ((53 : I64) << 52);
		tl = tl & u64(0x7fffffff, 0xffffffff);
		var dn = tl - tn, de = (tn - tl) >>> 52;
		var hard = (dn >= -2 && dn <= 0) || de > 47;
		var res = ph + pl;
		if (hard) res = asinDatabase(tb, x, res);
		return res;
	}

	@:hxmc.noGc static function asinDatabase(tb:Ptr, x:Float, f:Float):Float {
		// db: |x|, then the result as a sum, sorted by |x|
		var ax = Math.abs(x);
		var a = 0, b = 29;
		while (a + 1 < b) { // binary search with invariant db[a][0] <= x < db[b][0]
			var m = (a + b) >> 1;
			if (td(tb, O_ASIN_DB + 3 * m) <= ax) a = m; else b = m;
		}
		if (td(tb, O_ASIN_DB + 3 * a) == ax) {
			var h = td(tb, O_ASIN_DB + 3 * a + 1), l = td(tb, O_ASIN_DB + 3 * a + 2);
			return x > 0 ? h + l : -h - l;
		}
		return f;
	}

	// ---- acos

	@:hxmc.host("Math_acos") @:hxmc.noGc static function acos(x:Float):Float {
		var ixu = bits(x);
		var ax = ixu << 1;
		if (!ult(ax, u64(0x7fe00000, 0))) { // |x| >= 1
			if (ax == u64(0x7fe00000, 0)) return x > 0 ? 0.0 : 3.141592653589793 + 1.2246467991473532e-16; // |x| = 1
			if (ult(u64(0xffe00000, 0), ax)) return x + x; // nan
			return (x - x) / (x - x); // |x| > 1
		}
		// |x| <= 2^-31: acos(x) ~ pi/2 - x - x^3/6
		if (!ult(u64(0x7e000000, 0), ax)) {
			var f0h = 1.5707963267948966, f0l = 6.123233995736766e-17;
			var v = !ult(u64(0x79196767, 0x0d2e8fe8), ax) ? 0.0 : (x * x) * (-0.16666666666666666 * x);
			var h = f0h + -x; // fasttwosum (f0h, -x)
			var w = -x - (h - f0h);
			var l = v + (w + f0l);
			var lb = h + (l - 1.990403348955723e-24), ub = h + (l + 1.990403348955723e-24);
			if (lb != ub) return acosRefine(tab(), x, lb);
			return lb;
		}
		return LibM.useHw() ? acosCore(true, x, ixu, ax) : acosCore(false, x, ixu, ax);
	}

	@:hxmc.noGc static inline function acosCore(hw:Bool, x:Float, ixu:I64, ax:I64):Float {
		var t:Float, z:Float, zl:Float, jd:Float, f0h:Float, f0l:Float, eps:Float;
		var tb = tab();
		if (ult(u64(0x7fc00000, 0), ax)) { // |x| > 0.5
			var neg = nz(ixu >>> 63);
			f0h = neg ? 3.141592653589793 : 0.0;
			f0l = neg ? 1.2246467991473532e-16 : 0.0;
			t = 2 - 2 * Math.abs(x);
			jd = roundeven(t * 32.0);
			z = copysign(Math.sqrt(t), x);
			zl = LibM.fm(hw, z, z, -t) * ((-0.5 / t) * z);
			t = 0.25 * t - jd * 0.0078125;
			eps = Math.abs(z * t) * 3.434752482434078e-16 + 2.465190328815662e-32;
		} else {
			f0h = 1.5707963267948966;
			f0l = 6.123233995736766e-17;
			t = x * x;
			jd = roundeven(t * 128.0);
			t = LibM.fm(hw, x, x, -0.0078125 * jd);
			z = -x;
			zl = 0;
			eps = (z * t) * 3.3393426912553537e-16;
		}
		var c = O_ACOS_CC + 8 * (cast jd : Int);
		var t2 = t * t;
		var d = t * ((td(tb, c + 2) + t * td(tb, c + 3)) + t2 * ((td(tb, c + 4) + t * td(tb, c + 5)) + t2 * (td(tb, c + 6) + t * td(tb, c + 7))));
		var fh = td(tb, c), fl = td(tb, c + 1) + d;
		// muldd (z, zl, fh, fl)
		var ahhh = z * fh;
		fl = (z * fl + zl * fh) + LibM.fm(hw, z, fh, -ahhh);
		fh = ahhh;
		// fastsum (f0h, f0l, fh, fl)
		var sh = f0h + fh;
		var sl = fh - (sh - f0h);
		fl = (f0l + fl) + sl;
		fh = sh;
		var lb = fh + (fl - eps), ub = fh + (fl + eps);
		if (lb != ub) return acosRefine(tb, x, lb);
		return lb;
	}

	@:hxmc.noGc static function acosRefine(tb:Ptr, x:Float, phi:Float):Float {
		var o = Mem.stack(8);
		var jf:Int = cast roundeven(Math.abs(phi - 1.5707963267948966) * 20.371832715762604);
		var v = rotate(tb, x, jf, o);
		var dv = Mem.getF64(o, 0);
		var sgn = copysign(1.0, x), jt = 32 - jf * sgn;
		var fh = refinePoly(tb, v, dv, -sgn, o);
		var fl = Mem.getF64(o, 0);
		var ph = jt * 0.04908738521234035, pl = 1.684469643174416e-16 * jt, ps = -3.917809439666406e-31 * jt;
		// pl = sum (fh, fl, pl, ps, &ps): with twosum
		var s = fh + pl;
		var ap = s - pl;
		var bp = s - ap;
		var sl = (fh - ap) + (pl - bp);
		ps = (fl + ps) + sl;
		pl = s;
		s = ph + pl; // fasttwosum (ph, pl)
		pl = pl - (s - ph);
		ph = s;
		s = pl + ps; // fasttwosum (pl, ps)
		ps = ps - (s - pl);
		pl = s;
		s = ph + pl;
		pl = pl - (s - ph);
		ph = s;
		s = pl + ps;
		ps = ps - (s - pl);
		pl = s;
		var tu = bits(pl);
		var e = ((tu >>> 52) & 0x7ff).toInt() - 1023;
		e = 52 - (107 + e);
		if (e < 0) e = 0;
		if (e > 52) e = 52;
		var m = ((1 : I64) << 52) - ((1 : I64) << e);
		if (e == 0) e = 64;
		if (!nz((tu + ((1 : I64) << (e - 1))) & m)) {
			// the hard cases that need it
			if (x == 0.999999999999936) return 3.5762786865234566e-07 + 1.3234889800848443e-23;
			if (x == 0.08298723566019295) return 1.4877135408445967 + 5.551115123125783e-17;
			if (x == 0.0009717008771394217) return 1.5698246257648432 + 1.6653345369377348e-16;
			if (x == 0.999999999999984) return 1.788139343261721e-07 + 6.617444900424222e-24;
			if (x == 0.038214879531014476) return 1.5325721397906955 - 1.5407439555097887e-33;
			var w = bits(ps);
			if (nz((w ^ tu) >>> 63)) tu = tu - 1; else tu = tu + 1;
			pl = ofBits(tu);
		}
		return ph + pl;
	}

	// ---- atan

	// muldd_acc (xh, xl, ch, cl): the high part, the low one at o
	static inline function mulddAcc(xh:Float, xl:Float, ch:Float, cl:Float, o:Ptr):Float {
		var ahlh = ch * xl, alhh = cl * xh, ahhh = ch * xh, ahhl = fma(ch, xh, -ahhh);
		ahhl += alhh + ahlh;
		var s = ahhh + ahhl; // fasttwosum (ahhh, ahhl)
		Mem.setF64(o, 0, ahhl - (s - ahhh));
		return s;
	}

	// adddd (xh, xl, ch, cl): the high part, the low one at o
	static inline function adddd(xh:Float, xl:Float, ch:Float, cl:Float, o:Ptr):Float {
		var s = xh + ch, d = s - xh;
		Mem.setF64(o, 0, ((ch - d) + (xh + (d - s))) + (xl + cl));
		return s;
	}

	@:hxmc.host("Math_atan") @:hxmc.noGc static function atan(x:Float):Float {
		var tu = bits(x);
		var at = tu & u64(0x7fffffff, 0xffffffff); // |x|
		if (ult(at, u64(0x3f7b21c4, 0x75e6362a))) { // |x| < 0x1.b21c475e6362ap-8
			if (at == 0) return x; // atan(+/-0) = +/-0
			if (ult(at, u64(0x3e400000, 0))) return fma(-5.551115123125783e-17, x, x); // |x| < 0x1p-27
			var x2 = x * x, x3 = x * x2, x4 = x2 * x2;
			var f = x3 * ((-0.3333333333333333 + x2 * 0.199999999999994) + x4 * (-0.1428571424743179 + x2 * 0.11110113960028833));
			var epsp = f * 1.2212453270876722e-15, epsm = f * 6.106226635438361e-16;
			var ub = (f + epsp) + x, lb = (f - epsm) + x;
			if (ub == lb) return ub;
			return atanRefine(tab(), x, ub);
		}
		if (!ult(at, u64(0x434d0296, 0x7c31cdb5))) { // |x| >= 0x1.d02967c31cdb5p+53
			if (ult((0x7ff : I64) << 52, at)) return x + x; // NaN
			return copysign(1.5707963267948966, x) + copysign(6.123233995736766e-17, x);
		}
		return LibM.useHw() ? atanCore(true, x, tu, at) : atanCore(false, x, tu, at);
	}

	@:hxmc.noGc static inline function atanCore(hw:Bool, x:Float, tu:I64, at:I64):Float {
		var h:Float, ah:Float, al:Float;
		var tb = tab();
		if (ult(u64(0x4062ded8, 0xe34a9035), at)) { // |x| > 0x1.2ded8e34a9035p+7
			ah = copysign(1.5707963267948966, x);
			al = copysign(6.123233995736766e-17, x);
			h = -1.0 / x;
		} else {
			// 0x1.b21c475e6362ap-8 <= |x| <= 0x1.2ded8e34a9035p+7, 1 <= i <= 30
			var i = ((at >>> 51) - 2030).toInt();
			var u = tu & ((-1 : I64) >>> 13);
			var ut = u >>> (51 - 16), ut2 = (ut * ut) >>> 16;
			var c = O_ATAN_C + 3 * i;
			i = (((tw(tb, c) << 16) + ut * tw(tb, c + 1) - ut2 * tw(tb, c + 2)) >>> (16 + 9)).toInt();
			var sg = copysign(1.0, x);
			var ta = sg * td(tb, O_ATAN_A + 2 * i), id = sg * i;
			al = sg * td(tb, O_ATAN_A + 2 * i + 1) + 4.2111741079360304e-17 * id;
			h = (x - ta) / (1 + x * ta);
			ah = 0.012271846303085088 * id;
		}
		var h2 = h * h, h4 = h2 * h2;
		var f = (1.0 + h2 * -0.333333333333331) + h4 * (0.1999999997326265 + h2 * -0.1428473928322857);
		al = LibM.fm(hw, h, f, al);
		var e = h * 8.743006318923108e-16;
		var ub = (al + e) + ah, lb = (al - e) + ah;
		if (ub == lb) return ub;
		return atanRefine(tb, x, ub);
	}

	// as_atan_refine2: for 0x1p-27 <= |x|, a: the fast path's approximation
	@:hxmc.noGc static function atanRefine(tb:Ptr, x:Float, a:Float):Float {
		var o = Mem.stack(8);
		var phi = bits(Math.abs(a) * 81.48733086305042 + 256.5);
		var i = ((phi >>> (52 - 8)) & 0xff).toInt(); // 0 <= i <= 128
		var h:Float, hl:Float;
		if (i == 128) {
			h = -1.0 / x;
			hl = fma(h, x, 1) * h;
		} else {
			var ta = copysign(td(tb, O_ATAN_A + 2 * i), x);
			var zta = x * ta, ztal = fma(x, ta, -zta), zmta = x - ta;
			var v = 1 + zta, d = 1 - v, ev = (d + zta) - ((d + v) - 1) + ztal;
			var r = 1.0 / v, rl = (fma(r, -v, 1.0) - ev * r) * r;
			h = r * zmta;
			hl = fma(r, zmta, -h) + rl * zmta;
		}
		var h2 = mulddAcc(h, hl, h, hl, o), h2l = Mem.getF64(o, 0), h4 = h2 * h2;
		var h3 = mulddAcc(h, hl, h2, h2l, o), h3l = Mem.getF64(o, 0);
		var fl = h2 * ((0.1111111111111111 + h2 * -0.09090909090907358) + h4 * (0.07692307637971313 + h2 * -0.06665779689246536));
		// f = polydd (h2, h2l, 3, ch, &fl), atan.c's
		var ch = -0.14285714285714285 + fl;
		var cl = ((-0.14285714285714285 - ch) + fl) + -7.930161522310759e-18;
		ch = mulddAcc(h2, h2l, ch, cl, o);
		cl = Mem.getF64(o, 0);
		var th = ch + 0.2, tl = (0.2 - th) + ch;
		ch = th;
		cl += tl + -1.1102230246265417e-17;
		ch = mulddAcc(h2, h2l, ch, cl, o);
		cl = Mem.getF64(o, 0);
		th = ch + -0.3333333333333333;
		tl = (-0.3333333333333333 - th) + ch;
		ch = th;
		cl += tl + -1.850371707708594e-17;
		var f = mulddAcc(h3, h3l, ch, cl, o);
		fl = Mem.getF64(o, 0);
		var ah:Float, al:Float, at:Float;
		if (i == 0) {
			ah = h;
			al = f;
			at = fl;
		} else {
			var df = 0.0;
			if (i < 128) df = copysign(1.0, x) * td(tb, O_ATAN_A + 2 * i + 1);
			var id = copysign(i, x);
			ah = 0.012271846303085088 * id;
			al = 4.21117410793604e-17 * id;
			at = -9.794523599166037e-32 * id;
			al = adddd(al, at, df, 0, o);
			at = Mem.getF64(o, 0);
			al = adddd(al, at, h, hl, o);
			at = Mem.getF64(o, 0);
			al = adddd(al, at, f, fl, o);
			at = Mem.getF64(o, 0);
		}
		var v0 = ah + al; // fasttwosum (ah, al, &v2)
		var v2 = al - (v0 - ah);
		var v1 = v2 + at; // fasttwosum (v2, at, &v2)
		v2 = at - (v1 - v2);
		var ax = Math.abs(x);
		var t0 = bits(v0), t1 = bits(v1);
		var mant = (-1 : I64) >>> 12;
		if (!ult(2, (t1 + 1) & mant) || ult(103, ((t0 >>> 52) & 0x7ff) - ((t1 >>> 52) & 0x7ff))) {
			for (j in 0...12)
				if (ax == td(tb, O_ATAN_DB + 3 * j))
					return copysign(td(tb, O_ATAN_DB + 3 * j + 1), x) + copysign(1.0, x) * td(tb, O_ATAN_DB + 3 * j + 2);
			if (!nz(t1 & mant)) {
				var w = bits(v2);
				if (nz((w ^ t1) >>> 63)) t1 = t1 - 1; else t1 = t1 + 1;
				v1 = ofBits(t1);
			}
		}
		return v1 + v0;
	}

	// ---- atan2

	static inline var PI_H = 3.141592653589793;
	static inline var PI_L = 1.2246467991473532e-16;
	static inline var PI_OVER2_H = 1.5707963267948966;
	static inline var PI_OVER2_L = 6.123233995736766e-17;

	@:hxmc.noGc static function atan2Special(y0:Float, x0:Float):Float {
		var iy = bits(y0), ix = bits(x0);
		var aiy = iy << 1, aix = ix << 1;
		var inf2 = (0x7ff : I64) << 53;
		if (!ult(aiy, inf2) || !ult(aix, inf2)) {
			if (ult(inf2, aiy) || ult(inf2, aix)) return y0 + x0;
			if (aiy == inf2 && aix == inf2) {
				if (nz(ix >>> 63)) return copysign(2.356194490192345, y0) + copysign(5.551115123125783e-17, y0);
				return copysign(0.7853981633974483, y0) + copysign(2.7755575615628914e-17, y0);
			}
			if (aix == inf2) {
				if (x0 < 0) return copysign(PI_H, y0) + copysign(PI_L, y0);
				return copysign(0, y0);
			}
			return copysign(PI_OVER2_H, y0) + copysign(PI_OVER2_L, y0);
		}
		if (aiy == 0 || aix == 0) {
			if (aiy == 0 && aix == 0) {
				if (ix == 0) return y0;
				return iy == 0 ? PI_H + PI_L : -PI_H - PI_L;
			}
			if (aiy == 0) {
				if (x0 > 0) return y0 / x0;
				return !nz(iy >>> 63) ? PI_H + PI_L : -PI_H - PI_L;
			}
			return y0 > 0 ? PI_OVER2_H + PI_OVER2_L : -PI_OVER2_H - PI_OVER2_L;
		}
		return 0;
	}

	@:hxmc.host("Math_atan2") @:hxmc.noGc static function atan2(y0:Float, x0:Float):Float {
		var iy = bits(y0), ix = bits(x0);
		var mask = u64(0x7fffffff, 0xffffffff), infb = (0x7ff : I64) << 52;
		var aiy = iy & mask;
		if (aiy == 0 || !ult(aiy, infb)) return atan2Special(y0, x0);
		var aix = ix & mask;
		if (aix == 0 || !ult(aix, infb)) return atan2Special(y0, x0);
		var ax = Math.abs(x0), ay = Math.abs(y0);
		var x = ax > ay ? ax : ay, y = ax > ay ? ay : ax;
		var sy = (iy >>> 63).toInt(), sx = (ix >>> 63).toInt();
		var gt = ult(aix, aiy) ? 1 : 0;
		var dxy = (aix - aiy) ^ -(gt : I64);
		if (!ult(dxy, (53 : I64) << 52)) return atan2Accurate(y0, x0);
		var r = LibM.useHw() ? atan2Core(true, y0, x0, iy, ix, aiy, aix) : atan2Core(false, y0, x0, iy, ix, aiy, aix);
		// (NaN: the fast paths cannot decide)
		return r == r ? r : atan2Accurate(y0, x0);
	}

	@:hxmc.noGc static inline function atan2Core(hw:Bool, y0:Float, x0:Float, iy:I64, ix:I64, aiy:I64, aix:I64):Float {
		var ax = Math.abs(x0), ay = Math.abs(y0);
		var x = ax > ay ? ax : ay, y = ax > ay ? ay : ax;
		var sy = (iy >>> 63).toInt(), sx = (ix >>> 63).toInt();
		var gt = ult(aix, aiy) ? 1 : 0;
		var tb = tab();
		var s1 = ((gt ^ sx ^ sy) != 0) ? -1.0 : 1.0;
		var kw = sx << 2 | sy << 1 | gt;
		var jj = bits(y / x + (2 + 1 / 128.0));
		var jt = ((jj >>> (52 - 7)) & 127).toInt();
		var fh = td(tb, O_F2 + 2 * jt + 1) * s1;
		var fl = td(tb, O_F2 + 2 * jt) * s1;
		fh += td(tb, O_O8 + 2 * kw);
		fl += td(tb, O_O8 + 2 * kw + 1);
		if (x < 1.1282464849155185e-277) {
			x *= 8.863311460481781e+276;
			y *= 8.863311460481781e+276;
		}
		if (x > 4.49423283715579e+307 && jt != 0) {
			x *= 0.5;
			y *= 0.5;
		}
		var t0 = td(tb, O_T2 + jt);
		var zn = LibM.fm(hw, -t0, x, y), zd = LibM.fm(hw, t0, y, x);
		var z = zn / zd;
		var z2 = z * z;
		z *= s1;
		var dz = (z * z2) * (-0.33333333333332604 + z2 * (0.19999999943116925 + z2 * -0.14284292170535642));
		var eps = Math.abs(z) * 4.528712474471952e-16 + 8.077935669463161e-28;
		var rh = fh + z; // fasttwosum (fh, z, &z)
		z = z - (rh - fh);
		var rl = (fl + dz) + z;
		var lb = rh + (rl - eps), ub = rh + (rl + eps);
		if (lb != ub) {
			var dh = y * t0, dl = LibM.fm(hw, y, t0, -dh);
			var s = x + dh; // fasttwosum (x, dh, &e)
			var e = dh - (s - x);
			dh = s;
			var rdh = 1 / dh;
			dl += e;
			var nh = x * t0, nl = LibM.fm(hw, x, t0, -nh);
			var dt = y - nh, y1 = dt + nh;
			var b = y1 == y ? -nl : (y - y1) - nl;
			nh = dt + b; // fasttwosum (dt, b, &nl)
			nl = b - (nh - dt);
			var zh = nh * rdh;
			z2 = zh * zh;
			var zl = rdh * (LibM.fm(hw, dh, -zh, nh) + (nl - (nh * rdh) * dl));
			zl += zh * z2 * ((-0.3333333333333333 + z2 * 0.19999999999974255) + (z2 * z2) * (-0.14285713816496304 + z2 * 0.11107620301764512));
			zh *= s1;
			zl *= s1;
			eps = 1.1102230246251565e-15 * (Math.abs(zh) * z2 + 4.440892098500626e-16);
			// fh = fastsum (fh, fl, zh, zl, &fl)
			var sh = fh + zh;
			var sl = zh - (sh - fh);
			fl = (fl + zl) + sl;
			fh = sh;
			lb = fh + (fl - eps);
			ub = fh + (fl + eps);
			if (lb != ub) ub = Math.NaN;
		}
		return ub;
	}

	// ---- tint_t: 192-bit significands (atan2/tint.h)

	static inline function tH(p:Ptr):I64
		return Mem.getI64(p, 0);

	static inline function tM(p:Ptr):I64
		return Mem.getI64(p, 8);

	static inline function tL(p:Ptr):I64
		return Mem.getI64(p, 16);

	static inline function tEx(p:Ptr):Int
		return Mem.getI32(p, 24);

	static inline function tSgn(p:Ptr):Int
		return Mem.getI32(p, 28);

	static inline function setT(p:Ptr, h:I64, m:I64, l:I64, ex:Int, sgn:Int):Void {
		Mem.setI64(p, 0, h);
		Mem.setI64(p, 8, m);
		Mem.setI64(p, 16, l);
		Mem.setI32(p, 24, ex);
		Mem.setI32(p, 28, sgn);
	}

	static inline function setLimbs(p:Ptr, h:I64, m:I64, l:I64):Void {
		Mem.setI64(p, 0, h);
		Mem.setI64(p, 8, m);
		Mem.setI64(p, 16, l);
	}

	static inline function cpT(r:Ptr, a:Ptr):Void
		setT(r, tH(a), tM(a), tL(a), tEx(a), tSgn(a));

	// r = a * b (r may be a or b)
	@:hxmc.noGc static function mulT(r:Ptr, a:Ptr, b:Ptr):Void {
		var ah = tH(a), am = tM(a), al = tL(a);
		var bh = tH(b), bm = tM(b), bl = tL(b);
		var ex = tEx(a) + tEx(b), sgn = tSgn(a) ^ tSgn(b);
		var rh = mulhi(ah, bh), rm = ah * bh;
		var rl = ah * bm;
		var h = mulhi(ah, bm);
		rm += h;
		rh += ult(rm, h) ? 1 : 0;
		var l = am * bh;
		h = mulhi(am, bh);
		rl += l;
		var cm:I64 = ult(rl, l) ? 1 : 0;
		rm += h;
		rh += ult(rm, h) ? 1 : 0;
		// the high halves of ah*bl, am*bm and al*bh, a 66-bit sum
		var s1 = mulhi(ah, bl), s2 = mulhi(am, bm), s3 = mulhi(al, bh);
		var s = s1 + s2;
		var carry:I64 = ult(s, s1) ? 1 : 0;
		var s4 = s + s3;
		carry += ult(s4, s) ? 1 : 0;
		cm += carry;
		rl += s4;
		cm += ult(rl, s4) ? 1 : 0;
		rm += cm;
		rh += ult(rm, cm) ? 1 : 0;
		if (!nz(rh >>> 63)) {
			rh = (rh << 1) | (rm >>> 63);
			rm = (rm << 1) | (rl >>> 63);
			rl = rl << 1;
			ex--;
		}
		setT(r, rh, rm, rl, ex, sgn);
	}

	@:hxmc.noGc static function cmpTAbs(a:Ptr, b:Ptr):Int {
		if (tH(a) == 0) return tH(b) == 0 ? 0 : -1;
		if (tH(b) == 0) return 1;
		var ea = tEx(a), eb = tEx(b);
		if (ea != eb) return ea > eb ? 1 : -1;
		var x = tH(a), y = tH(b);
		if (!(x == y)) return ult(x, y) ? -1 : 1;
		x = tM(a);
		y = tM(b);
		if (!(x == y)) return ult(x, y) ? -1 : 1;
		x = tL(a);
		y = tL(b);
		if (!(x == y)) return ult(x, y) ? -1 : 1;
		return 0;
	}

	// the limbs of r = the limbs h, m, l shifted right by k >= 0 (truncated)
	@:hxmc.noGc static function shrT(r:Ptr, h:I64, m:I64, l:I64, k:Int):Void {
		if (k == 0) setLimbs(r, h, m, l);
		else if (k < 64) setLimbs(r, h >>> k, (m >>> k) | (h << (64 - k)), (l >>> k) | (m << (64 - k)));
		else if (k == 64) setLimbs(r, 0, h, m);
		else if (k < 128) setLimbs(r, 0, h >>> (k - 64), (m >>> (k - 64)) | (h << (128 - k)));
		else if (k < 192) setLimbs(r, 0, 0, h >>> (k - 128));
		else setLimbs(r, 0, 0, 0);
	}

	// the limbs of r = the limbs h, m, l shifted left by k >= 0
	@:hxmc.noGc static function shlT(r:Ptr, h:I64, m:I64, l:I64, k:Int):Void {
		if (k == 0) setLimbs(r, h, m, l);
		else if (k < 64) setLimbs(r, (h << k) | (m >>> (64 - k)), (m << k) | (l >>> (64 - k)), l << k);
		else if (k == 64) setLimbs(r, m, l, 0);
		else if (k < 128) setLimbs(r, (m << (k - 64)) | (l >>> (128 - k)), l << (k - 64), 0);
		else if (k < 192) setLimbs(r, l << (k - 128), 0, 0);
		else setLimbs(r, 0, 0, 0);
	}

	static inline function clz192(h:I64, m:I64, l:I64):Int
		return nz(h) ? clz(h) : nz(m) ? 64 + clz(m) : 128 + clz(l);

	// r = a + b (r may be a or b)
	@:hxmc.noGc static function addT(tb:Ptr, r:Ptr, a:Ptr, b:Ptr):Void {
		switch cmpTAbs(a, b) {
			case 0:
				if ((tSgn(a) ^ tSgn(b)) != 0) {
					cpT(r, tb.add(8 * O_TZERO));
					return;
				}
				cpT(r, a);
				Mem.setI32(r, 24, tEx(r) + 1);
				return;
			case -1:
				var tmp = a;
				a = b;
				b = tmp;
			case _:
		}
		var w = Mem.stack(32);
		var sh = tEx(a) - tEx(b);
		var ah = tH(a), am = tM(a), al = tL(a);
		var aex = tEx(a), sgn = tSgn(a);
		shrT(w, tH(b), tM(b), tL(b), sh);
		var th = tH(w), tm = tM(w), tl = tL(w);
		if ((tSgn(a) ^ tSgn(b)) != 0) {
			// t = a - t
			var nl = al - tl;
			var bw = ult(al, nl) ? 1 : 0;
			var nm = am - tm - bw;
			var bw2 = ult(am, tm) || (am == tm && bw == 1) ? 1 : 0;
			var nh = ah - th - bw2;
			var ex = clz192(nh, nm, nl);
			if (ex <= 1 || sh == 0) {
				shlT(r, nh, nm, nl, ex);
				Mem.setI32(r, 24, aex - ex);
			} else {
				shlT(w, tH(b), tM(b), tL(b), ex - sh);
				var bh2 = tH(w), bm2 = tM(w), bl2 = tL(w);
				shlT(w, ah, am, al, ex);
				var xh = tH(w), xm = tM(w), xl = tL(w);
				nl = xl - bl2;
				bw = ult(xl, nl) ? 1 : 0;
				nm = xm - bm2 - bw;
				bw2 = ult(xm, bm2) || (xm == bm2 && bw == 1) ? 1 : 0;
				nh = xh - bh2 - bw2;
				var ex1 = clz192(nh, nm, nl);
				shlT(r, nh, nm, nl, ex1);
				Mem.setI32(r, 24, aex - (ex + ex1));
			}
		} else {
			var nl = al + tl;
			var cl:I64 = ult(nl, al) ? 1 : 0;
			// the high 128 bits: (ah:am) + (th:tm) + cl
			var nm = am + tm;
			var cmid:I64 = ult(nm, am) ? 1 : 0;
			var nh = ah + th + cmid;
			var ch:I64 = ult(nh, ah) || (nh == ah && cmid == 1) ? 1 : 0;
			var nm2 = nm + cl;
			var c2:I64 = ult(nm2, cl) ? 1 : 0;
			var nh2 = nh + c2;
			ch += ult(nh2, c2) ? 1 : 0;
			nm = nm2;
			nh = nh2;
			if (nz(ch)) {
				nl = (nm << 63) | (nl >>> 1);
				nm = (nh << 63) | (nm >>> 1);
				nh = (ch << 63) | (nh >>> 1);
				Mem.setI32(r, 24, aex + 1);
			} else
				Mem.setI32(r, 24, aex);
			setLimbs(r, nh, nm, nl);
		}
		Mem.setI32(r, 28, sgn);
	}

	@:hxmc.noGc static function fromdT(a:Ptr, x:Float):Void {
		var u = bits(x);
		var sgn = (u >>> 63).toInt();
		var ax = u & u64(0x7fffffff, 0xffffffff);
		var e = (ax >>> 52).toInt();
		if (e != 0)
			setT(a, ((1 : I64) << 63) | (ax << 11), 0, 0, e - 0x3fe, sgn);
		else {
			e = clz(ax);
			setT(a, ax << e, 0, 0, -0x3f2 - e, sgn);
		}
	}

	// a rounded to a double (err: the error bound, in ulps of a.l)
	@:hxmc.noGc static function todT(a:Ptr, err:Int):Float {
		var sgn = tSgn(a), ex = tEx(a);
		if (ex >= 1025) return sgn != 0 ? -8.98846567431158e+307 - 8.98846567431158e+307 : 8.98846567431158e+307 + 8.98846567431158e+307;
		if (ex <= -1074) {
			if (ex < -1074) return (sgn != 0 ? -5e-324 : 5e-324) * 0.5;
			var mid = tH(a) == ((1 : I64) << 63) && tM(a) == 0 && tL(a) == 0;
			return (sgn != 0 ? -5e-324 : 5e-324) * (mid ? 0.5 : 0.75);
		}
		var hh = tH(a), mm = tM(a), ll = tL(a);
		var low = (hh & 0x7ff).toInt();
		if (ex <= -1022) {
			var sh = -1021 - ex;
			ll = (mm << (64 - sh)) | (ll >>> sh) | (nz(ll) ? 1 : 0);
			mm = (hh << (64 - sh)) | (mm >>> sh);
			hh = hh >>> sh;
			low = (hh & 0x7ff).toInt();
			ex += sh;
		}
		var h:Float = cast(hh >>> 11), l:Float;
		if (err == 0) l = 0;
		else if (low < 0x400) l = 0.25;
		else if (low > 0x400) l = 0.75;
		else l = !nz(mm) && !nz(ll) ? 0.5 : 0.75;
		var s = sgn != 0 ? -1.0 : 1.0;
		h = fma(l, s, s * h);
		h *= 2.220446049250313e-16;
		return h * ofBits(((0x3ff + ex - 1) : I64) << 52);
	}

	@:hxmc.noGc static function invT(tb:Ptr, r:Ptr, da:Ptr):Void {
		var q = Mem.stack(32);
		var a = todT(da, 0);
		var subnormal = Math.abs(a) < 2.2250738585072014e-308;
		if (subnormal) a *= 9007199254740992.0;
		fromdT(r, 1.0 / a);
		if (subnormal) Mem.setI32(r, 24, tEx(r) + 53);
		mulT(q, da, r);
		Mem.setI32(q, 28, 1 - tSgn(q));
		addT(tb, q, tb.add(8 * O_TONE), q);
		mulT(q, r, q);
		addT(tb, r, r, q);
	}

	// r = b / a (r not a or b)
	@:hxmc.noGc static function divT(tb:Ptr, r:Ptr, b:Ptr, a:Ptr):Void {
		var w = Mem.stack(64);
		var dy = w, dz = w.add(32);
		invT(tb, dy, a);
		mulT(r, dy, b);
		mulT(dz, a, r);
		Mem.setI32(dz, 28, 1 - tSgn(dz));
		addT(tb, dz, b, dz);
		mulT(dz, dy, dz);
		addT(tb, r, r, dz);
	}

	@:hxmc.noGc static function atan2Accurate(y:Float, x:Float):Float {
		var t = y / x;
		if (t == 0) {
			if (x > 0) return t;
			return y > 0 ? PI_H + PI_L : -PI_H - PI_L;
		}
		var corr = fma(t, x, -y);
		if (corr == 0 && x > 0)
			if (Math.abs(t) <= 1.3538603431225864e-08) {
				if (Math.abs(y) >= 3.610388751729659e-276) return fma(t, -5.551115123125783e-17, t);
				corr = fma(t * 4.056481920730334e+31, x, -y * 4.056481920730334e+31);
				if (corr == 0) return fma(t, -5.551115123125783e-17, t);
			}
		var tb = tab();
		var w = Mem.stack(160);
		var z = w, p = w.add(32), q = w.add(64), da = w.add(96), db = w.add(128);
		var inv = Math.abs(y) > Math.abs(x);
		// div_tint_d
		if (inv) {
			fromdT(da, y);
			fromdT(db, x);
		} else {
			fromdT(da, x);
			fromdT(db, y);
		}
		divT(tb, z, db, da);
		if (!inv && x > 0 && tEx(z) <= -96) {
			// atan(y/x) rounds as y/x perturbed by a small amount towards zero
			var zl = tL(z) - 2, zm = tM(z), zh = tH(z);
			if (ult(zl, 2)) zm = zm - 1;
			if (zm == 0) zh = zh - 1;
			setLimbs(z, zh, zm, zl);
			return todT(z, 1);
		}
		var sz = tSgn(z);
		Mem.setI32(z, 28, 0);
		cpT(p, tb.add(8 * (O_P + 4 * 29)));
		cpT(q, tb.add(8 * (O_Q + 4 * 29)));
		var i = 28;
		while (i >= 0) {
			mulT(p, p, z);
			mulT(q, q, z);
			addT(tb, p, p, tb.add(8 * (O_P + 4 * i)));
			addT(tb, q, q, tb.add(8 * (O_Q + 4 * i)));
			i--;
		}
		mulT(p, p, z);
		divT(tb, z, p, q);
		var err = 662;
		Mem.setI32(z, 28, sz);
		if (inv) {
			if (tSgn(z) == 0) {
				Mem.setI32(z, 28, 1);
				addT(tb, z, tb.add(8 * O_TPI2), z);
			} else {
				addT(tb, z, tb.add(8 * O_TPI2), z);
				Mem.setI32(z, 28, 1);
			}
			err = 524;
		}
		if (x < 0) {
			if (tSgn(z) == 0) {
				Mem.setI32(z, 28, 1);
				addT(tb, z, tb.add(8 * O_TPI), z);
				Mem.setI32(z, 28, 1);
			} else
				addT(tb, z, tb.add(8 * O_TPI), z);
			err = 266;
		}
		return todT(z, err);
	}

	// ---- the tables (asin.c, acos.c, atan.c, atan2.c)

	// 30 tints
	static inline var P = "82703f8b53112eca71ce6279d467aa45019c9b28466b6fc0ffecb3cf74b427d53e03ee590b839e751890f2570b12bcb2381afff0b08498b17b88c39a11e37821d784d8fa2795b14b84b9d78cfff4fd4baa7bb52b0d83b25425beb0a04dc392008d9fb34b68fffff696541948b85fb386e0b815ace425a859beca17c69bb4f7a0fffa96aaa5d4baffc590f23db783b6e4ce552c54e054d3b69f7efffc83cd41b5fa862b11ad8f9d6e3eb9d8334ef470d801fa03cafffecbbc7752197cc106bc66cfb3edefa6e3568b2f9e4feb8910fffe8cf8f7c585767042cd92a5b9ac13d8c8043bd4a023dbe04d0000afdc36d6b36139bf11df63474e3859d442b30b2c089a2b6c0000c6f8fb14638225192f9f04cf55c103771c44675c6d4836060000cce79f10f754e31591ce47edcbc8a4eeb2a6f721ac656b420000c090384dbd77132e1dfb4d9a1d595de7e506ca899a394f700000a556ac9eee25e867d84dafa25141d203f1c7c2a5156b3ec3000081bd2677ddfcbc381df33f27dbb60939cb4c2c73286a6c290000b9ed12169d72e8d9c81d95dcef13c227974b95796b93c332fffef2df6da875b666fac29dd3a69c274c6583b9260976c8f0c5fffc902d34d4db910ed86f3ecddfd6af0a9f8e950d7e70a8e9b2fffc9aefa41961ce1207acd03176667537513eaf42a53fcc6534fffa95db9977c5e6e26385367a63fab8a720fc2b63bd115998d8fff8817cb6d8236d5f4d70c7815f28909d9b0c54e97155d12158fff6c5eec4228c352098789e56be1dee9b67ba25bda81292ccc1fff2840c38ccfcb5dc64b55a44095bf7f3126668b8792d4ecd08fff097074af7b286b19ec20aac21f3130f1d369e9fdbdd48528affec9054011c32d4b7a5c68d3c5d525f4af4eeb3c98615dee188ffe8dddb4a2eaab2bb15753761a8f0e9aa8d3f20620cd3e075bbffe280ef9a1b3e59abe518e6afe0651fdf49d1c0329e6a702d9dffdeca16dd49cd30854cbad8ca379401027c1fc7f47985486f16ffd6a0ba01b8742ba801e6dc14a9516d7f041f5303d878905d2fffce9c0440896ce6515c0cf3470fa7f10ac3a9dc80682c111a9dff8b";
	// 30 tints
	static inline var Q = "82703f8b53112eca71ce6279d467aa45019c9b28466b6fc0ffecb3cf74b427d53e03ee590b839e751890f2570b12bcb238cffff0b33c44af0d43c9e8f4426f84614701db979e49dc5b858442fff48264d256f0bf4d61ee21431cc0f29764ce0cc1b593ac9952fff89d97c4947687b2eeef4087c49dde5229742bc6e02bfb6df8fffaa0f888dc7aab949ef623f19ac413db23854744a164f70ecdfffc8fd9c7172ab0828e1a9f72fadafc3dfbaf96a180ea297178fffee38168b78a51ee15604a47815c8091eb9faaa42312e8eb30fffea164ccdbb65ee133e623433c5e086402cb228afd335a245f0000ced0c0cbe44fac2fd7c2adfc7c5dda9ea22b4a311cf5a5b10000f0e6660438c903713dca1a0f58f0d9438a92b9de68c4488c00008000000000000000000000000000000000000000000000000002f8ea68f9ad849103b257e4bfc606967f818fa2816928c4aa0000ddc64eeee350623447a33ea40a2b22e4a6a2c129ace2470a0000b52ddfba2d37c8e224551a9b19fa064a3d78c68b54bc3850000087ac113d26b683a14e97756c38785b0bf75f0a4506931ba80000ba065070b900f3d5e49d8f9f238f1eeb6805d48d67f1dcd9fffee902d2a4bfc22441945cfe6c83a5b828519ebb457f8ccca0fffc84e405c915f7769b0faaf34c3c51dd39a97fa0ae99382c93fffc896da46c7e6cebb3e0afc0b6db3dbbf5061ccff6e78efff4fffa801a0c1a0dfefc92f8e0a97902e08d4781898e0b7d8ef0bcfff8d59d088930df07dba8cb00021849fbaff80cc91aa0bddf89fff49db56a6984b77231cf7c2074e04809593316ecaa6aa4604efff2cb7450d9d62d2e689787b4265977d004ba615cee00a841d7ffeee12a52e02b64b23e97c9139a8ced716c70a176ad2b5f16d2ffead057b6d0900ed30d5e04bb17eb879a5e23ed135b60bea070ffe69b1f1ca22fef7ae519a687f0a4073eee05a9ccbc8c14578bffe2aeba710f053aac3b30ea5d6fb116f7758a9bcfef5698f8f1ffdc84b9ada076cd007d13e55006073f76b14cf4259968228f3effd6cca4b9046786937d233c1e691c127c1ff493e0b7a3de459affcc";
	// asin.c cc[33][8]
	static inline var ASIN_CC = "3ff000000000000000000000000000003fc55555555555553fb33333333333e43fa6db6db6d31f823f9f1c71f68893973f96e874b7045b463f91f753132271e23ff0055a27e0d033bc9d9ba10494c0623fc57c00cb5d6c4d3fb37881f5649a753fa759af49d494dd3fa002e1864dda2e3f97c2d5d468cdd93f9292834c0253573ff00abe0c129e1e3c67ceb0ee49d42a3fc5a3385d5c7ba53fb3bf51056f66373fa7dba76b124b373fa07be4b02e94c43f98a6bb92513f013f936afd4c615aec3ff0102bcffd6acdbc8c2294c65d2e863fc5caff173519013fb407abbc04feb33fa86179b80059493fa0f97520bd4e723f99950c5c89f3df3f944f2344e7b6643ff015a397cf0f1cbc8eebd6ccfe3ee33fc5f3581be7b08b3fb4519ddf1ae5313fa8eb4b6ee35e923fa17bc85414cd463f9a8e5895e3fcf93f953fafdc6294003ff01b2588811eeb3c47193e5d0a915f3fc61c46a67205d23fb49d33a6eeae0b3fa979438563c0143fa20316ae977f053f9b9339afb53aa43f963d6b02c42d0a3ff020b1c7df0575bc8dd547e329c1e53fc645ce0ab901bb3fb4ea79c34fc7a63faa0b8ac08940ec3fa28f9babd0629b3f9ca452cf90a55e3f97492b016730ef3ff026487c8c5d71bc95fd9b68dc3b6e3fc66ff1b67d5d703fb5397d613373eb3faaa24bce3aeb4a3fa3219610b150ac3f9dc251825103f13f9863d5a39325323ff02be9ce0b87cd3c7e5d09da2e0f043fc69ab5325bc3593fb58a4c3097aab33fab3db3605f46f23fa3b94821742cab3f9eedee7da72a153f998e6179a3e9a03ff03195e4c483f1bc95db10ad66eacb3fc6c61c22d908f03fb5dcf46ab9f2cb3fabddf049bb1f4d3fa456f7db6ac7683fa013f738bd7bb33f9ac9d739783d213ff0374cea0c0c9fbc9917bff5241c763fc6f22a497b2ec03fb63184d8a79db53fac83339caf946e3fa4faef331019d43fa0b8917547d6783f9c17533f147e1c3ff03d0f082afcc8bc9018bbcddb49eb3fc71ee385efdf063fb6880cda2d38853fad2db0cbfae54d3fa5a57c56b50c5e3fa16535a40098b23f9d780730b8ebb83ff042dc6a65ffbfbc8c7ea28dce95d13fc74c4bd7412f9e3fb6e09c6d2b72bc3faddd9dcda253de3fa656f1f62b50013fa21a5ae2ac77ee3f9eed3bca067f0e3ff048b53d05907b3c9634fffed6e2a63fc77a675d1978be3fb73b44355834153fae9333402ebbf33fa70fa78fd9f73f3fa2d8804d934fe13fa03c29691a281c3ff04e99ad5e4bcdbc9e97a72fe827e03fc7a93a5917200c3fb7981584731c053faf4eac9268fae23fa7cff9c3b197213fa3a02d9c1e01453fa10d64a0e569533ff05489e9d999953c8d177637ec6a2b3fc7d8c9303146813fb7f72262f532e43fb0082416e390133fa8984aac80ddf43fa471f3caf18eb83fa1eb1cce6dd5703ff05a8621feb16bbc7e5b33b1407c5f3fc809186c2e57dd3fb8587d99442dc83fb06c23d1dfcb7f3fa969024036dd223fa54e6dd4d2af333fa2d62f439f2a313ff0608e867bff303c8cbef5d85800273fc83a2cbd2d8ba23fb8bc3ab9724c6e3fb0d377ef1e0c393faa428eb7addf843fa636417bc01ff23fa3cf8acc7eb2a03ff066a34930ec8dbc9480f445fedad13fc86c0afb447a743fb9226e29948d9c3fb13e44a9b5a3a63fab2564fea8b3fe3fa72a2023d924583fa4d8313cec34853ff06cc49d38146cbc8b55394f4fc07b3fc89eb82831feed3fb98b2d2eb9bb233fb1acb01e9ab4143fac12012cbd00c63fa82ac7c1d15c383fa5f13925c6edca3ff072f2b6f1e601bc92dcbb054199703fc8d2397127aebb3fb9f68df88da51d3fb21ee26a4f62a13fad08e707f7ae6f3fa93903dee3feb03fa71bcfb5c57b593ff0792dcc0fbd20bc75bf23ee4f9d543fc9069430ab508a3fba64a7adb4cd853fb29505c8b483493fae0aa2921cfa603faa55aeb46f43223fa8593acad3bece3ff07f76139f761d3c9fa1046481bb823fc93bcdf091cca63fbad59278edc42f3fb30f46b72616523faf17c8a17c843e3fab81b2619e15b53fa9aadb395f5ae43ff085cbc61783c13c90a6e9efa201763fc971ec6c1531e43fbb4967970689123fb38dd4191401843fb0187bc3357bbb3facbe0a3dcafe263fab122f4fa499d03ff08c2f1d638e4c3c7b47c159534a3d3fc9a8f5920786243fbbc04165b57ab23fb410df5f4bed1d3fb0ab6bdf478c713fae0bc44a945c643fac90d59bcd57013ff092a054f1a2fcbc92f657224e98303fc9e0ef87243a2c3fbc3a3b7366a2783fb4989cb22e21753fb1450e5ba7ad393faf6c02c8f0ef933fae288ffc8d182c3ff0991fa9bffbf4bc5ca1140a1abbf43fca19e0a8823b803fbcb772900f9c243fb525431f0cbb2e3fb1e5c2d06804e13fb06ffefa7aa6b83fafdb4704dca3473ff09fad5a6b68f93c7aa1f06e92964e3fca53cf8e28c50e3fbd3804df1de3503fb5b70cc8fa98dc3fb28def298c979b3fb13482f6347eeb3fb0d586de48358c3ff0a649a73e61f23c874ac0d817e9c73fca8ec30dc938913fbdbc11ea9506253fb64e371d5616d33fb33e00239362493fb204426263066a3fb1cd12e46297233ff0acf4d240ccc43c9da890f3b40bd33fcacac23da077973fbe43bab7741a983fb6eb030c6318193fb3f669d2eb516e3fb2e0006ae505ae3fb2d58204457c823ff0b3af1f4880bb3c7f450fb78d32ba3fcb07d4778263af3fbecf21db7be0ef3fb78db5465013e43fb4b7a8376f09963fb3c88f9f2ef2213fb3f02ad9eb97533ff0ba78d40a9260bc957b07a441e2423fcb46015c1262623fbf5e6b94713f3d3fb836967d0afecf3fb5823fdd1707b93fb4bed355269dc23fb51e83065121cf3ff0c152382d7366bc9ee6913347c2a63fcb8550d62bfb6e3fbff1bde0fa3cad3fb8e5f3ab5509893fb656be8b38ebaf3fb5c3c13008a0993fb662225a1b4f77";
	// acos.c cc[33][8]
	static inline var ACOS_CC = "3ff000000000000000000000000000003fc55555555555553fb33333333333e43fa6db6db6d31f823f9f1c71f68893973f96e874b7045b463f91f753132271e23ff0055a27e0d033bc9d9ba10494c0623fc57c00cb5d6c4d3fb37881f5649a753fa759af49d494dd3fa002e1864dda2e3f97c2d5d468cdd93f9292834c0253573ff00abe0c129e1e3c67ceb0ee49d42a3fc5a3385d5c7ba53fb3bf51056f66373fa7dba76b124b373fa07be4b02e94c43f98a6bb92513f013f936afd4c615aec3ff0102bcffd6acdbc8c2294c65d2e863fc5caff173519013fb407abbc04feb33fa86179b80059493fa0f97520bd4e723f99950c5c89f3df3f944f2344e7b6643ff015a397cf0f1cbc8eebd6ccfe3ee33fc5f3581be7b08b3fb4519ddf1ae5313fa8eb4b6ee35e923fa17bc85414cd463f9a8e5895e3fcf93f953fafdc6294003ff01b2588811eeb3c47193e5d0a915f3fc61c46a67205d23fb49d33a6eeae0b3fa979438563c0143fa20316ae977f053f9b9339afb53aa43f963d6b02c42d0a3ff020b1c7df0575bc8dd547e329c1e53fc645ce0ab901bb3fb4ea79c34fc7a63faa0b8ac08940ec3fa28f9babd0629b3f9ca452cf90a55e3f97492b016730ef3ff026487c8c5d71bc95fd9b68dc3b6e3fc66ff1b67d5d703fb5397d613373eb3faaa24bce3aeb4a3fa3219610b150ac3f9dc251825103f13f9863d5a39325323ff02be9ce0b87cd3c7e5d09da2e0f043fc69ab5325bc3593fb58a4c3097aab33fab3db3605f46f23fa3b94821742cab3f9eedee7da72a153f998e6179a3e9a03ff03195e4c483f1bc95db10ad66eacb3fc6c61c22d908f03fb5dcf46ab9f2cb3fabddf049bb1f4d3fa456f7db6ac7683fa013f738bd7bb33f9ac9d739783d213ff0374cea0c0c9fbc9917bff5241c763fc6f22a497b2ec03fb63184d8a79db53fac83339caf946e3fa4faef331019d43fa0b8917547d6783f9c17533f147e1c3ff03d0f082afcc8bc9018bbcddb49eb3fc71ee385efdf063fb6880cda2d38853fad2db0cbfae54d3fa5a57c56b50c5e3fa16535a40098b23f9d780730b8ebb83ff042dc6a65ffbfbc8c7ea28dce95d13fc74c4bd7412f9e3fb6e09c6d2b72bc3faddd9dcda253de3fa656f1f62b50013fa21a5ae2ac77ee3f9eed3bca067f0e3ff048b53d05907b3c9634fffed6e2a63fc77a675d1978be3fb73b44355834153fae9333402ebbf33fa70fa78fd9f73f3fa2d8804d934fe13fa03c29691a281c3ff04e99ad5e4bcdbc9e97a72fe827e03fc7a93a5917200c3fb7981584731c053faf4eac9268fae23fa7cff9c3b197213fa3a02d9c1e01453fa10d64a0e569533ff05489e9d999953c8d177637ec6a2b3fc7d8c9303146813fb7f72262f532e43fb0082416e390133fa8984aac80ddf43fa471f3caf18eb83fa1eb1cce6dd5703ff05a8621feb16bbc7e5b33b1407c5f3fc809186c2e57dd3fb8587d99442dc83fb06c23d1dfcb7f3fa969024036dd223fa54e6dd4d2af333fa2d62f439f2a313ff0608e867bff303c8cbef5d85800273fc83a2cbd2d8ba23fb8bc3ab9724c6e3fb0d377ef1e0c393faa428eb7addf843fa636417bc01ff23fa3cf8acc7eb2a03ff066a34930ec8dbc9480f445fedad13fc86c0afb447a743fb9226e29948d9c3fb13e44a9b5a3a63fab2564fea8b3fe3fa72a2023d924583fa4d8313cec34853ff06cc49d38146cbc8b55394f4fc07b3fc89eb82831feed3fb98b2d2eb9bb233fb1acb01e9ab4143fac12012cbd00c63fa82ac7c1d15c383fa5f13925c6edca3ff072f2b6f1e601bc92dcbb054199703fc8d2397127aebb3fb9f68df88da51d3fb21ee26a4f62a13fad08e707f7ae6f3fa93903dee3feb03fa71bcfb5c57b593ff0792dcc0fbd20bc75bf23ee4f9d543fc9069430ab508a3fba64a7adb4cd853fb29505c8b483493fae0aa2921cfa603faa55aeb46f43223fa8593acad3bece3ff07f76139f761d3c9fa1046481bb823fc93bcdf091cca63fbad59278edc42f3fb30f46b72616523faf17c8a17c843e3fab81b2619e15b53fa9aadb395f5ae43ff085cbc61783c13c90a6e9efa201763fc971ec6c1531e43fbb4967970689123fb38dd4191401843fb0187bc3357bbb3facbe0a3dcafe263fab122f4fa499d03ff08c2f1d638e4c3c7b47c159534a3d3fc9a8f5920786243fbbc04165b57ab23fb410df5f4bed1d3fb0ab6bdf478c713fae0bc44a945c643fac90d59bcd57013ff092a054f1a2fcbc92f657224e98303fc9e0ef87243a2c3fbc3a3b7366a2783fb4989cb22e21753fb1450e5ba7ad393faf6c02c8f0ef933fae288ffc8d182c3ff0991fa9bffbf4bc5ca1140a1abbf43fca19e0a8823b803fbcb772900f9c243fb525431f0cbb2e3fb1e5c2d06804e13fb06ffefa7aa6b83fafdb4704dca3473ff09fad5a6b68f93c7aa1f06e92964e3fca53cf8e28c50e3fbd3804df1de3503fb5b70cc8fa98dc3fb28def298c979b3fb13482f6347eeb3fb0d586de48358c3ff0a649a73e61f23c874ac0d817e9c73fca8ec30dc938913fbdbc11ea9506253fb64e371d5616d33fb33e00239362493fb204426263066a3fb1cd12e46297233ff0acf4d240ccc43c9da890f3b40bd33fcacac23da077973fbe43bab7741a983fb6eb030c6318193fb3f669d2eb516e3fb2e0006ae505ae3fb2d58204457c823ff0b3af1f4880bb3c7f450fb78d32ba3fcb07d4778263af3fbecf21db7be0ef3fb78db5465013e43fb4b7a8376f09963fb3c88f9f2ef2213fb3f02ad9eb97533ff0ba78d40a9260bc957b07a441e2423fcb46015c1262623fbf5e6b94713f3d3fb836967d0afecf3fb5823fdd1707b93fb4bed355269dc23fb51e83065121cf3ff0c152382d7366bc9ee6913347c2a63fcb8550d62bfb6e3fbff1bde0fa3cad3fb8e5f3ab5509893fb656be8b38ebaf3fb5c3c13008a0993fb662225a1b4f77";
	// asin.c off[2][2]
	static inline var ASIN_OFF = "3ff921fb54442d183c91a62633145c07bff921fb54442d18bc91a62633145c07";
	// asin.c, acos.c s[33][2]
	static inline var SPI64 = "00000000000000000000000000000000bc2912bd0d569a903fa91f65f10dd814bc3e2718d26ed6883fb917a6bc29b42c3c513000a89a11e03fc2c8106e8e613abc626d19b9ff8d823fc8f8b83c69a60bbc642deef11da2c43fcf19f97b215f1bbc75d28da2c4612d3fd294062ed59f06bc1efdc0d58cf6203fd58f9a75ab1fddbc672cedd3d5a6103fd87de2a6aea9633c65b362cb9741833fdb5d1009e15cc03c5e0d891d3c68413fde2b5d3806f63bbc8a5a014347406c3fe073879922ffee3c8b25dd267f66003fe1c73b39ae68c8bc6efcc626f74a6f3fe30ff7fce170353c68076a2cfdc6b33fe44cf325091dd6bc875720992bfbb23fe57d69348ceca0bc8bdd3413b264563fe6a09e667f3bcdbc70f537acdf0ad73fe7b5df226aafafbc82c5e12ed1336d3fe8bc806b151741bc830ee2867124743fe9b3e047f387413c39f630e8b6dac83fea9b66290ea1a3bc8bc69f324e6d613feb728345196e3ebc76e0b1757c8d073fec38b2f180bdb1bc5e7b6bb5ab58ae3feced7af43cc7733c7457e610231ac23fed906bcf328d46bc8014c76c1265273fee212104f686e53c8760b1e2e3f81e3fee9f4156c62dda3c752c7adc6b49893fef0a7efb9230d73c7562172a361fd33fef6297cff75cb0bc87a0a8ca13571f3fefa7557f08a517bc887df6378811c73fefd88da3d12526bc6c57bc2e24aa153feff621e3796d7e00000000000000003ff0000000000000";
	// asin.c, acos.c c[5][2]
	static inline var CPOLY = "3ff0000000000000b93fc2c76456515b3fc55555555555553c655555556235133fb33333333333333c49997e3427441b3fa6db6db6db6db7bc1cb95ff08658e63f9f1c71c71c6d5b3c3b125bccdcc89e";
	// asin.c db[29][3]
	static inline var ASIN_DB = "3e57137449123ef63e57137449123ef7baffffffffffffff3e5d12ed0af1a27e3e5d12ed0af1a27fb7963676aa7969aa3e851c4b960778f53e851c4b9607790d3b2fffffffffffff3e93cfc2a006a4143e93cfc2a006a465b7c1e68bc303367c3e9cbaa95dadb5593e9cbaa95dadb65037f742593ef4c3d33ebacd69f89ad8f13ebacd69f89ae57a381b0ddfe3e29b3c3ef2bffffffc233b3ef2c00000006dddb851c26f2054c2303efff0f3022b2e9d3efff0f3024065e7bb9ffffffffffffe3f13217783d70d1d3f132177841ffbefbbbfffffffffffff3f1c373ff4aad79b3f1c373ff594d65bbbbfffffffffffff3f6b3f28593cad2f3f6b3f2ba40dbc66b8b27ca20c6844813f8e17b3f6bb5e6e3f8e17faefac7797b8f15a1c95184d1b3f941d60a76a82ed3f941db571d96126b8ddf34bcdacf3533f9921c0a04865373f99226605233224b9338e672f1696d53f99c360a8dd681a3f99c412d62c14403911edd261167baf3f9d6315f7ee7e013f9d641e6d5e769ab92af7dec023f5b93f9ea6fdc56fc61a3f9ea829e3e988e5b92f358e90326f9a3fa2749dc4d19c6d3fa275a3d78c01ec39149ab71c17bd113fa69768dc89bb003fa69949b3d51fb1b8e14b91318650e83faa4816b20667073faa4b0bfb0454d53c4fffffffffffff3fad77b117f230d63fad7bdcd778049f38daafc31a59e0933fafc7a07b2549aa3fafccdc252cad1fb92dc02fdac5159a3fb2df0542154f1b3fb2e36813a98740b9363abaa885a4da3fb51cf5db1b19563fb5231b416ba885b93e1e3f45d0bec33fcd0ef799001ba93fcd5064e6fe82c5b9284b9ecb11e2413fd4a8e1a96e38e33fd50954b7bbf87bb93b9f88cfb1ef423fdceee68154d1c93fde05b0e0a809bc394117d6aecd25943fdda4e0e6c717a53fded25c5eb8c916b9289e120e5744a53fde9950730c46963fdfe767739d0f6d38716376667a73f3";
	// atan.c A[129][2]
	static inline var ATAN_A = "000000000000000000000000000000003f89224e047e368e3c1a3ca6c727c59d3f992346247a91f03bf138b0ef96a1863fa2dbaae9a05db03c436e7f8a3f5e423fa927278a3b1162bbfac986efb926623faf7495ea3f37833c406ec8011ee8163fb2e239ccff3831bc5858437d4313323fb60b9f7597fdecbc3cebd13eb7c5133fb936bb8c5b2da2bc5840cac0d81db53fbc63ce377fc8023c5400b0fdaa109e3fbf93183a8db9e93c40e04e06c86e723fc1626d85a91e703c4f7ad829163ca73fc2fcac73a60640bc52680735ce2cd83fc4986a74cf4e57bc690559690b42e43fc635c990ce0d363c591d29110b41aa3fc7d4ec54fb5968bc4ea90e271827803fc975f5e0553158bc2dc82ac14e3e1c3fcb1909efd8b762bc573a10fd13daaf3fccbe4ceb4b4cf2bc63a7ffbeabda0b3fce65e3f27c9f2abc6db6627a24d5233fd007fa758626aebc645f97dd3099f63fd0de53475f3b3cbc66293f687418163fd1b6103d3597e9bc6ab240d40633e93fd28f459ecad74dbc2de34d14e832e03fd36a08355c63dc3c6af540d9fb49263fd4466d542bac923c6da60fdbc82ac43fd5248ae1701b17bc792a601170138a3fd604775fbb27dfbc67f1fca1d5d15b3fd6e649f7d78649bc64e223ea716c7b3fd7ca1a832d0f843c7b24c824ac51fc3fd8b00196b3d0223c64314cd132ba433fd998188e816bf0bc711f1e0817879a3fda827999fcef32bc6c3dea4dbad5383fdb6f3fc8c61e5b3c660d1b780ee3eb3fdc5e87185e67b6bc4ab5edb7dfa5453fdd506c82a2c800bc68e1437048b5bd3fde450e0d273e7abc706951c97b050f3fdf3c8ad985d9eebc414af9522ab5183fe01b819b5a7cf7bc7aba0d7d97d1f23fe09a4c59bd0d4d3c4095bc4ebc2c423fe11ab7190834ec3c8798826fa277743fe19cd3fe8e405d3c8008f6258fc98f3fe220b5ef047825bc5462af7ceb7de63fe2a6709a74f289bc71184dfd78b4723fe32e1889047ffd3c79141876dc40c53fe3b7c3289ed6f33c8481c20189726c3fe44386db9ce5db3c82e851bd0254413fe4d17b087b265d3c713ada9b8bc4193fe561b82ab7f990bc805b4c3c4cbee83fe5f457e4f4812ebc85619249bd96f13fe6897514751db6bc6b0a0fbcafc6713fe7212be621be6dbc819ff2dc66da453fe7bb99ed2990cf3c81320449592d923fe858de3b716571bc81fddcd2f3da8e3fe8f9197bf85eeb3c6d44a42e35cc973fe99c6e0f634394bc7585a178b4a18d3fea43002ae428503c6f95a531b3a9703feaecf5f9ba35a6bc396c2d43ca33923feb9a77c18c1af2bc6a5bed94b05def3fec4bb009e779833c454509d2bff5113fed00cbc7384d2ebc6b4c867cef300c3fedb9fa89953fcfbc1ddfac663d6bc63fee776eafc91706bc7a510683ff7cb63fef395d9f0e3c923c44fdcd8e4e87103ff000000000000000000000000000003ff065c900aaf2d8bc8deec7fc9042ad3ff0ce29d0883c99bc8395ae45e0657d3ff139447e6a86ee3c8332cf301a97f33ff1a73d55278c4bbc86cc8c4b78213b3ff2183b0c4573ff3c870a90841da57a3ff28c66fdaf8f09bc6ba39bad450ee03ff303ed61109e20bc88692946d9f93c3ff37efd8d87607e3c63b711bf765b583ff3fdca428475073c7c21387985b0813ff48089f8bf42ccbc87ddb19d3d0efc3ff507773c537eadbc7f5e354cf971f33ff592d11142fa55bc700f0ad675330d3ff622db63c8ecc2bc82c93f50ab2c0e3ff6b7df862652003c7bec391adc37d53ff7522cbdd428a8bc69686ddc9ffcf53ff7f218e25a7461bc78d165295142463ff89801106cc709bc8092f51e9c28033ff9444a7462122abc807c06755404c43ff9f7632fa9e8713c802e0d43abc92b3ffab1c35d8a74ea3c5d0184e48af6f73ffb73ee3c3ef16a3c773be957380bc23ffc3e738086bc0fbc702b6e26c844623ffd11f0dae406093c525c4f3ffa6e1f3ffdef13b73c1406bc5e302db3c6823f3ffed69b4153a45d3c73207830326c0e3fffc95abad6cf4abc66308cee7927bf4000641e192ceab3bc70147ebf0df4c54000ea21d716fbf7bc7168533cc41d8b40017749711a6679bc652a0b0333e9c540020c36c6a7f38e3c68659eece353954002a99f50fd4f4f3c820fcad18cb36f4003504f333f9de6bc752afdbd5a8c744004012ce2586a17bc79747a792907d74004bd3d87fe06503c790c59393b52c8400585aa4e1530fa3c7af6934f13a3a840065bc6cc825147bc48534dcab5ad3e40074118e4b6a7c8bc7555aa8bfca9a1400837626d70fdb8bc556b3fee9ca72b400940ad30abc7923c54b3fdd4fdc06c400a5f59e90600dd3c6285d367c55ddc400b9633283b6d14bc48712976f17a16400ce885653127e7bc3abe8ab65d49fc400e5a3de972a3773c5cd9be81ad764b400ff01305ecd8dc3c4742c2922656fa4010d7dc7cff4c9ebc77c842978bee094011d0143e71565f3c67bc7dea7c3c034012e4ff1626b9493c4aefbe25b404e940141bfee2424771bc34bcfaaa95cb2c40157be4eaa5e11b3c50fe741e4ec67940170d751908c1b13c5fe74a5b0ec7094018dc25c117782b3c50ca1c19f710ef401af73f4ca3310f3c52867b40ba77d6401d7398d15e70db3c60fd4e0d4b15474020372fb36b87e23c5c16c9ecc1621d402208dbdae055ef3c56b81a36e75e8c40244e6c595afdccbc57c220457718484027398c57f3f1ad3c5970503be105c0402b1d03c03d2f7fbc3f299d010aead2403046e9fe60a77e3c5d2b61deff33ec40345affed201b553bf0e84d9567203a403b267195b1ffaebbfad44b44b9265340445e2455e4aaa7bc3296d577b5e21d40545eed6854ce993c02db53886013ca00000000000000000000000000000000";
	// atan.c as_atan_refine2 db[12][3]
	static inline var ATAN_DB = "3f80dc89a3b550103f80dc70ac2287173c200000000000003f7e3fb41d2d22603f7e3f9013a852f83c100000000000003fe7ba49f739829f3fe46ac37224353639200000000000003fca933fe176b3753fca33f32ac5ceb5b8f00000000000003f7bb04a798200633f7bb02ed5c5e956b8c00000000000003f7cd30a9499618b3f7cd2eb65f92a46b8f00000000000003f8f44aa37b8e66b3f8f440b04187c87b8f00000000000003f7fd2ac95e57ef93f7fd2829febc03ab8f00000000000003f96419079bbf6013f9640aade8f542738d00000000000003fe7ba49f739829f3fe46ac37224353639100000000000003fcd768804487b073fccf5676f373ec1b9100000000000003f7bb04a798200633f7bb02ed5c5e956b8c0000000000000";
	// atan2.c T2[65]
	static inline var T2 = "00000000000000003f900000000000003fa00000000000003fa80000000000003fb00000000000003fb40000000000003fb80000000000003fbc0000000000003fc00000000000003fc20000000000003fc40000000000003fc60000000000003fc80000000000003fca0000000000003fcc0000000000003fce0000000000003fd00000000000003fd10000000000003fd20000000000003fd30000000000003fd40000000000003fd50000000000003fd60000000000003fd70000000000003fd80000000000003fd90000000000003fda0000000000003fdb0000000000003fdc0000000000003fdd0000000000003fde0000000000003fdf0000000000003fe00000000000003fe08000000000003fe10000000000003fe18000000000003fe20000000000003fe28000000000003fe30000000000003fe38000000000003fe40000000000003fe48000000000003fe50000000000003fe58000000000003fe60000000000003fe68000000000003fe70000000000003fe78000000000003fe80000000000003fe88000000000003fe90000000000003fe98000000000003fea0000000000003fea8000000000003feb0000000000003feb8000000000003fec0000000000003fec8000000000003fed0000000000003fed8000000000003fee0000000000003fee8000000000003fef0000000000003fef8000000000003ff0000000000000";
	// atan2.c f2[65][2]
	static inline var F2 = "00000000000000000000000000000000bca95220c39d4dff3f8fff555bbb73003ca2542779d776de3f9ffd55bba97600bca6061bbe3de53c3fa7fb818430da40bca639269b0da47e3faff55bb72cfe00bc84a7663af440f73fb3f59f0e7c55a03cad1824d59f9e133fb7ee182602f1003c8bef71e5340b313fbbe39ebe6f07c03cab8cb225e627d03fbfd5ba9aac2f603cab92de9bac94c23fc1e1fafb043720bc9d3cb89e62dafd3fc3d6eee8c66270bca882a55960087a3fc5c9811e3ec2703c91347b0b4f881d3fc7b97b4bce5b003ca873d8079ed0d23fc9a6a8e96c86203c9022f621a5c1cb3fcb90d7529260a03ca9c648d15345983fcd77d5df205730bc94ea9238610a083fcf5b75f92c80e03ca2c5c8e721970d3fd09dc597d863603c630ca4748b1bf93fd18bf5a30bf178bca20ef9ba6dbf903fd278372057ef483cae69c5abb498d23fd362773707ebc83c9a8a86f0ea93113fd44aa436c2af083c9db5336feef7f03fd530ad9951cd483c99636a3aa3b8403fd614840309cfe03c81ce2a8c848b743fd6f61941e4def0bc84b1bbd1ea6db33fd7d5604b63b3f8bca4925e8b916e0b3fd8b24d394a1b283c79e6c988fd0a773fd98cd5454d6b18bcaa49bd836a17003fda64eec3cc2400bcaca3cf09c6b5f83fdb3a911da65c70bc7cc1ce70934c343fdc0db4c94ec9f03c82e982ddf3872a3fdcde53432c1350bc82ea406ee84d0f3fddac670561bb50bcade35847c819793fde77eb7f175a38bc6a3992dc382a233fdf40dd0b541418bc8b32c949c9d5933fe0039c73c1a40cbc7d5b495f6349e63fe0657e94db30d0bcaf34582f6255fe3fe0c6145b5b43dc3c9ed42511e3f11d3fe1255d9bfbd2a8bc91cef189ff9e7f3fe1835a88be7c14bc5928df287a668f3fe1e00babdefeb4bcae3bde360c7ddb3fe23b71e2cc9e6c3c9bd86313ce4fde3fe2958e59308e30bca8e8a85803cc1d3fe2ee628406cbccbc977ef7641c777f3fe345f01cce37bc3cab73ef3389d02f3fe39c391cd417183c7ecf8b492644f03fe3f13fb89e96f43cac1125fd3810c73fe445065b795b543ca2483350fe548b3fe4978fa3269ee03c84a33dbeb3796c3fe4e8de5bb6ec04bca46edd2af694833fe538f57b890620bca2bcb93b18b52a3fe587d81f732fbc3c60028e4bc5e7ca3fe5d58987169b183caed487acaf11743fe6220d115d7b8cbca2dd4dfd7d17773fe66d663923e0883c92bfe3cf3b9d793fe6b798920b3d98bc78c34d25aadef63fe700a7c5784634bc9f426acf4d3bdb3fe748978fba8e10bcaafe57dd9ff2303fe78f6bbd5d3160bc954fbef0e862ab3fe7d528289fa0943c990227758b11ba3fe819d0b7158a4c3ca16b66e7fc8b8c3fe85d69576cc2c4bc855b9a5e177a1b3fe89ff5ff57f1f83cac27cfaa9f7a143fe8e17aa99cc05c3c81a62633145c073fe921fb54442d18";
	// atan.c c[31][3] (16 bits each)
	static inline var ATAN_C = "01a30051000001f400510000024600a3000002e900a30000038c0146000004d2014600000617028b000008a2028a00010b2c05130003103c050d000415440a0900181f3509d8002028ec133500a83b7811e000c84c912095034669e119f802db810c27e207cea1321894045db5851ef60800cc970fc60351d92311ef050be61a087c01dfecc4095602b0f375045300f7f6d804b7015dfa38022c007cfbeb025d00affd9b0116003efe75012f0058ff4e008b001fffbb0097002c";
	// atan2.c O[8][2]
	static inline var O8 = "000000000000000000000000000000003ff921fb54442d183c91a62633145c0700000000000000000000000000000000bff921fb54442d18bc91a62633145c07400921fb54442d183ca1a62633145c073ff921fb54442d183c91a62633145c07c00921fb54442d18bca1a62633145c07bff921fb54442d18bc91a62633145c07";
}
