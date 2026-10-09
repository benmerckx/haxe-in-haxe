// EXPERIMENTAL runtime for backend/: UTF-16 strings, number formatting,
// String / StringBuf / Std natives.
#include "rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

void *hx_str_alloc(int32_t len) {
	uint32_t nslots = (8 + 2 * (uint32_t)len + 7) / 8;
	void *s = rt_alloc(nslots, T_STRING, K_RAW);
	STR_LEN(s) = len;
	return s;
}

void *hx_str_of_ascii(const char *c) {
	int32_t n = (int32_t)strlen(c);
	void *s = hx_str_alloc(n);
	uint16_t *d = STR_CHARS(s);
	for (int32_t i = 0; i < n; i++)
		d[i] = (unsigned char)c[i];
	return s;
}

void *hx_str_of_utf8(const char *c, int32_t n) {
	const unsigned char *u = (const unsigned char *)c;
	// count UTF-16 units
	int32_t units = 0;
	for (int32_t i = 0; i < n;) {
		unsigned char b = u[i];
		int k = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
		units += k == 4 ? 2 : 1;
		i += k;
	}
	void *s = hx_str_alloc(units);
	uint16_t *d = STR_CHARS(s);
	int32_t j = 0;
	for (int32_t i = 0; i < n;) {
		unsigned char b = u[i];
		uint32_t cp;
		if (b < 0x80) {
			cp = b;
			i += 1;
		} else if (b < 0xE0) {
			cp = ((b & 0x1F) << 6) | (i + 1 < n ? u[i + 1] & 0x3F : 0);
			i += 2;
		} else if (b < 0xF0) {
			cp = ((b & 0x0F) << 12) | ((i + 1 < n ? u[i + 1] & 0x3F : 0) << 6) | (i + 2 < n ? u[i + 2] & 0x3F : 0);
			i += 3;
		} else {
			cp = ((b & 0x07) << 18) | ((i + 1 < n ? u[i + 1] & 0x3F : 0) << 12) | ((i + 2 < n ? u[i + 2] & 0x3F : 0) << 6) | (i + 3 < n ? u[i + 3] & 0x3F : 0);
			i += 4;
		}
		if (cp >= 0x10000) {
			cp -= 0x10000;
			d[j++] = 0xD800 | (cp >> 10);
			d[j++] = 0xDC00 | (cp & 0x3FF);
		} else d[j++] = cp;
	}
	return s;
}

// UTF-8 bytes of a string into buf (size >= 3 * length + 1); returns the byte count
int32_t hx_str_utf8_into(void *s, char *buf) {
	uint16_t *c = STR_CHARS(s);
	int32_t n = STR_LEN(s), j = 0;
	for (int32_t i = 0; i < n; i++) {
		uint32_t cp = c[i];
		if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n && c[i + 1] >= 0xDC00 && c[i + 1] < 0xE000) {
			cp = 0x10000 + ((cp - 0xD800) << 10) + (c[i + 1] - 0xDC00);
			i++;
		}
		if (cp < 0x80) buf[j++] = cp;
		else if (cp < 0x800) {
			buf[j++] = 0xC0 | (cp >> 6);
			buf[j++] = 0x80 | (cp & 0x3F);
		} else if (cp < 0x10000) {
			buf[j++] = 0xE0 | (cp >> 12);
			buf[j++] = 0x80 | ((cp >> 6) & 0x3F);
			buf[j++] = 0x80 | (cp & 0x3F);
		} else {
			buf[j++] = 0xF0 | (cp >> 18);
			buf[j++] = 0x80 | ((cp >> 12) & 0x3F);
			buf[j++] = 0x80 | ((cp >> 6) & 0x3F);
			buf[j++] = 0x80 | (cp & 0x3F);
		}
	}
	buf[j] = 0;
	return j;
}

char *hx_str_to_utf8(void *s) {
	if (!s) return strdup("null");
	char *buf = (char *)malloc(3 * (size_t)STR_LEN(s) + 1);
	hx_str_utf8_into(s, buf);
	return buf;
}

