/* The reference side of hxmc/test/Libm.hx: inputs for the math functions
   of hxmc's LibM (hxmc/std/hxmc/rt/LibM*.hx) with the results of the C
   library this is linked with (glibc on Linux: the reference compiler's),
   as records on stdout for hxmc/test/libm/Probe.hx.
     cc -O1 -fno-builtin hxmc/test/libm/ref.c -lm -o ref && ./ref <n per function> [seed]
   (hxmc/test/Libm.hx runs it)
   A record is 40 bytes, little-endian: int32 function, int32 0, double x,
   double y (atan2, pow, fmod, fma), double z (fma), double the result. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SIN, COS, TAN, ASIN, ACOS, ATAN, ATAN2, EXP, LOG, POW, FMOD, FLOOR, CEIL, FMA, NFUN };

static uint64_t state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) { /* xorshift64* */
	state ^= state >> 12;
	state ^= state << 25;
	state ^= state >> 27;
	return state * 0x2545f4914f6cdd1dull;
}
static double of_bits(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static uint64_t to_bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static int below(int n) { return (int)(rnd() % (uint64_t)n); }
static double sign(double x) { return rnd() & 1 ? -x : x; }

/* any bit pattern: every class (subnormals, infinities, NaNs) */
static double any(void) { return of_bits(rnd()); }
/* random sign, binary exponent in [lo, hi], random mantissa */
static double expo(int lo, int hi) {
	int e = lo + below(hi - lo + 1);
	uint64_t m = rnd() & 0x000fffffffffffffull;
	if (e < -1022) /* subnormal */
		return sign(of_bits(m >> (-1022 - e)));
	return sign(of_bits(m | (uint64_t)(e + 1023) << 52));
}
static double pos_expo(int lo, int hi) { return fabs(expo(lo, hi)); }
/* a short decimal, as programs write them: k / 10^d */
static double decimal(int maxk) {
	static const double p10[] = {1, 10, 100, 1000, 10000};
	return (double)(below(2 * maxk + 1) - maxk) / p10[below(5)];
}
/* x shifted by a few ulps */
static double ulps(double x, int k) { return of_bits(to_bits(x) + (uint64_t)(int64_t)(below(2 * k + 1) - k)); }

static const double specials[] = {
	0.0, -0.0, INFINITY, -INFINITY, NAN, -NAN, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0, 10.0, 0.1, -0.1,
	4.9406564584124654e-324, -4.9406564584124654e-324, 2.2250738585072009e-308, 2.2250738585072014e-308,
	-2.2250738585072014e-308, 1.7976931348623157e308, -1.7976931348623157e308, 3.141592653589793,
	-3.141592653589793, 1.5707963267948966, -1.5707963267948966, 0.7853981633974483, 6.283185307179586,
	1e22, -1e22, 1e300, 8.98846567431158e307, 709.782712893384, 709.7827128933841, -745.1332191019411,
	-745.1332191019412, -708.3964185322641, 0.9999999999999999, 1.0000000000000002, 4503599627370496.0,
	4503599627370497.0, 9007199254740992.0, -2.5, 2.5, 1e-300, 1e-310, 255.0, 0.25,
};
#define NSPECIAL ((int)(sizeof specials / sizeof specials[0]))
static double special(void) { return specials[below(NSPECIAL)]; }

static void put3(int f, double x, double y, double z, double r) {
	struct { int32_t f, pad; double x, y, z, r; } rec = {f, 0, x, y, z, r};
	fwrite(&rec, sizeof rec, 1, stdout);
}
static void put(int f, double x, double y, double r) { put3(f, x, y, 0, r); }

static double trig_input(void) {
	switch (below(8)) {
	case 0: return any();
	case 1: case 2: return expo(-30, 30);
	case 3: return expo(-1074, 1023); /* subnormal to huge */
	case 4: return decimal(1000000);
	case 5: return sign(ulps(below(200000) * 1.5707963267948966, 4)); /* near multiples of pi/2 */
	case 6: return (double)(below(2000001) - 1000000); /* integers */
	default: return special();
	}
}

static void gen(int f, long n) {
	for (long i = 0; i < n; i++) {
		double x = 0, y = 0, r;
		switch (f) {
		case SIN: x = trig_input(); r = sin(x); break;
		case COS: x = trig_input(); r = cos(x); break;
		case TAN: x = trig_input(); r = tan(x); break;
		case ASIN: case ACOS:
			switch (below(6)) {
			case 0: x = any(); break;
			case 1: case 2: x = expo(-60, -1); break;
			case 3: x = sign(1.0 - pos_expo(-53, -2)); break; /* near +-1 */
			case 4: { /* decimals in [-1, 1] */
				static const int p10[] = {10, 100, 1000, 10000};
				int p = p10[below(4)];
				x = (double)(below(2 * p + 1) - p) / p;
				break;
			}
			default: x = special();
			}
			r = f == ASIN ? asin(x) : acos(x);
			break;
		case ATAN:
			switch (below(5)) {
			case 0: x = any(); break;
			case 1: case 2: x = expo(-60, 60); break;
			case 3: x = decimal(1000000); break;
			default: x = special();
			}
			r = atan(x);
			break;
		case ATAN2:
			switch (below(7)) {
			case 0: y = any(); x = any(); break;
			case 1: case 2: y = expo(-40, 40); x = expo(-40, 40); break;
			case 3: y = decimal(100000); x = decimal(100000); break;
			case 4: y = special(); x = special(); break;
			case 5: y = expo(-1074, 1023); x = expo(-1074, 1023); break;
			default: y = expo(-20, 20); x = ulps(y * (below(2) ? 1 : -1), 3); break; /* near the diagonals */
			}
			r = atan2(y, x);
			put(f, y, x, r); /* x is atan2's first argument in a record */
			continue;
		case EXP:
			switch (below(7)) {
			case 0: x = any(); break;
			case 1: case 2: x = (double)rnd() / 18446744073709551616.0 * 1460 - 750; break; /* the finite range */
			case 3: x = expo(-60, 10); break;
			case 4: x = -708.4 - (double)rnd() / 18446744073709551616.0 * 37; break; /* subnormal results */
			case 5: x = decimal(1000000); break;
			default: x = special();
			}
			r = exp(x);
			break;
		case LOG:
			switch (below(6)) {
			case 0: x = any(); break;
			case 1: case 2: x = pos_expo(-1074, 1023); break;
			case 3: x = 1.0 + expo(-60, -3); break; /* near 1 */
			case 4: x = fabs(decimal(1000000)); break;
			default: x = special();
			}
			r = log(x);
			break;
		case POW:
			switch (below(9)) {
			case 0: x = any(); y = any(); break;
			case 1: case 2: x = pos_expo(-30, 30); y = expo(-10, 6); break;
			case 3: x = 1.0 + expo(-50, -5); y = expo(10, 60); break; /* near 1, large y */
			case 4: x = -pos_expo(-10, 10); y = (double)(below(201) - 100); break; /* negative x, integer y */
			case 5: x = decimal(10000); y = (double)(below(41) - 20) / (below(2) ? 1 : 2); break;
			case 6: x = special(); y = special(); break;
			case 7: x = pos_expo(-1074, 1023); y = expo(-60, 11); break; /* results over the whole range */
			default: x = pos_expo(-3, 3); y = expo(-1, 11); break;
			}
			r = pow(x, y);
			break;
		case FMOD:
			switch (below(4)) {
			case 0: x = any(); y = any(); break;
			case 1: x = expo(-1074, 1023); y = expo(-1074, 1023); break;
			case 2: x = decimal(1000000); y = decimal(1000); break;
			default: x = special(); y = special(); break;
			}
			r = fmod(x, y);
			break;
		case FLOOR: case CEIL:
			switch (below(4)) {
			case 0: x = any(); break;
			case 1: x = expo(-10, 60); break;
			case 2: x = decimal(1000000); break;
			default: x = special();
			}
			r = f == FLOOR ? floor(x) : ceil(x);
			break;
		case FMA: { /* hxmc.rt.LibM.fma, which the others are built on */
			double z;
			switch (below(6)) {
			case 0: x = any(); y = any(); z = any(); break;
			case 1: x = expo(-60, 60); y = expo(-60, 60); z = expo(-120, 120); break;
			case 2: x = expo(-60, 60); y = expo(-60, 60); z = -x * y; z = ulps(z, 2); break; /* cancellation */
			case 3: x = expo(-1074, 1023); y = expo(-1074, 1023); z = expo(-1074, 1023); break;
			case 4: x = expo(-600, -400); y = expo(-600, -400); z = expo(-1074, -900); break; /* tiny results */
			default: x = expo(-60, 60); y = expo(-60, 60); z = sign(ldexp(x * y, -50 - below(10))); break;
			}
			put3(f, x, y, z, fma(x, y, z));
			continue;
		}
		default: return;
		}
		put(f, x, y, r);
	}
}

/* --wc f: the inputs of a CORE-MATH hard-case list (src/binary64/<f>/<f>.wc)
   on stdin, for function f (SIN...ATAN2), with both signs */
static void wc(int f) {
	char line[512];
	while (fgets(line, sizeof line, stdin)) {
		if (line[0] == '#' || strstr(line, "snan")) continue;
		char *e;
		double x = strtod(line, &e), y = 0;
		if (e == line) continue;
		if (f == ATAN2) {
			while (*e == ',' || *e == ' ') e++;
			y = strtod(e, NULL);
		}
		for (int s = 0; s < (f == ATAN2 ? 4 : 2); s++) {
			double a = s & 1 ? -x : x, b = s & 2 ? -y : y, r;
			switch (f) {
			case SIN: r = sin(a); break;
			case COS: r = cos(a); break;
			case TAN: r = tan(a); break;
			case ASIN: r = asin(a); break;
			case ACOS: r = acos(a); break;
			case ATAN: r = atan(a); break;
			default: r = atan2(a, b);
			}
			put(f, a, b, r);
		}
	}
}

int main(int argc, char **argv) {
	if (argc > 2 && !strcmp(argv[1], "--wc")) {
		wc(atoi(argv[2]));
		return 0;
	}
	long n = argc > 1 ? atol(argv[1]) : 100000;
	if (argc > 2) state ^= strtoull(argv[2], NULL, 0) * 0x9e3779b97f4a7c15ull;
	for (int f = 0; f < NFUN; f++) {
		/* every special value (pairs for the two-argument functions) first */
		for (int i = 0; i < NSPECIAL; i++) {
			double x = specials[i];
			switch (f) {
			case SIN: put(f, x, 0, sin(x)); break;
			case COS: put(f, x, 0, cos(x)); break;
			case TAN: put(f, x, 0, tan(x)); break;
			case ASIN: put(f, x, 0, asin(x)); break;
			case ACOS: put(f, x, 0, acos(x)); break;
			case ATAN: put(f, x, 0, atan(x)); break;
			case EXP: put(f, x, 0, exp(x)); break;
			case LOG: put(f, x, 0, log(x)); break;
			case FLOOR: put(f, x, 0, floor(x)); break;
			case FMA:
				for (int j = 0; j < NSPECIAL; j++)
					for (int k = 0; k < NSPECIAL; k += 7)
						put3(f, x, specials[j], specials[k], fma(x, specials[j], specials[k]));
				break;
			case CEIL: put(f, x, 0, ceil(x)); break;
			default:
				for (int j = 0; j < NSPECIAL; j++) {
					double y = specials[j];
					put(f, x, y, f == ATAN2 ? atan2(x, y) : f == POW ? pow(x, y) : fmod(x, y));
				}
			}
		}
		gen(f, n);
	}
	return 0;
}
