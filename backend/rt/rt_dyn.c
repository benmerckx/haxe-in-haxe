// EXPERIMENTAL runtime for backend/: field names, structural access,
// Dynamic operations, type tests, reflection intrinsics (hxc.Native).
#include "rt_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

void *hx_str_alloc(int32_t len);
int32_t hx_str_utf8_into(void *s, char *buf);
void hx_arr_to_ptr(void **slot);

// ---- field names: the generated table is sorted; names seen only at run time are appended

// Names added at run time live in chunks that never move, so a reader needs no
// lock for a name it got an id for; adding (and searching the added names)
// holds extra_lock.
#define EXTRA_CHUNK 1024
static char **extra_chunks[4096];
static int nextra;
static rt_lock_t extra_lock = RT_LOCK_INIT;

static const char *extra_name(int i) { return extra_chunks[i / EXTRA_CHUNK][i % EXTRA_CHUNK]; }

static int32_t find_static_name(const char *name) {
	int lo = 0, hi = rt_nfield_names - 1;
	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		int c = strcmp(rt_field_names[mid], name);
		if (c == 0) return mid;
		if (c < 0) lo = mid + 1;
		else hi = mid - 1;
	}
	return -1;
}

static int32_t find_extra(const char *name) {
	for (int i = 0; i < nextra; i++)
		if (strcmp(extra_name(i), name) == 0) return rt_nfield_names + i;
	return -1;
}

int32_t hx_fid_c(const char *name) {
	int32_t f = find_static_name(name);
	if (f >= 0) return f;
	rt_lock(&extra_lock);
	f = find_extra(name);
	rt_unlock(&extra_lock);
	return f;
}

static int32_t intern(const char *name) {
	int32_t f = find_static_name(name);
	if (f >= 0) return f;
	rt_lock(&extra_lock);
	f = find_extra(name);
	if (f < 0) {
		int c = nextra / EXTRA_CHUNK;
		if (!extra_chunks[c]) extra_chunks[c] = (char **)malloc(EXTRA_CHUNK * sizeof(char *));
		extra_chunks[c][nextra % EXTRA_CHUNK] = strdup(name);
		f = rt_nfield_names + nextra++;
	}
	rt_unlock(&extra_lock);
	return f;
}

int32_t hx_fid(void *name) {
	char small[256];
	char *buf = STR_LEN(name) * 3 + 1 <= (int32_t)sizeof small ? small : (char *)malloc(STR_LEN(name) * 3 + 1);
	hx_str_utf8_into(name, buf);
	int32_t f = intern(buf);
	if (buf != small) free(buf);
	return f;
}

static const char *fid_name(int32_t f) {
	return f < rt_nfield_names ? rt_field_names[f] : extra_name(f - rt_nfield_names);
}

static void *fid_str(int32_t f) {
	return hx_str_of_utf8(fid_name(f), (int32_t)strlen(fid_name(f)));
}

// ---- lookups

static const rt_field *find_field(const rt_type *t, int32_t fid) {
	int lo = 0, hi = (int)t->nfields - 1;
	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		if (t->fields[mid].fid == fid) return &t->fields[mid];
		if (t->fields[mid].fid < fid) lo = mid + 1;
		else hi = mid - 1;
	}
	return 0;
}

static const rt_method *find_method(const rt_type *t, int32_t fid) {
	int lo = 0, hi = (int)t->nmethods - 1;
	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		if (t->methods[mid].fid == fid) return &t->methods[mid];
		if (t->methods[mid].fid < fid) lo = mid + 1;
		else hi = mid - 1;
	}
	return 0;
}

static void icache_fill(void *o, int32_t fid, rt_icache *c) {
	uint32_t t = TINDEX(o);
	const rt_type *ty = &rt_types[t];
	c->fn = 0;
	c->sig = -1;
	const rt_field *f = find_field(ty, fid);
	if (f) {
		c->slot = f->slot + 1;
		c->kind = f->kind;
	} else {
		const rt_method *m = find_method(ty, fid);
		if (m) {
			c->slot = 0;
			c->fn = m->fn;
			c->sig = m->sig;
			c->kind = 'm';
		} else {
			c->slot = -1;
			c->kind = 0;
		}
	}
}

#if RT_MT
// Misses on entries filled for another type, with several threads: per
// thread, a table of immutable entries by (type, field id). A generated
// access may read its entry after evaluating arguments that miss again, so
// an entry, once returned, never changes.
typedef struct {
	uint64_t *keys; // type << 32 | fid, 0: free
	rt_icache **vals;
	uint32_t cap, n;
} ic_table;
static RT_TLS ic_table ic_local;

static rt_icache *ic_local_get(void *o, int32_t fid) {
	ic_table *tb = &ic_local;
	uint64_t key = (uint64_t)TINDEX(o) << 32 | (uint32_t)fid;
	if (tb->n * 2 >= tb->cap) {
		uint32_t ncap = tb->cap ? tb->cap * 2 : 256;
		uint64_t *nk = (uint64_t *)calloc(ncap, sizeof(uint64_t));
		rt_icache **nv = (rt_icache **)calloc(ncap, sizeof(rt_icache *));
		for (uint32_t i = 0; i < tb->cap; i++)
			if (tb->keys[i]) {
				uint32_t j = (uint32_t)((tb->keys[i] * 0x9E3779B97F4A7C15ull) >> 32) & (ncap - 1);
				while (nk[j]) j = (j + 1) & (ncap - 1);
				nk[j] = tb->keys[i];
				nv[j] = tb->vals[i];
			}
		free(tb->keys);
		free(tb->vals);
		tb->keys = nk;
		tb->vals = nv;
		tb->cap = ncap;
	}
	uint32_t j = (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> 32) & (tb->cap - 1);
	while (tb->keys[j]) {
		if (tb->keys[j] == key) return tb->vals[j];
		j = (j + 1) & (tb->cap - 1);
	}
	rt_icache *e = (rt_icache *)malloc(sizeof(rt_icache));
	icache_fill(o, fid, e);
	e->t = TINDEX(o);
	tb->keys[j] = key;
	tb->vals[j] = e;
	tb->n++;
	return e;
}
#endif