int hx_str_eq_slow(void *a, void *b) {
	return memcmp(STR_CHARS(a), STR_CHARS(b), 2 * (size_t)STR_LEN(a)) == 0;
}

int32_t hx_str_cmp(void *a, void *b) {
	if (a == b) return 0;
	if (!a) return -1;
	if (!b) return 1;
	int32_t na = STR_LEN(a), nb = STR_LEN(b), n = na < nb ? na : nb;
	uint16_t *ca = STR_CHARS(a), *cb = STR_CHARS(b);
	for (int32_t i = 0; i < n; i++)
		if (ca[i] != cb[i]) return ca[i] < cb[i] ? -1 : 1;
	return na < nb ? -1 : na > nb ? 1 : 0;
}

int32_t hx_str_hash(void *s) {
	// cached in the string (a benign race between threads: the same value)
	int32_t *h = &((int32_t *)s)[1];
#if RT_MT
	int32_t h0 = __atomic_load_n(h, __ATOMIC_RELAXED);
	if (h0) return h0;
#else
	if (*h) return *h;
#endif
	uint32_t x = 2166136261u;
	uint16_t *c = STR_CHARS(s);
	for (int32_t i = 0, n = STR_LEN(s); i < n; i++)
		x = (x ^ c[i]) * 16777619u;
	if (x == 0) x = 1;
#if RT_MT
	__atomic_store_n(h, (int32_t)x, __ATOMIC_RELAXED);
#else
	*h = (int32_t)x;
#endif
	return (int32_t)x;
}

int32_t hxc_Native_strHash(void *s) {
	return hx_str_hash(s);
}

static uint64_t null_storage[3] = {MKHDR(2, K_RAW, T_STRING), 4, 0x006c006c0075006eull};
void *hx_str_or_null(void *s) {
	return s ? s : (void *)&null_storage[1];
}

void *hx_str_concat(void *a, void *b) {
	a = hx_str_or_null(a);
	b = hx_str_or_null(b);
	int32_t na = STR_LEN(a), nb = STR_LEN(b);
	if (na == 0) return b;
	if (nb == 0) return a;
	RT_ROOT(a);
	RT_ROOT(b);
	void *s = hx_str_alloc(na + nb);
	RT_RELOAD(a);
	RT_RELOAD(b);
	RT_UNROOT(2);
	memcpy(STR_CHARS(s), STR_CHARS(a), 2 * (size_t)na);
	memcpy(STR_CHARS(s) + na, STR_CHARS(b), 2 * (size_t)nb);
	return s;
}

void *hx_str_of_int(int32_t v) {
	char buf[16];
	snprintf(buf, sizeof buf, "%d", v);
	return hx_str_of_ascii(buf);
}

// shortest representation that reads back as the same double, formatted like JavaScript
void hx_format_float(double v, char *out) {
	if (v != v) {
		strcpy(out, "NaN");
		return;
	}
	if (isinf(v)) {
		strcpy(out, v > 0 ? "Infinity" : "-Infinity");
		return;
	}
	if (v == 0) {
		strcpy(out, signbit(v) ? "-0" : "0");
		return;
	}
	char buf[40];
	int prec;
	for (prec = 1; prec <= 17; prec++) {
		snprintf(buf, sizeof buf, "%.*e", prec - 1, v);
		if (strtod(buf, NULL) == v) break;
	}
	// buf: [-]d.ddde[+-]xx ; digits and exponent
	char digits[24];
	int nd = 0, neg = 0, i = 0;
	if (buf[0] == '-') {
		neg = 1;
		i = 1;
	}
	for (; buf[i] && buf[i] != 'e'; i++)
		if (buf[i] != '.') digits[nd++] = buf[i];
	digits[nd] = 0;
	int exp = atoi(buf + i + 1);
	char *o = out;
	if (neg) *o++ = '-';
	if (exp >= 21 || exp < -6) {
		*o++ = digits[0];
		if (nd > 1) {
			*o++ = '.';
			memcpy(o, digits + 1, nd - 1);
			o += nd - 1;
		}
		o += sprintf(o, "e%c%d", exp < 0 ? '-' : '+', exp < 0 ? -exp : exp);
	} else if (exp >= 0) {
		for (int k = 0; k <= exp; k++)
			*o++ = k < nd ? digits[k] : '0';
		if (nd > exp + 1) {
			*o++ = '.';
			memcpy(o, digits + exp + 1, nd - exp - 1);
			o += nd - exp - 1;
		}
	} else {
		*o++ = '0';
		*o++ = '.';
		for (int k = 0; k < -exp - 1; k++)
			*o++ = '0';
		memcpy(o, digits, nd);
		o += nd;
	}
	*o = 0;
}

void *hx_str_of_float(double v) {
	char buf[48];
	hx_format_float(v, buf);
	return hx_str_of_ascii(buf);
}

void *hx_str_of_bool(int32_t v) {
	return hx_str_of_ascii(v ? "true" : "false");
}

// ---- String

void *String_charAt(void *s, int32_t i) {
	if ((uint32_t)i >= (uint32_t)STR_LEN(s)) return hx_str_alloc(0);
	RT_ROOT(s);
	void *r = hx_str_alloc(1);
	RT_RELOAD(s);
	RT_UNROOT(1);
	STR_CHARS(r)[0] = STR_CHARS(s)[i];
	return r;
}

void *String_charCodeAt(void *s, int32_t i) {
	if ((uint32_t)i >= (uint32_t)STR_LEN(s)) return 0;
	return hx_box_int(STR_CHARS(s)[i]);
}

void *String_fromCharCode(int32_t code) {
	if (code >= 0x10000) {
		void *r = hx_str_alloc(2);
		code -= 0x10000;
		STR_CHARS(r)[0] = 0xD800 | (code >> 10);
		STR_CHARS(r)[1] = 0xDC00 | (code & 0x3FF);
		return r;
	}
	void *r = hx_str_alloc(1);
	STR_CHARS(r)[0] = code;
	return r;
}

static int32_t opt_int(void *boxed, int32_t dflt) {
	return boxed ? hx_unbox_int(boxed) : dflt;
}

int32_t String_indexOf(void *s, void *sub, void *start) {
	int32_t n = STR_LEN(s), m = STR_LEN(sub), from = opt_int(start, 0);
	if (from < 0) from = 0;
	uint16_t *c = STR_CHARS(s), *d = STR_CHARS(sub);
	for (int32_t i = from; i + m <= n; i++)
		if (memcmp(c + i, d, 2 * (size_t)m) == 0) return i;
	return -1;
}

int32_t String_lastIndexOf(void *s, void *sub, void *start) {
	int32_t n = STR_LEN(s), m = STR_LEN(sub), from = opt_int(start, n);
	if (from > n - m) from = n - m;
	uint16_t *c = STR_CHARS(s), *d = STR_CHARS(sub);
	for (int32_t i = from; i >= 0; i--)
		if (memcmp(c + i, d, 2 * (size_t)m) == 0) return i;
	return -1;
}

static void *substr_range(void *s, int32_t pos, int32_t len) {
	RT_ROOT(s);
	void *r = hx_str_alloc(len);
	RT_RELOAD(s);
	RT_UNROOT(1);
	memcpy(STR_CHARS(r), STR_CHARS(s) + pos, 2 * (size_t)len);
	return r;
}

void *String_substr(void *s, int32_t pos, void *lenp) {
	int32_t n = STR_LEN(s);
	int32_t len = lenp ? hx_unbox_int(lenp) : n;
	if (pos < 0) {
		pos += n;
		if (pos < 0) pos = 0;
	}
	if (pos > n) return hx_str_alloc(0);
	if (len < 0) {
		len += n - pos;
		if (len < 0) return hx_str_alloc(0);
	}
	if (pos + len > n) len = n - pos;
	if (pos == 0 && len == n) return s;
	return substr_range(s, pos, len);
}