void rt_dyn_thread_exit(void) {
#if RT_MT
	ic_table *tb = &ic_local;
	for (uint32_t i = 0; i < tb->cap; i++)
		if (tb->keys[i]) free(tb->vals[i]);
	free(tb->keys);
	free(tb->vals);
	memset(tb, 0, sizeof *tb);
#endif
}

rt_icache *rt_icache_miss(void *o, int32_t fid, rt_icache *c) {
#if RT_MT
	if (rt_mt) {
		uint32_t z = 0;
		if (__atomic_compare_exchange_n(&c->t, &z, RT_IC_BUSY, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
			icache_fill(o, fid, c);
			__atomic_store_n(&c->t, TINDEX(o), __ATOMIC_RELEASE);
			return c;
		}
		return ic_local_get(o, fid);
	}
#endif
	icache_fill(o, fid, c);
	c->t = TINDEX(o);
	return c;
}

static void *box_slot(void *o, int32_t slot, char kind) {
	switch (kind) {
	case 'i': return hx_box_int(FH(o, slot));
	case 'b': return hx_box_bool(FH(o, slot));
	case 'f': return hx_box_float(FD(o, slot));
	default: return FP(o, slot);
	}
}

static void store_slot(void *o, int32_t slot, char kind, void *v) {
	switch (kind) {
	case 'i': FH(o, slot) = hx_unbox_int(v); break;
	case 'b': FH(o, slot) = hx_unbox_bool(v); break;
	case 'f': FD(o, slot) = hx_unbox_float(v); break;
	default: rt_set_ptr(o, &FP(o, slot), v);
	}
}

// a closure over `o` calling method m
static void *bound_method(void *o, const rt_method *m) {
	RT_ROOT(o);
	void *c = rt_alloc(3, rt_bound_types[m->sig], K_OBJ);
	RT_RELOAD(o);
	RT_UNROOT(1);
	FP(c, 0) = rt_bound_tramps[m->sig];
	rt_set_ptr(c, &FP(c, 1), o);
	FP(c, 2) = m->fn;
	return c;
}

// dynamic fields of anonymous objects: slot 0 holds (name id box, value) pairs
static void *overflow_get(void *o, int32_t fid, int *found) {
	*found = 0;
	if (rt_types[TINDEX(o)].tk != TK_ANON) return 0;
	void *ov = FP(o, 0);
	if (!ov) return 0;
	for (uint32_t i = 0; i + 1 < NSLOTS(ov); i += 2)
		if (FP(ov, i) && hx_unbox_int(FP(ov, i)) == fid) {
			*found = 1;
			return FP(ov, i + 1);
		}
	return 0;
}

static void overflow_set(void *o, int32_t fid, void *v) {
	if (rt_types[TINDEX(o)].tk != TK_ANON) hx_throw_str("Cannot add a field to this object");
	void *ov = FP(o, 0);
	if (ov)
		for (uint32_t i = 0; i + 1 < NSLOTS(ov); i += 2)
			if (FP(ov, i) && hx_unbox_int(FP(ov, i)) == fid) {
				rt_set_ptr(ov, &FP(ov, i + 1), v);
				return;
			}
	uint32_t n = ov ? NSLOTS(ov) : 0;
	RT_ROOT(o);
	RT_ROOT(v);
	void *key = hx_box_int(fid);
	RT_ROOT(key);
	void *nv = rt_alloc(n + 2, T_OVERFLOW, K_PARR);
	RT_RELOAD(o);
	RT_RELOAD(v);
	RT_RELOAD(key);
	RT_UNROOT(3);
	ov = FP(o, 0);
	for (uint32_t i = 0; i < n; i++)
		rt_set_ptr(nv, &FP(nv, i), FP(ov, i));
	rt_set_ptr(nv, &FP(nv, n), key);
	rt_set_ptr(nv, &FP(nv, n + 1), v);
	rt_set_ptr(o, &FP(o, 0), nv);
}

// built-in fields of runtime types reached structurally (untyped code)
static int32_t fid_length = -1;
static int is_length(int32_t fid) {
	if (fid_length < 0) fid_length = hx_fid_c("length");
	return fid == fid_length;
}

void Array_resize(void *a, int32_t len);

// statics of a class reached through its class value (Class<T> as Dynamic)
static const rt_static *find_static(void *o, int32_t fid) {
	if (TINDEX(o) != T_TYPEOBJ) return 0;
	const rt_type *t = &rt_types[FI(o, 0)];
	uint32_t lo = 0, hi = t->nstatics;
	while (lo < hi) {
		uint32_t mid = (lo + hi) / 2;
		int32_t f = t->statics[mid].fid;
		if (f == fid) return &t->statics[mid];
		if (f < fid) lo = mid + 1;
		else hi = mid;
	}
	return 0;
}

static void *static_get(const rt_static *s) {
	switch (s->kind) {
	case 'c': {
		void *c = rt_alloc(1, s->idx, K_OBJ);
		FP(c, 0) = s->ptr;
		return c;
	}
	case 'p': return rt_globals[s->idx];
	case 'i': return hx_box_int(*(int32_t *)s->ptr);
	case 'b': return hx_box_bool(*(int32_t *)s->ptr);
	case 'f': return hx_box_float(*(double *)s->ptr);
	}
	return 0;
}

static void static_set(const rt_static *s, void *v) {
	switch (s->kind) {
	case 'c': hx_throw_str("Cannot rebind this method");
	case 'p': rt_globals[s->idx] = v; break;
	case 'i': *(int32_t *)s->ptr = hx_unbox_int(v); break;
	case 'b': *(int32_t *)s->ptr = hx_unbox_bool(v); break;
	case 'f': *(double *)s->ptr = hx_unbox_float(v); break;
	}
}

void *hx_anon_get_slow(void *o, int32_t fid) {
	if (!o) hx_throw_str("Null access");
	const rt_static *st = find_static(o, fid);
	if (st) return static_get(st);
	if (TINDEX(o) == T_STRING && is_length(fid)) return hx_box_int(STR_LEN(o));
	if (TINDEX(o) == T_ARRAY && is_length(fid)) return hx_box_int(ARR_LEN(o));
	const rt_type *ty = &rt_types[TINDEX(o)];
	const rt_field *f = find_field(ty, fid);
	if (f) return box_slot(o, f->slot, f->kind);
	const rt_method *m = find_method(ty, fid);
	if (m) return bound_method(o, m);
	int found;
	return overflow_get(o, fid, &found);
}

void hx_anon_set_slow(void *o, int32_t fid, void *v) {
	if (!o) hx_throw_str("Null access");
	if (TINDEX(o) == T_ARRAY && is_length(fid)) {
		Array_resize(o, hx_unbox_int(v)); // haxe.ds.Vector's generic constructor
		return;
	}
	const rt_static *st = find_static(o, fid);
	if (st) {
		static_set(st, v);
		return;
	}
	const rt_field *f = find_field(&rt_types[TINDEX(o)], fid);
	if (f) store_slot(o, f->slot, f->kind, v);
	else overflow_set(o, fid, v);
}

static int32_t closure_sig(void *c) {
	if (!c || TINDEX(c) < T_FIRST) return -1;
	const rt_type *t = &rt_types[TINDEX(c)];
	return t->tk == TK_CLOSURE || t->tk == TK_BOUND ? t->super : -1;
}

// calls a closure with boxed arguments (an Array's data, n elements)
static void *call_boxed(void *f, void **args, int32_t n) {
	int32_t s = closure_sig(f);
	if (s < 0) hx_throw_str("Cannot call a non-function");
	// the signature key gives the argument count: chars before '_'
	const char *k = rt_sig_keys[s];
	int32_t want = (int32_t)(strchr(k, '_') - k);
	void *buf[16];
	for (int32_t i = 0; i < want && i < 16; i++)
		buf[i] = i < n ? args[i] : 0;
	return rt_dyncalls[s](f, buf);
}

static uint64_t from_boxed(void *v, char k) {
	switch (k) {
	case 'i':
	case 'b': return (uint64_t)(uint32_t)hx_unbox_int(v);
	case 'f': {
		double d = hx_unbox_float(v);
		uint64_t u;
		memcpy(&u, &d, 8);
		return u;
	}
	case 'v': return 0;
	default: return (uint64_t)(uintptr_t)v;
	}
}

int32_t hx_arrayiter_hasNext(void *it) { return FI(it, 1) < ARR_LEN(FP(it, 0)); }

void *hx_arrayiter_next(void *it) {
	int32_t i = FI(it, 1);
	FI(it, 1) = i + 1;
	return hx_aget_p_slow(FP(it, 0), i);
}

static void *array_iterator(void *a) {
	RT_ROOT(a);
	void *it = rt_alloc(2, T_ARRAYITER, K_OBJ);
	RT_RELOAD(a);
	RT_UNROOT(1);
	FP(it, 0) = a; // it is young
	return it;
}

static int call_builtin(void *o, const char *nm, int32_t n, void **slots, void **res);

uint64_t hx_anon_call_slow(void *o, int32_t fid, int32_t sig, uint64_t *args) {
	const char *k = rt_sig_keys[sig];
	int32_t n = (int32_t)(strchr(k, '_') - k);
	char rk = strchr(k, '_')[1];
	RT_ROOT(o);
	// box the arguments into rooted slots
	void **slots = rt_sp;
	rt_sp += n;
	for (int32_t i = 0; i < n; i++)
		slots[i] = 0;
	for (int32_t i = 0; i < n; i++) {
		void *b;
		switch (k[i]) {
		case 'i': b = hx_box_int((int32_t)args[i]); break;
		case 'b': b = hx_box_bool((int32_t)args[i]); break;
		case 'f': {
			double d;
			memcpy(&d, &args[i], 8);
			b = hx_box_float(d);
			break;
		}
		default: b = (void *)(uintptr_t)args[i];
		}
		slots[i] = b;
	}
	RT_RELOAD(o);
	void *r;
	if (!(o && call_builtin(o, fid_name(fid), n, slots, &r))) {
		void *f = hx_anon_get_slow(o, fid);
		r = call_boxed(f, slots, n);
	}
	rt_sp = slots;
	RT_UNROOT(1);
	return from_boxed(r, rk);
}

// ---- Dynamic access

void *hx_dyn_get(void *o, void *name) {
	if (!o) hx_throw_str("Null access");
	uint32_t t = TINDEX(o);
	char nm[64];
	if (STR_LEN(name) == 6) {
		hx_str_utf8_into(name, nm);
		if (strcmp(nm, "length") == 0) {
			if (t == T_STRING) return hx_box_int(STR_LEN(o));
			if (t == T_ARRAY) return hx_box_int(ARR_LEN(o));
		}
	}
	RT_ROOT(o);
	int32_t f = hx_fid(name);
	RT_RELOAD(o);
	RT_UNROOT(1);
	return hx_anon_get_slow(o, f);
}

void hx_dyn_set(void *o, void *name, void *v) {
	RT_ROOT(o);
	RT_ROOT(v);
	int32_t f = hx_fid(name);
	RT_RELOAD(o);
	RT_RELOAD(v);
	RT_UNROOT(2);
	hx_anon_set_slow(o, f, v);
}

void *hx_dyn_call(void *f, void *args) {
	if (!args) return call_boxed(f, 0, 0);
	RT_ROOT(f);
	RT_ROOT(args);
	if (ARR_KIND(args) != AK_PTR) hx_arr_to_ptr(args_root);
	RT_RELOAD(f);
	RT_RELOAD(args);
	RT_UNROOT(2);
	// the array data may move during boxing inside the callee: copy into rooted slots
	int32_t n = ARR_LEN(args);
	void **slots = rt_sp;
	rt_sp += n;
	for (int32_t i = 0; i < n; i++)
		slots[i] = FP(ARR_DATA(args), i);
	void *r = call_boxed(f, slots, n);
	rt_sp = slots;
	return r;
}

// methods of the runtime's built-in types called through Dynamic
void *Array_copy(void *a);
void *Array_concat(void *a, void *b);
int32_t Array_indexOf(void *a, void *x, void *from);
int32_t Array_lastIndexOf(void *a, void *x, void *from);
int32_t Array_contains(void *a, void *x);
int32_t Array_remove(void *a, void *x);
void *Array_pop(void *a);
void *Array_shift(void *a);
void Array_insert(void *a, int32_t pos, void *x);
void Array_unshift(void *a, void *x);
void Array_reverse(void *a);
void *Array_slice(void *a, int32_t pos, void *endp);
void *Array_splice(void *a, int32_t pos, int32_t len);
void *Array_join(void *a, void *sep);
void *Array_toString(void *a);
void Array_sort(void *a, void *f);
void *Array_filter(void *a, void *f);
void *Array_map(void *a, void *f);
void *String_charAt(void *s, int32_t i);
void *String_charCodeAt(void *s, int32_t i);
int32_t String_indexOf(void *s, void *sub, void *start);
int32_t String_lastIndexOf(void *s, void *sub, void *start);
void *String_substr(void *s, int32_t pos, void *lenp);
void *String_substring(void *s, int32_t start, void *endp);
void *String_toLowerCase(void *s);
void *String_toUpperCase(void *s);
void *String_split(void *s, void *delim);

static int call_builtin(void *o, const char *nm, int32_t n, void **slots, void **res) {
	uint32_t t = TINDEX(o);
	if (t != T_ARRAY && t != T_STRING) return 0;
	void *a0 = n > 0 ? slots[0] : 0, *a1 = n > 1 ? slots[1] : 0;
#define IS(s) (strcmp(nm, s) == 0)
	if (t == T_STRING) {
		if (IS("charAt")) *res = String_charAt(o, hx_unbox_int(a0));
		else if (IS("charCodeAt")) *res = String_charCodeAt(o, hx_unbox_int(a0));
		else if (IS("indexOf")) *res = hx_box_int(String_indexOf(o, a0, a1));
		else if (IS("lastIndexOf")) *res = hx_box_int(String_lastIndexOf(o, a0, a1));
		else if (IS("substr")) *res = String_substr(o, hx_unbox_int(a0), a1);
		else if (IS("substring")) *res = String_substring(o, hx_unbox_int(a0), a1);
		else if (IS("toLowerCase")) *res = String_toLowerCase(o);
		else if (IS("toUpperCase")) *res = String_toUpperCase(o);
		else if (IS("toString")) *res = o;
		else if (IS("split")) *res = String_split(o, a0);
		else return 0;
		return 1;
	}
	*res = 0;
	if (IS("join")) *res = Array_join(o, a0);
	else if (IS("push")) {
		RT_ROOT(o);
		hx_apush_slow(o_root, AK_PTR, (uint64_t)(uintptr_t)&slots[0]);
		RT_RELOAD(o);
		RT_UNROOT(1);
		*res = hx_box_int(ARR_LEN(o));
	} else if (IS("pop")) *res = Array_pop(o);
	else if (IS("shift")) *res = Array_shift(o);
	else if (IS("copy")) *res = Array_copy(o);
	else if (IS("concat")) *res = Array_concat(o, a0);
	else if (IS("indexOf")) *res = hx_box_int(Array_indexOf(o, a0, a1));
	else if (IS("lastIndexOf")) *res = hx_box_int(Array_lastIndexOf(o, a0, a1));
	else if (IS("contains")) *res = hx_box_bool(Array_contains(o, a0));
	else if (IS("remove")) *res = hx_box_bool(Array_remove(o, a0));
	else if (IS("insert")) Array_insert(o, hx_unbox_int(a0), a1);
	else if (IS("unshift")) Array_unshift(o, a0);
	else if (IS("reverse")) Array_reverse(o);
	else if (IS("slice")) *res = Array_slice(o, hx_unbox_int(a0), a1);
	else if (IS("splice")) *res = Array_splice(o, hx_unbox_int(a0), hx_unbox_int(a1));
	else if (IS("toString")) *res = Array_toString(o);
	else if (IS("sort")) Array_sort(o, a0);
	else if (IS("filter")) *res = Array_filter(o, a0);
	else if (IS("map")) *res = Array_map(o, a0);
	else if (IS("iterator")) *res = array_iterator(o);
	else return 0;
#undef IS
	return 1;
}

// a method of a built-in value (Array, String) called through Dynamic
static int call_field_builtin(void *o, const char *nm, void *args, void **res) {
	int32_t n = args ? ARR_LEN(args) : 0;
	RT_ROOT(o);
	RT_ROOT(args);
	// the arguments boxed into rooted slots
	void **slots = rt_sp;
	rt_sp += n;
	for (int32_t i = 0; i < n; i++)
		slots[i] = 0;
	for (int32_t i = 0; i < n; i++) {
		void *v = hx_aget_p_slow(*args_root, i);
		slots[i] = v;
	}
	int ok = call_builtin(*o_root, nm, n, slots, res);
	rt_sp = slots;
	RT_UNROOT(2);
	return ok;
}

void *hx_dyn_call_field(void *o, void *name, void *args) {
	uint32_t t = o ? TINDEX(o) : 0;
	if ((t == T_ARRAY || t == T_STRING) && STR_LEN(name) < 30) {
		char nm[128];
		nm[hx_str_utf8_into(name, nm)] = 0;
		void *r;
		RT_ROOT(o);
		RT_ROOT(args);
		int ok = call_field_builtin(o, nm, args, &r);
		RT_RELOAD(o);
		RT_RELOAD(args);
		RT_UNROOT(2);
		if (ok) return r;
	}
	RT_ROOT(args);
	void *f = hx_dyn_get(o, name);
	RT_RELOAD(args);
	RT_UNROOT(1);
	return hx_dyn_call(f, args);
}

// by field id (a literal name: no interning at run time)
void *hx_dyn_get_fid(void *o, int32_t fid) {
	return hx_anon_get_slow(o, fid);
}

void hx_dyn_set_fid(void *o, int32_t fid, void *v) {
	hx_anon_set_slow(o, fid, v);
}

void *hx_dyn_call_field_fid(void *o, int32_t fid, void *args) {
	uint32_t t = o ? TINDEX(o) : 0;
	if (t == T_ARRAY || t == T_STRING) {
		void *r;
		RT_ROOT(o);
		RT_ROOT(args);
		int ok = call_field_builtin(o, fid_name(fid), args, &r);
		RT_RELOAD(o);
		RT_RELOAD(args);
		RT_UNROOT(2);
		if (ok) return r;
	}
	RT_ROOT(args);
	void *f = hx_anon_get_slow(o, fid);
	RT_RELOAD(args);
	RT_UNROOT(1);
	return hx_dyn_call(f, args);
}

void *hx_dyn_aget(void *a, int32_t i) {
	if (!a || TINDEX(a) != T_ARRAY) return 0;
	return hx_aget_p_slow(a, i);
}

void hx_dyn_aset(void *a, int32_t i, void *v) {
	if (!a || TINDEX(a) != T_ARRAY) hx_throw_str("Invalid array access");
	*rt_sp++ = a;
	*rt_sp++ = v;
	hx_aset_slow(rt_sp - 2, i, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
	rt_sp -= 2;
}

static int is_num(void *v) {
	return v && (TINDEX(v) == T_BOXINT || TINDEX(v) == T_BOXFLOAT);
}

int hx_dyn_eq(void *a, void *b) {
	if (a == b) return 1;
	if (!a || !b) return 0;
	uint32_t ta = TINDEX(a), tb = TINDEX(b);
	if (is_num(a) && is_num(b)) return hx_unbox_float(a) == hx_unbox_float(b);
	if (ta == T_BOXBOOL && tb == T_BOXBOOL) return FI(a, 0) == FI(b, 0);
	if (ta == T_STRING && tb == T_STRING) return hx_str_eq(a, b);
	if (ta == T_TYPEOBJ && tb == T_TYPEOBJ) return FI(a, 0) == FI(b, 0);
	return 0;
}

int32_t hx_dyn_cmp(void *a, void *b) {
	if (is_num(a) && is_num(b)) {
		double x = hx_unbox_float(a), y = hx_unbox_float(b);
		return x < y ? -1 : x > y ? 1 : 0;
	}
	if (a && b && TINDEX(a) == T_STRING && TINDEX(b) == T_STRING) return hx_str_cmp(a, b);
	if (a == b) return 0;
	return a == 0 ? -1 : 1;
}

int32_t hxc_Native_compare(void *a, void *b) {
	return hx_dyn_cmp(a, b);
}

void *hx_dyn_op(int32_t op, void *a, void *b) {
	if (op == 0 && ((a && TINDEX(a) == T_STRING) || (b && TINDEX(b) == T_STRING))) {
		RT_ROOT(b);
		void *sa = hx_std_string(a);
		RT_RELOAD(b);
		RT_ROOT(sa);
		void *sb = hx_std_string(b);
		RT_RELOAD(sa);
		RT_UNROOT(2);
		return hx_str_concat(sa, sb);
	}
	int ints = a && b && TINDEX(a) != T_BOXFLOAT && TINDEX(b) != T_BOXFLOAT;
	if (op >= 5 || (ints && op != 3)) {
		int32_t x = hx_unbox_int(a), y = hx_unbox_int(b), r = 0;
		switch (op) {
		case 0: r = IADD(x, y); break;
		case 1: r = ISUB(x, y); break;
		case 2: r = IMUL(x, y); break;
		case 4: r = IMOD(x, y); break;
		case 5: r = x & y; break;
		case 6: r = x | y; break;
		case 7: r = x ^ y; break;
		case 8: r = ISHL(x, y); break;
		case 9: r = ISHR(x, y); break;
		case 10: r = IUSHR(x, y); break;
		}
		return hx_box_int(r);
	}
	double x = hx_unbox_float(a), y = hx_unbox_float(b), r = 0;
	switch (op) {
	case 0: r = x + y; break;
	case 1: r = x - y; break;
	case 2: r = x * y; break;
	case 3: r = x / y; break;
	case 4: r = fmod(x, y); break;
	}
	return hx_box_float(r);
}

// ---- type tests

static int class_extends(int32_t t, int32_t c) {
	while (t >= 0) {
		if (t == c) return 1;
		t = rt_types[t].super;
	}
	return 0;
}

static int implements(int32_t t, int32_t i) {
	const rt_type *ty = &rt_types[t];
	for (uint32_t k = 0; k < ty->nifaces; k++)
		if (ty->ifaces[k] == i) return 1;
	return 0;
}

int hx_is(void *v, void *type) {
	if (!v || !type) return 0;
	int32_t c = FI(type, 0);
	uint32_t t = TINDEX(v);
	switch (c) {
	case T_NONE: return 1; // Dynamic
	case T_BOXINT: return t == T_BOXINT || (t == T_BOXFLOAT && FD(v, 0) == floor(FD(v, 0)) && fabs(FD(v, 0)) < 2147483648.0);
	case T_BOXFLOAT: return t == T_BOXINT || t == T_BOXFLOAT;
	case T_BOXBOOL: return t == T_BOXBOOL;
	case T_STRING: return t == T_STRING;
	case T_ARRAY: return t == T_ARRAY;
	case T_BYTES: return t == T_BYTES;
	}
	if ((uint32_t)c >= T_FIRST) {
		const rt_type *ct = &rt_types[c];
		if (ct->tk == TK_CLASS) return t >= T_FIRST && rt_types[t].tk == TK_CLASS && class_extends(t, c);
		if (ct->tk == TK_INTERFACE) return t >= T_FIRST && rt_types[t].tk == TK_CLASS && implements(t, c);
		if (ct->tk == TK_ENUM) return t >= T_FIRST && rt_types[t].tk == TK_CTOR && rt_types[t].super == c;
	}
	return 0;
}

void *hx_cast(void *v, void *type) {
	if (!v || hx_is(v, type)) return v;
	hx_throw_str("Class cast error");
}

// ---- hxc.Native

// identity hash in the header's top 16 bits, set once (a CAS: another thread
// may set it at the same time; the collector only runs with every thread stopped)
static RT_TLS uint32_t hash_seed;
int32_t hxc_NativeThread_current(void);
int32_t hxc_Native_objHash(void *o) {
	if (!o) return 0;
	uint32_t h = (uint32_t)(HDR(o) >> 48);
	if (h == 0) {
		if (hash_seed == 0) hash_seed = 0x9E37 + 0x10000u * (uint32_t)(hxc_NativeThread_current() - 1); // the main thread's sequence is the single-threaded one
		hash_seed = hash_seed * 1103515245u + 12345u;
		h = (hash_seed >> 16) & 0xFFFF;
		if (h == 0) h = 1;
#if RT_MT
		uint64_t old = __atomic_load_n(&HDR(o), __ATOMIC_RELAXED);
		while ((old >> 48) == 0 && !__atomic_compare_exchange_n(&HDR(o), &old, old | (uint64_t)h << 48, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
		h = (uint32_t)(old >> 48) ? (uint32_t)(old >> 48) : h;
#else
		HDR(o) |= (uint64_t)h << 48;
#endif
	}
	return (int32_t)(h * 2654435761u);
}

int32_t hxc_Native_refEq(void *a, void *b) {
	return a == b;
}

int32_t hxc_Native_typeKind(void *v) {
	if (!v) return 0;
	uint32_t t = TINDEX(v);
	switch (t) {
	case T_BOXINT: return 1;
	case T_BOXFLOAT: return 2;
	case T_BOXBOOL: return 3;
	case T_STRING: return 8;
	case T_ARRAY: return 9;
	case T_TYPEOBJ: return 10;
	}
	if (t < T_FIRST) return 11;
	switch (rt_types[t].tk) {
	case TK_ANON: return 4;
	case TK_CLOSURE:
	case TK_BOUND: return 5;
	case TK_CLASS: return 6;
	case TK_CTOR: return 7;
	default: return 11;
	}
}

void *hxc_Native_getClass(void *v) {
	if (!v) return 0;
	uint32_t t = TINDEX(v);
	if (t == T_STRING || t == T_ARRAY) return TYPE_OBJ(t);
	if (t >= T_FIRST && rt_types[t].tk == TK_CLASS) return TYPE_OBJ(t);
	return 0;
}

void *hxc_Native_getEnum(void *v) {
	if (!v) return 0;
	uint32_t t = TINDEX(v);
	if (t >= T_FIRST && rt_types[t].tk == TK_CTOR) return TYPE_OBJ(rt_types[t].super);
	return 0;
}

void *hxc_Native_superClass(void *c) {
	int32_t s = rt_types[FI(c, 0)].super;
	return s >= 0 && rt_types[FI(c, 0)].tk == TK_CLASS ? TYPE_OBJ(s) : 0;
}

void *hxc_Native_typeName(void *t) {
	return hx_str_of_ascii(rt_types[FI(t, 0)].name);
}

void *hxc_Native_resolveType(void *name) {
	char *n = hx_str_to_utf8(name);
	for (int t = T_FIRST; t < rt_ntypes; t++)
		if ((rt_types[t].tk == TK_CLASS || rt_types[t].tk == TK_ENUM) && strcmp(rt_types[t].name, n) == 0) {
			free(n);
			return TYPE_OBJ(t);
		}
	int isString = strcmp(n, "String") == 0;
	free(n);
	return isString ? TYPE_OBJ(T_STRING) : 0;
}

void *hxc_Native_createEmpty(void *c) {
	int32_t t = FI(c, 0);
	uint32_t n = rt_types[t].nslots;
	return rt_alloc(n ? n : 1, t, K_OBJ);
}

void *hxc_Native_enumCtorNames(void *e) {
	int32_t t = FI(e, 0);
	if (rt_types[t].tk != TK_ENUM) return 0;
	int32_t n = rt_types[t].tag;
	void *a = hx_arr_new(AK_PTR, 0);
	RT_ROOT(a);
	for (int32_t i = 0; i < n; i++) {
		void *s = hx_str_of_ascii(rt_types[rt_types[t].ctors[i]].name);
		*rt_sp++ = s;
		hx_apush_slow(a_root, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
		rt_sp--;
	}
	RT_RELOAD(a);
	RT_UNROOT(1);
	return a;
}

// the position of an enum constructor's argument (its slot: no packing)
static int32_t ctor_arg(const rt_field *f) {
	return f->kind == 'i' || f->kind == 'b' ? f->slot / 2 : f->slot;
}

void *hxc_Native_enumCreate(void *e, int32_t index, void *params) {
	int32_t t = FI(e, 0);
	if (rt_types[t].tk != TK_ENUM || index < 0 || index >= rt_types[t].tag) hx_throw_str("Invalid enum constructor");
	int32_t ct = rt_types[t].ctors[index];
	const rt_type *cty = &rt_types[ct];
	RT_ROOT(params);
	void *o = rt_alloc(cty->nslots ? cty->nslots : 1, ct, K_OBJ);
	RT_RELOAD(params);
	RT_UNROOT(1);
	for (uint32_t i = 0; i < cty->nfields; i++) {
		const rt_field *f = &cty->fields[i];
		void *v = params ? hx_aget_p_slow(params, ctor_arg(f)) : 0;
		store_slot(o, f->slot, f->kind, v);
	}
	return o;
}

int32_t hxc_Native_enumIndex(void *v) {
	return rt_types[TINDEX(v)].tag;
}

void *hxc_Native_enumCtorName(void *v) {
	return hx_str_of_ascii(rt_types[TINDEX(v)].name);
}

void *hxc_Native_enumParams(void *v) {
	const rt_type *ty = &rt_types[TINDEX(v)];
	uint32_t n = ty->nslots;
	RT_ROOT(v);
	void *a = hx_arr_new(AK_PTR, n);
	RT_ROOT(a);
	for (uint32_t i = 0; i < ty->nfields; i++) {
		const rt_field *f = &ty->fields[i];
		RT_RELOAD(v);
		void *b = box_slot(v, f->slot, f->kind);
		RT_RELOAD(a);
		rt_set_ptr(ARR_DATA(a), &FP(ARR_DATA(a), ctor_arg(f)), b);
	}
	RT_RELOAD(a);
	RT_UNROOT(2);
	return a;
}

int32_t hxc_Native_enumEq(void *a, void *b) {
	if (a == b) return 1;
	if (!a || !b || TINDEX(a) != TINDEX(b)) return 0;
	const rt_type *ty = &rt_types[TINDEX(a)];
	if (ty->tk != TK_CTOR) return 0;
	for (uint32_t i = 0; i < ty->nfields; i++) {
		const rt_field *f = &ty->fields[i];
		switch (f->kind) {
		case 'i':
		case 'b':
			if (FH(a, f->slot) != FH(b, f->slot)) return 0;
			break;
		case 'f':
			if (FD(a, f->slot) != FD(b, f->slot)) return 0;
			break;
		default: {
			void *x = FP(a, f->slot), *y = FP(b, f->slot);
			if (x == y) break;
			if (x && y && TINDEX(x) >= T_FIRST && rt_types[TINDEX(x)].tk == TK_CTOR) {
				if (!hxc_Native_enumEq(x, y)) return 0;
			} else if (!hx_dyn_eq(x, y)) return 0;
		}
		}
	}
	return 1;
}

static void *names_array(const rt_type *ty, int with_methods) {
	void *a = hx_arr_new(AK_PTR, 0);
	RT_ROOT(a);
	for (uint32_t i = 0; i < ty->nfields; i++) {
		void *s = fid_str(ty->fields[i].fid);
		*rt_sp++ = s;
		hx_apush_slow(a_root, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
		rt_sp--;
	}
	if (with_methods)
		for (uint32_t i = 0; i < ty->nmethods; i++) {
			void *s = fid_str(ty->methods[i].fid);
			*rt_sp++ = s;
			hx_apush_slow(a_root, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
			rt_sp--;
		}
	RT_RELOAD(a);
	RT_UNROOT(1);
	return a;
}

void *hxc_Native_instanceFields(void *c) {
	return names_array(&rt_types[FI(c, 0)], 1);
}

void *hxc_Native_fields(void *o) {
	if (!o || TINDEX(o) < T_FIRST) return hx_arr_new(AK_PTR, 0);
	const rt_type *ty = &rt_types[TINDEX(o)];
	RT_ROOT(o);
	void *a = names_array(ty, 0);
	RT_ROOT(a);
	RT_RELOAD(o);
	if (ty->tk == TK_ANON && FP(o, 0)) {
		void *ov = FP(o, 0);
		for (uint32_t i = 0; i + 1 < NSLOTS(ov); i += 2) {
			RT_RELOAD(o);
			ov = FP(o, 0);
			void *s = fid_str(hx_unbox_int(FP(ov, i)));
			*rt_sp++ = s;
			hx_apush_slow(a_root, AK_PTR, (uint64_t)(uintptr_t)(rt_sp - 1));
			rt_sp--;
		}
	}
	RT_RELOAD(a);
	RT_UNROOT(2);
	return a;
}

int32_t hxc_Native_hasField(void *o, void *name) {
	if (!o || TINDEX(o) < T_FIRST) return 0;
	RT_ROOT(o);
	int32_t f = hx_fid(name);
	RT_RELOAD(o);
	RT_UNROOT(1);
	if (find_field(&rt_types[TINDEX(o)], f)) return 1;
	int found;
	overflow_get(o, f, &found);
	return found;
}

void *hxc_Native_getField(void *o, void *name) {
	if (!o) return 0;
	if (TINDEX(o) < T_FIRST && TINDEX(o) != T_STRING && TINDEX(o) != T_ARRAY) return 0;
	return hx_dyn_get(o, name);
}

void hxc_Native_setField(void *o, void *name, void *v) {
	hx_dyn_set(o, name, v);
}

int32_t hxc_Native_deleteField(void *o, void *name) {
	if (!o || rt_types[TINDEX(o)].tk != TK_ANON || !FP(o, 0)) return 0;
	RT_ROOT(o);
	int32_t f = hx_fid(name);
	RT_RELOAD(o);
	RT_UNROOT(1);
	void *ov = FP(o, 0);
	for (uint32_t i = 0; i + 1 < NSLOTS(ov); i += 2)
		if (FP(ov, i) && hx_unbox_int(FP(ov, i)) == f) {
			FP(ov, i) = 0;
			FP(ov, i + 1) = 0;
			return 1;
		}
	return 0;
}

void *hxc_Native_callMethod(void *f, void *args) {
	return hx_dyn_call(f, args);
}

int32_t hxc_Native_compareMethods(void *a, void *b) {
	if (a == b) return 1;
	if (!a || !b || TINDEX(a) != TINDEX(b)) return 0;
	if (rt_types[TINDEX(a)].tk == TK_BOUND) return FP(a, 1) == FP(b, 1) && FP(a, 2) == FP(b, 2);
	return 0;
}

void *hxc_Native_copyObject(void *o) {
	if (!o || TINDEX(o) < T_FIRST) return o;
	uint32_t n = NSLOTS(o);
	RT_ROOT(o);
	void *c = rt_alloc(n, TINDEX(o), KIND(o));
	RT_RELOAD(o);
	memcpy(c, o, 8 * (size_t)n);
	// an anonymous object's dynamic fields (slot 0) are its own
	if (rt_types[TINDEX(o)].tk == TK_ANON && FP(o, 0)) {
		RT_ROOT(c);
		void *ov = FP(o, 0);
		void *nv = rt_alloc(NSLOTS(ov), T_OVERFLOW, K_PARR);
		RT_RELOAD(o);
		RT_RELOAD(c);
		RT_UNROOT(1);
		ov = FP(o, 0);
		memcpy(nv, ov, 8 * (size_t)NSLOTS(ov));
		rt_barrier_range(nv, (void **)nv, NSLOTS(ov));
		FP(c, 0) = nv;
	}
	RT_UNROOT(1);
	if (KIND(c) == K_PARR) rt_barrier_range(c, (void **)c, n);
	else if (KIND(c) == K_OBJ) {
		const uint64_t *pm = rt_types[TINDEX(c)].ptrmap; // only the reference slots
		for (uint32_t i = 0; pm && i < n; i++)
			if (pm[i / 64] >> (i % 64) & 1) rt_barrier_range(c, &FP(c, i), 1);
	}
	return c;
}

// { a : 1, b : 2 }
void *hx_anon_to_string(void *o) {
	const rt_type *ty = &rt_types[TINDEX(o)];
	extern void *StringBuf_new(void);
	extern void StringBuf_add(void *b, void *x);
	extern void *StringBuf_toString(void *b);
	RT_ROOT(o);
	void *b = StringBuf_new();
	RT_ROOT(b);
	void *s0 = hx_str_of_ascii("{");
	RT_RELOAD(b);
	StringBuf_add(b, s0);
	for (uint32_t i = 0; i < ty->nfields; i++) {
		void *s = hx_str_of_ascii(i == 0 ? " " : ", ");
		RT_RELOAD(b);
		StringBuf_add(b, s);
		s = fid_str(ty->fields[i].fid);
		RT_RELOAD(b);
		StringBuf_add(b, s);
		s = hx_str_of_ascii(" : ");
		RT_RELOAD(b);
		StringBuf_add(b, s);
		RT_RELOAD(o);
		void *v = box_slot(o, ty->fields[i].slot, ty->fields[i].kind);
		RT_RELOAD(b);
		StringBuf_add(b, v);
	}
	void *s1 = hx_str_of_ascii(ty->nfields ? " }" : "}");
	RT_RELOAD(b);
	StringBuf_add(b, s1);
	RT_RELOAD(b);
	RT_UNROOT(2);
	return StringBuf_toString(b);
}