void *String_substring(void *s, int32_t start, void *endp) {
	int32_t n = STR_LEN(s);
	int32_t end = endp ? hx_unbox_int(endp) : n;
	if (start < 0) start = 0;
	if (end < 0) end = 0;
	if (start > n) start = n;
	if (end > n) end = n;
	if (start > end) {
		int32_t t = start;
		start = end;
		end = t;
	}
	if (start == 0 && end == n) return s;
	return substr_range(s, start, end - start);
}

void *String_toLowerCase(void *s) {
	int32_t n = STR_LEN(s);
	RT_ROOT(s);
	void *r = hx_str_alloc(n);
	RT_RELOAD(s);
	RT_UNROOT(1);
	for (int32_t i = 0; i < n; i++) {
		uint16_t c = STR_CHARS(s)[i];
		STR_CHARS(r)[i] = c >= 'A' && c <= 'Z' ? c + 32 : c;
	}
	return r;
}

void *String_toUpperCase(void *s) {
	int32_t n = STR_LEN(s);
	RT_ROOT(s);
	void *r = hx_str_alloc(n);
	RT_RELOAD(s);
	RT_UNROOT(1);
	for (int32_t i = 0; i < n; i++) {
		uint16_t c = STR_CHARS(s)[i];
		STR_CHARS(r)[i] = c >= 'a' && c <= 'z' ? c - 32 : c;
	}
	return r;
}

void *String_toString(void *s) {
	return s;
}

void *String_split(void *s, void *delim) {
	RT_ROOT(s);
	RT_ROOT(delim);
	void *arr = hx_arr_new(AK_PTR, 0);
	RT_ROOT(arr);
	RT_RELOAD(delim); // hx_arr_new may have moved it (a stale delim's length is its forwarding address)
	int32_t m = STR_LEN(delim);
	int32_t start = 0;
	for (;;) {
		RT_RELOAD(s);
		RT_RELOAD(delim);
		int32_t n = STR_LEN(s);
		int32_t at = -1;
		if (m == 0) {
			// split("") gives the code units
			if (start >= n) break;
			at = start + 1;
		} else
			for (int32_t i = start; i + m <= n; i++)
				if (memcmp(STR_CHARS(s) + i, STR_CHARS(delim), 2 * (size_t)m) == 0) {
					at = i;
					break;
				}
		int32_t end = at < 0 ? n : at;
		void *part = substr_range(s, start, end - start);
		*rt_sp++ = part;
		hx_apush_slow(arr_root, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
		rt_sp--;
		if (at < 0) break;
		start = m == 0 ? at : at + m;
	}
	RT_RELOAD(arr);
	RT_UNROOT(3);
	return arr;
}

// ---- StringBuf: slot 0 length, slot 1 data (K_RAW uint16 units)

void *StringBuf_new(void) {
	void *b = rt_alloc(2, T_STRINGBUF, K_OBJ);
	RT_ROOT(b);
	void *d = rt_alloc(8, T_ADATA_RAW, K_RAW);
	RT_RELOAD(b);
	RT_UNROOT(1);
	rt_set_ptr(b, &FP(b, 1), d);
	return b;
}

static void sb_reserve(void **slot, int32_t extra) {
	void *b = *slot;
	int32_t len = FI(b, 0);
	uint32_t cap = NSLOTS(FP(b, 1)) * 4;
	if ((uint32_t)(len + extra) <= cap) return;
	uint32_t ncap = cap * 2;
	if (ncap < (uint32_t)(len + extra)) ncap = len + extra;
	void *nd = rt_alloc((ncap + 3) / 4, T_ADATA_RAW, K_RAW);
	b = *slot;
	memcpy(nd, FP(b, 1), 2 * (size_t)len);
	rt_set_ptr(b, &FP(b, 1), nd);
}

static void sb_add_str(void *b, void *s) {
	RT_ROOT(b);
	RT_ROOT(s);
	int32_t n = STR_LEN(s);
	sb_reserve(b_root, n);
	RT_RELOAD(b);
	RT_RELOAD(s);
	RT_UNROOT(2);
	memcpy((uint16_t *)FP(b, 1) + FI(b, 0), STR_CHARS(s), 2 * (size_t)n);
	FI(b, 0) += n;
}

void StringBuf_add(void *b, void *x) {
	RT_ROOT(b);
	void *s = hx_std_string(x);
	RT_RELOAD(b);
	RT_UNROOT(1);
	sb_add_str(b, s);
}

void StringBuf_addChar(void *b, int32_t c) {
	RT_ROOT(b);
	sb_reserve(b_root, 2);
	RT_RELOAD(b);
	RT_UNROOT(1);
	uint16_t *d = (uint16_t *)FP(b, 1);
	if (c >= 0x10000) {
		c -= 0x10000;
		d[FI(b, 0)++] = 0xD800 | (c >> 10);
		d[FI(b, 0)++] = 0xDC00 | (c & 0x3FF);
	} else d[FI(b, 0)++] = c;
}

void StringBuf_addSub(void *b, void *s, int32_t pos, void *lenp) {
	RT_ROOT(b);
	void *sub = String_substr(s, pos, lenp);
	RT_RELOAD(b);
	RT_UNROOT(1);
	sb_add_str(b, sub);
}

int32_t StringBuf_get_length(void *b) {
	return FI(b, 0);
}

void *StringBuf_toString(void *b) {
	RT_ROOT(b);
	void *s = hx_str_alloc(FI(b, 0));
	RT_RELOAD(b);
	RT_UNROOT(1);
	memcpy(STR_CHARS(s), FP(b, 1), 2 * (size_t)FI(b, 0));
	return s;
}

// ---- Std

void *Std_string(void *v) {
	return hx_std_string(v);
}

void *Std_parseInt(void *s) {
	if (!s) return 0;
	int32_t n = STR_LEN(s), i = 0;
	uint16_t *c = STR_CHARS(s);
	while (i < n && (c[i] == ' ' || c[i] == '\t' || c[i] == '\n' || c[i] == '\r'))
		i++;
	int neg = 0;
	if (i < n && (c[i] == '-' || c[i] == '+')) {
		neg = c[i] == '-';
		i++;
	}
	if (i + 1 < n && c[i] == '0' && (c[i + 1] == 'x' || c[i + 1] == 'X')) {
		i += 2;
		uint32_t v = 0;
		int any = 0;
		for (; i < n; i++) {
			int d = c[i] >= '0' && c[i] <= '9' ? c[i] - '0' : c[i] >= 'a' && c[i] <= 'f' ? c[i] - 'a' + 10 : c[i] >= 'A' && c[i] <= 'F' ? c[i] - 'A' + 10 : -1;
			if (d < 0) break;
			v = v * 16 + d;
			any = 1;
		}
		if (!any) return 0;
		return hx_box_int(neg ? -(int32_t)v : (int32_t)v);
	}
	int64_t v = 0;
	int any = 0;
	for (; i < n && c[i] >= '0' && c[i] <= '9'; i++) {
		v = v * 10 + (c[i] - '0');
		if (v > 0xFFFFFFFFll) v &= 0xFFFFFFFFll;
		any = 1;
	}
	if (!any) return 0;
	return hx_box_int((int32_t)(neg ? -v : v));
}

double Std_parseFloat(void *s) {
	if (!s) return NAN;
	char *u = hx_str_to_utf8(s);
	char *p = u;
	while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
		p++;
	char *end;
	double d = strtod(p, &end);
	if (end == p) d = NAN;
	free(u);
	return d;
}

int32_t Std_random(int32_t max) {
	if (max <= 0) return 0;
	return (int32_t)(((uint64_t)rand() * (uint64_t)max) / ((uint64_t)RAND_MAX + 1));
}

int32_t Std_isOfType(void *v, void *t) {
	return hx_is(v, t);
}

void *Std_downcast(void *v, void *t) {
	return hx_is(v, t) ? v : 0;
}

// ---- Std.string

void *hx_std_string(void *v) {
	if (!v) return hx_str_or_null(0);
	uint32_t t = TINDEX(v);
	switch (t) {
	case T_STRING: return v;
	case T_BOXINT: return hx_str_of_int(FI(v, 0));
	case T_BOXFLOAT: return hx_str_of_float(FD(v, 0));
	case T_BOXBOOL: return hx_str_of_bool(FI(v, 0));
	case T_TYPEOBJ: return hx_str_of_ascii(rt_types[FI(v, 0)].name);
	case T_ARRAY: {
		// [a,b,c]
		RT_ROOT(v);
		void *b = StringBuf_new();
		RT_ROOT(b);
		StringBuf_addChar(b, '[');
		for (int32_t i = 0;; i++) {
			RT_RELOAD(v);
			if (i >= ARR_LEN(v)) break;
			if (i > 0) {
				RT_RELOAD(b);
				StringBuf_addChar(b, ',');
				RT_RELOAD(v);
			}
			void *e = hx_aget_p_slow(v, i);
			void *s = hx_std_string(e);
			RT_RELOAD(b);
			sb_add_str(b, s);
		}
		RT_RELOAD(b);
		StringBuf_addChar(b, ']');
		RT_RELOAD(b);
		RT_UNROOT(2);
		return StringBuf_toString(b);
	}
	}
	if (t < T_FIRST) return hx_str_of_ascii(rt_types[t].name);
	const rt_type *ty = &rt_types[t];
	switch (ty->tk) {
	case TK_CTOR: {
		// Name(p1,p2)
		RT_ROOT(v);
		void *b = StringBuf_new();
		RT_ROOT(b);
		void *name = hx_str_of_ascii(ty->name);
		RT_RELOAD(b);
		sb_add_str(b, name);
		uint32_t np = ty->nslots;
		if (np > 0) {
			RT_RELOAD(b);
			StringBuf_addChar(b, '(');
			for (uint32_t i = 0; i < np; i++) {
				if (i > 0) {
					RT_RELOAD(b);
					StringBuf_addChar(b, ',');
				}
				RT_RELOAD(v);
				void *p = 0;
				char k = 'p';
				for (uint32_t f = 0; f < ty->nfields; f++)
					if (ty->fields[f].slot == (int32_t)(ty->fields[f].kind == 'i' || ty->fields[f].kind == 'b' ? 2 * i : i)) k = ty->fields[f].kind;
				switch (k) {
				case 'i': p = hx_box_int(FI(v, i)); break;
				case 'b': p = hx_box_bool(FI(v, i)); break;
				case 'f': p = hx_box_float(FD(v, i)); break;
				default: p = FP(v, i);
				}
				void *s = hx_std_string(p);
				RT_RELOAD(b);
				sb_add_str(b, s);
			}
			RT_RELOAD(b);
			StringBuf_addChar(b, ')');
		}
		RT_RELOAD(b);
		RT_UNROOT(2);
		return StringBuf_toString(b);
	}
	case TK_CLASS: {
		extern int32_t hx_fid_c(const char *name);
		int32_t f = hx_fid_c("toString");
		if (f >= 0)
			for (uint32_t i = 0; i < ty->nmethods; i++)
				if (ty->methods[i].fid == f) return ((void *(*)(void *))ty->methods[i].fn)(v);
		return hx_str_of_ascii(ty->name);
	}
	case TK_ANON: {
		extern void *hx_anon_to_string(void *o);
		return hx_anon_to_string(v);
	}
	case TK_CLOSURE:
	case TK_BOUND: return hx_str_of_ascii("<function>");
	default: return hx_str_of_ascii(ty->name);
	}
}
