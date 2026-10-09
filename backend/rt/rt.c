// EXPERIMENTAL runtime for the C output of backend/; see rt.h.
// GC, startup, exceptions, boxes, arrays.
#define _GNU_SOURCE // madvise (cosmocc)
#include "rt_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <sys/mman.h>
#include <unistd.h>

#ifdef __TINYC__ // tcc, for fast development builds: no bit-scan builtin
static inline int __builtin_ctzll(uint64_t m) {
	int i = 0;
	while (!(m & 1)) {
		m >>= 1;
		i++;
	}
	return i;
}
#endif

// Threads (rt_thread.c): each thread allocates in its own chunk of the
// nursery (TLAB: rt_young_ptr/rt_young_limit, taken from young_next) and
// records old-to-young stores in its own remembered set (rt_mutator); a
// collection stops every other thread at a safepoint (an allocation slow
// path) or in a safe region (a blocking native), see rt_world_stop. With one
// thread a TLAB is the whole free nursery, as before threads.
char *rt_young_start, *rt_young_end;
static char *young_next; // free part of the nursery: TLABs are taken from here
RT_TLS char *rt_young_ptr, *rt_young_limit;
static char *old_start, *old_ptr, *old_end;
RT_TLS void **rt_sp;
RT_TLS void **rt_stack_base; // the running thread's shadow stack (green threads swap it)
void **rt_globals;
static int nglobals;
RT_TLS rt_handler *rt_hcur;
RT_TLS void *rt_exn;
RT_TLS rt_mutator *rt_mut;
static size_t tlab_size; // with several threads (RT_TLAB_KB; default a 16th of the nursery)
static size_t minor_size;
static int stats;
static int census; // RT_CENSUS: 1 at exit, 2 also after each major collection
static void census_now(const char *when);
static int release_pages;
static void populate(char *upto);
static unsigned long minors, majors;
static double minor_secs, major_secs; // RT_STATS
#include <time.h>
static double now_secs(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}
int rt_argc;
char **rt_argv;

static inline uint32_t obj_bytes(void *o) { return 8 * (NSLOTS(o) + 1); }

static char *copy_to(char *dst, void *obj) {
	uint32_t words = NSLOTS(obj) + 1;
	uint64_t *s = (uint64_t *)obj - 1, *d = (uint64_t *)dst;
	if (words <= 8) // most objects: a few words, no call
		for (uint32_t i = 0; i < words; i++)
			d[i] = s[i];
	else
		memcpy(dst, s, 8 * (size_t)words);
	return dst + 8;
}

static inline int in_young(void *p) {
	return (char *)p >= rt_young_start && (char *)p < rt_young_end;
}

static inline void forward_to(void *p, void *n) {
	HDR(p) = (HDR(p) & ~((uint64_t)0xF << 28)) | ((uint64_t)K_FWD << 28);
	FP(p, 0) = n;
}

// ---- minor collection: copy live nursery objects to the end of the old space

static void *minor_forward(void *p) {
	if (!in_young(p)) return p;
	if (KIND(p) == K_FWD) return FP(p, 0);
	void *n = copy_to(old_ptr, p);
	old_ptr += obj_bytes(p);
	forward_to(p, n);
	return n;
}

static void scan_object(void *o, void *(*fwd)(void *)) {
	uint32_t n = NSLOTS(o);
	switch (KIND(o)) {
	case K_OBJ: {
		const uint64_t *pm = rt_types[TINDEX(o)].ptrmap;
		if (!pm) break;
		for (uint32_t w = 0; w * 64 < n; w++) {
			uint64_t m = pm[w];
			while (m) {
				int i = w * 64 + __builtin_ctzll(m);
				m &= m - 1;
				if (FP(o, i)) FP(o, i) = fwd(FP(o, i));
			}
		}
		break;
	}
	case K_PARR:
		for (uint32_t i = 0; i < n; i++)
			if (FP(o, i)) FP(o, i) = fwd(FP(o, i));
		break;
	default: break;
	}
}

// ---- finalisers (Gc.finalise in Eval): OCaml's Gc.finalise semantics. A
// finaliser's function is a root; its value is a root of minor collections
// only (they promote it), and a major collection that finds it unreachable
// copies it back (it lives on for the call) and queues the call. Queued calls
// run at the next allocation slow path or rt_gc_run_finalisers, in the
// reverse order of registration for values found dead together.
typedef struct {
	void *fn, *val;
} rt_final;
static rt_final *finals, *final_queue;
static size_t nfinals, finals_cap, final_qhead, final_qlen, final_qcap;
static RT_TLS int finals_running;
static rt_lock_t finals_lock = RT_LOCK_INIT; // registration and dequeuing (the collector runs with every thread stopped)

// ---- native handles: freed once their T_NATIVE object is found unreachable
typedef struct {
	void *obj, *p;
	void (*free_fn)(void *);
} rt_native;
static rt_native *natives;
static size_t nnatives, natives_cap;
static rt_lock_t natives_lock = RT_LOCK_INIT;

void *rt_native_new(void *p, void (*free_fn)(void *)) {
	void *o = rt_alloc(1, T_NATIVE, K_RAW);
	FP(o, 0) = p;
	rt_lock(&natives_lock);
	if (nnatives == natives_cap) {
		natives_cap = natives_cap ? natives_cap * 2 : 256;
		natives = (rt_native *)realloc(natives, natives_cap * sizeof(rt_native));
	}
	natives[nnatives].obj = o;
	natives[nnatives].p = p;
	natives[nnatives++].free_fn = free_fn;
	rt_unlock(&natives_lock);
	return o;
}

// after a collection of the nursery (and of [lo, hi) for a major one)
static void sweep_natives(char *lo, char *hi) {
	size_t live = 0;
	for (size_t i = 0; i < nnatives; i++) {
		void *o = natives[i].obj;
		if (in_young(o) || ((char *)o >= lo && (char *)o < hi)) {
			if (KIND(o) != K_FWD) {
				natives[i].free_fn(natives[i].p);
				continue;
			}
			o = FP(o, 0);
		}
		natives[live] = natives[i];
		natives[live++].obj = o;
	}
	nnatives = live;
}

static void scan_roots(void *(*fwd)(void *)) {
	for (void **s = rt_stack_base; s < rt_sp; s++)
		if (*s) *s = fwd(*s);
	rt_threads_scan(fwd); // the other green threads' shadow stacks
	for (int i = 0; i < nglobals; i++)
		if (rt_globals[i]) rt_globals[i] = fwd(rt_globals[i]);
	if (rt_exn) rt_exn = fwd(rt_exn);
	for (size_t i = 0; i < nfinals; i++)
		finals[i].fn = fwd(finals[i].fn);
	for (size_t i = final_qhead; i < final_qlen; i++) {
		final_queue[i].fn = fwd(final_queue[i].fn);
		final_queue[i].val = fwd(final_queue[i].val);
	}
}

// Depth-first copying: an object's descendants are copied right after it
// (preorder), the order in which the compiler then walks its trees; Cheney's
// breadth-first scan scatters them. RT_BFS=1 selects the breadth-first scan.
typedef struct {
	void *o;
	uint32_t i; // next slot to scan
} gc_frame;
static gc_frame *gc_stack;
static size_t gc_top, gc_cap;
static int gc_bfs;
static void *(*gc_fwd)(void *);

static void gc_push(void *o) {
	if (gc_top == gc_cap) {
		gc_cap = gc_cap ? gc_cap * 2 : 4096;
		gc_stack = (gc_frame *)realloc(gc_stack, gc_cap * sizeof(gc_frame));
	}
	gc_stack[gc_top].o = o;
	gc_stack[gc_top].i = 0;
	gc_top++;
}

static void gc_drain(void) {
	while (gc_top) {
		gc_frame *f = &gc_stack[gc_top - 1];
		void *o = f->o;
		uint32_t n = NSLOTS(o), k = KIND(o);
		const uint64_t *pm = k == K_OBJ ? rt_types[TINDEX(o)].ptrmap : 0;
		if (k == K_RAW || (k == K_OBJ && !pm)) {
			gc_top--;
			continue;
		}
		uint32_t i = f->i;
		for (; i < n; i++) {
			if (pm && !((pm[i >> 6] >> (i & 63)) & 1)) continue;
			void *v = FP(o, i);
			if (!v) continue;
			char *before = old_ptr;
			void *nv = gc_fwd(v);
			FP(o, i) = nv;
			if (old_ptr != before) { // copied just now: its subtree next
				f->i = i + 1;
				gc_push(nv); // may move gc_stack: f is not used after this
				goto next;
			}
		}
		gc_top--;
	next:;
	}
}

// forward a root, then copy everything reachable from it that is still to copy
static void *fwd_root(void *p) {
	char *before = old_ptr;
	void *n = gc_fwd(p);
	if (old_ptr != before) {
		gc_push(n);
		gc_drain();
	}
	return n;
}

static void major(size_t need);
static void run_finalisers(int propagate);

static void minor_(void);
static void minor(void) {
	double t0 = stats ? now_secs() : 0;
	unsigned long m0 = majors;
	minor_();
	if (majors == m0) sweep_natives(NULL, NULL);
	if (stats && majors == m0) minor_secs += now_secs() - t0;
}

static void *(*rem_fwd)(void *);
static void scan_object(void *o, void *(*fwd)(void *));
static void forget_objs(rt_mutator *m) {
	m->robjs_len = 0;
	memset(m->robjs_recent, 0, sizeof m->robjs_recent);
}

static void forward_remembered(rt_mutator *m, void *arg) {
	(void)arg;
	for (size_t i = 0; i < m->rem_len; i++)
		if (*m->rem[i]) *m->rem[i] = rem_fwd(*m->rem[i]);
	m->rem_len = 0;
	for (size_t i = 0; i < m->robjs_len; i++)
		scan_object(m->robjs[i], rem_fwd);
	forget_objs(m);
}

static void clear_remembered(rt_mutator *m, void *arg) {
	(void)arg;
	m->rem_len = 0;
	forget_objs(m);
}

static void minor_(void) {
	size_t young_used = young_next - rt_young_start;
	if ((size_t)(old_end - old_ptr) < young_used + 64) {
		major(0);
		return;
	}
	minors++;
	populate(old_ptr + young_used);
	char *scan = old_ptr;
	if (!gc_bfs) {
		gc_fwd = minor_forward;
		scan_roots(fwd_root);
		for (size_t i = 0; i < nfinals; i++)
			finals[i].val = fwd_root(finals[i].val);
		rem_fwd = fwd_root;
		rt_mutators_foreach(forward_remembered, NULL);
		return;
	}
	scan_roots(minor_forward);
	for (size_t i = 0; i < nfinals; i++)
		finals[i].val = minor_forward(finals[i].val);
	rem_fwd = minor_forward;
	rt_mutators_foreach(forward_remembered, NULL);
	while (scan < old_ptr) {
		void *o = scan + 8;
		scan += obj_bytes(o);
		scan_object(o, minor_forward);
	}
}

// ---- major collection: copy everything live into a fresh to-space.
// Natively the old space alternates between two large reserved regions;
// old_end is a soft limit, set after each major collection to three times the
// live size. Under Emscripten memory is real, so each major collection
// mallocs a to-space sized from what may survive and frees the from-space.

#ifndef __EMSCRIPTEN__
#define REGION (16ull << 30)
static char *regions[2];
static int cur_region;
// pages of each region already faulted in: populated in large batches ahead
// of use, which costs the kernel much less than one fault per 4 KB page. The
// batch is an eighth of the space in use, between 4 MB and 32 MB
// (RT_AHEAD_MB), so a small program does not fault in memory it never uses.
static char *populated[2];
static size_t populate_ahead = 32u << 20; // RT_AHEAD_MB
static void populate(char *upto) {
#ifdef MADV_POPULATE_WRITE
	char **hi = &populated[cur_region];
	if (*hi == NULL || *hi < regions[cur_region]) *hi = regions[cur_region];
	if (upto <= *hi) return;
	size_t ahead = (size_t)(upto - regions[cur_region]) / 8;
	if (ahead < (4u << 20)) ahead = 4u << 20;
	if (ahead > populate_ahead) ahead = populate_ahead;
	char *end = (char *)(((uintptr_t)upto + ahead) & ~(uintptr_t)((2u << 20) - 1));
	if (end > regions[cur_region] + REGION) end = regions[cur_region] + REGION;
	if (madvise(*hi, end - *hi, MADV_POPULATE_WRITE) == 0) *hi = end;
	else *hi = end; // not supported: let pages fault in as before
#else
	(void)upto;
#endif
}
#ifdef MADV_POPULATE_WRITE
#define POPULATE_AHEAD(bytes) \
	if (__builtin_expect(old_ptr + (bytes) > populated[cur_region], 0)) populate(old_ptr + (bytes))
#else
#define POPULATE_AHEAD(bytes)
#endif
#else
static void populate(char *upto) { (void)upto; }
#define POPULATE_AHEAD(bytes)
#endif
static char *from_start, *from_end;

static void *major_forward(void *p) {
	if (!in_young(p) && !((char *)p >= from_start && (char *)p < from_end)) return p;
	if (KIND(p) == K_FWD) return FP(p, 0);
	POPULATE_AHEAD(obj_bytes(p)); // the to-space is faulted in as the copy reaches it
	void *n = copy_to(old_ptr, p);
	old_ptr += obj_bytes(p);
	forward_to(p, n);
	return n;
}

static void major_(size_t need);
static void major(size_t need) {
	double t0 = stats ? now_secs() : 0;
	major_(need);
	if (stats) major_secs += now_secs() - t0;
}

static void major_(size_t need) {
	majors++;
	from_start = old_start;
	from_end = old_ptr;
#ifdef __EMSCRIPTEN__
	// everything in the old and young spaces may survive
	size_t cap = 2 * ((size_t)(old_ptr - old_start) + (size_t)(young_next - rt_young_start)) + 4 * minor_size + need;
	if (cap < (32u << 20)) cap = 32u << 20;
	old_start = old_ptr = (char *)malloc(cap);
	if (!old_start) {
		fputs("out of memory\n", stderr);
		exit(2);
	}
#else
	// pages faulted in ahead of the from-space's end are not needed now
	if (release_pages && populated[cur_region] > from_end) {
		char *lo = (char *)(((uintptr_t)from_end + 4095) & ~(uintptr_t)4095);
		if (populated[cur_region] > lo) madvise(lo, populated[cur_region] - lo, MADV_DONTNEED);
		populated[cur_region] = lo;
	}
	cur_region ^= 1;
	old_start = old_ptr = regions[cur_region];
	populate(old_start + 1);
#endif
	char *scan = old_ptr;
	if (!gc_bfs) {
		gc_fwd = major_forward;
		scan_roots(fwd_root);
	} else
		scan_roots(major_forward);
	rt_mutators_foreach(clear_remembered, NULL);
	while (gc_bfs && scan < old_ptr) {
		void *o = scan + 8;
		scan += obj_bytes(o);
		scan_object(o, major_forward);
	}
	if (nfinals) {
		// values not copied yet are unreachable: queue their calls (newest
		// first), then copy them and what they reach
		size_t live = 0, q0 = final_qlen;
		for (size_t i = nfinals; i-- > 0;) {
			void *v = finals[i].val;
			int collected = in_young(v) || ((char *)v >= from_start && (char *)v < from_end);
			if (collected && KIND(v) != K_FWD) {
				if (final_qlen == final_qcap) {
					final_qcap = final_qcap ? final_qcap * 2 : 64;
					final_queue = (rt_final *)realloc(final_queue, final_qcap * sizeof(rt_final));
				}
				final_queue[final_qlen++] = finals[i];
				finals[i].fn = NULL;
			}
		}
		for (size_t i = 0; i < nfinals; i++)
			if (finals[i].fn) {
				void *v = finals[i].val;
				if (in_young(v) || ((char *)v >= from_start && (char *)v < from_end)) v = FP(v, 0);
				finals[live].fn = finals[i].fn;
				finals[live++].val = v;
			}
		nfinals = live;
		for (size_t i = q0; i < final_qlen; i++)
			final_queue[i].val = gc_bfs ? major_forward(final_queue[i].val) : fwd_root(final_queue[i].val);
		while (gc_bfs && scan < old_ptr) {
			void *o = scan + 8;
			scan += obj_bytes(o);
			scan_object(o, major_forward);
		}
	}
	sweep_natives(from_start, from_end);
#ifdef __EMSCRIPTEN__
	free(from_start);
	old_end = old_start + cap;
#else
	// the from-space goes back to the kernel (RT_RELEASE=0 keeps it resident,
	// so the next major collection copies into faulted-in pages: a little
	// less system time for as much more memory as the old space held)
	if (release_pages) {
		char *hi = populated[cur_region ^ 1] > from_end ? populated[cur_region ^ 1] : from_end; // with the pages faulted in ahead
		madvise(from_start, hi - from_start, MADV_DONTNEED);
		populated[cur_region ^ 1] = regions[cur_region ^ 1];
	}
	size_t live = old_ptr - old_start;
	size_t limit = 3 * live + 4 * minor_size + need;
	if (limit < (64u << 20)) limit = 64u << 20;
	if (limit > REGION) limit = REGION;
	old_end = old_start + limit;
#endif
	if (stats) fprintf(stderr, "gc: major %lu: %zu MB live of %zu MB, limit %zu MB\n", majors, (size_t)(old_ptr - old_start) >> 20, (size_t)(from_end - from_start) >> 20, (size_t)(old_end - old_start) >> 20);
	if (census == 2) census_now("major collection");
}

// the nursery is empty again: every thread takes a new TLAB at its next allocation
static void reset_tlab(rt_mutator *m, void *arg) {
	(void)arg;
	*m->yptr_ref = NULL;
	*m->ylim_ref = NULL;
}

// a collection, with every other thread stopped (unless another thread
// collected meanwhile: the caller then retries its allocation)
static void collect(int full, size_t need) {
	if (!rt_world_stop()) return;
	if (full) major(need);
	else minor();
	young_next = rt_young_start;
	rt_mutators_foreach(reset_tlab, NULL);
	rt_world_resume();
}

// a TLAB with room for `bytes`: with one thread the whole free nursery
static int tlab_refill(uint32_t bytes) {
	size_t want = RT_NTHREADS() > 1 ? tlab_size : (size_t)-1;
	if (want < bytes) want = bytes;
#if RT_MT
	char *p = __atomic_load_n(&young_next, __ATOMIC_RELAXED);
	for (;;) {
		size_t avail = (size_t)(rt_young_end - p);
		if (avail < bytes) return 0;
		size_t take = want < avail ? want : avail;
		if (__atomic_compare_exchange_n(&young_next, &p, p + take, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
			rt_young_ptr = p;
			rt_young_limit = p + take;
			return 1;
		}
	}
#else
	char *p = young_next;
	size_t avail = (size_t)(rt_young_end - p);
	if (avail < bytes) return 0;
	size_t take = want < avail ? want : avail;
	young_next = p + take;
	rt_young_ptr = p;
	rt_young_limit = p + take;
	return 1;
#endif
}

void *rt_alloc_slow(uint64_t header, uint32_t bytes) {
#if RT_GREEN
	// a green thread that only computes gives way at each minor collection
	// (before allocating: the caller's live references are rooted here)
	if (RT_NTHREADS() > 1) rt_preempt();
#endif
	// a safepoint: the caller's live references are rooted here
	rt_safepoint();
	// likewise for finaliser calls queued by an earlier major collection
#if RT_MT
	if (__atomic_load_n(&final_qlen, __ATOMIC_RELAXED) && !finals_running) run_finalisers(0);
#else
	if (final_qhead < final_qlen && !finals_running) run_finalisers(0);
#endif
	char *p;
	if (bytes > minor_size / 4) {
		// large objects go straight to the old space
#if RT_MT
		p = __atomic_load_n(&old_ptr, __ATOMIC_RELAXED);
		for (;;) {
			if ((size_t)(old_end - p) < bytes) {
				collect(1, bytes);
				p = __atomic_load_n(&old_ptr, __ATOMIC_RELAXED);
				continue;
			}
			if (__atomic_compare_exchange_n(&old_ptr, &p, p + bytes, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) break;
		}
#else
		if ((size_t)(old_end - old_ptr) < bytes) collect(1, bytes);
		p = old_ptr;
		old_ptr += bytes;
#endif
	} else {
		if (rt_young_limit - rt_young_ptr < (intptr_t)bytes) // else another thread collected meanwhile
			while (!tlab_refill(bytes)) collect(0, 0);
		p = rt_young_ptr;
		rt_young_ptr += bytes;
	}
	*(uint64_t *)p = header;
	memset(p + 8, 0, bytes - 8);
	return p + 8;
}

// Gc.finalise f v: values outside the heap (static objects, null) are never
// collected, so their finalisers never run
void rt_gc_finalise(void *fn, void *val) {
	if (!val || !(in_young(val) || ((char *)val >= old_start && (char *)val < old_ptr))) return;
	rt_lock(&finals_lock);
	if (nfinals == finals_cap) {
		finals_cap = finals_cap ? finals_cap * 2 : 64;
		finals = (rt_final *)realloc(finals, finals_cap * sizeof(rt_final));
	}
	finals[nfinals].fn = fn;
	finals[nfinals++].val = val;
	rt_unlock(&finals_lock);
}

// a collection now: minor (0) or major (1), as OCaml's Gc.minor/full_major
void rt_gc_collect(int full) {
	collect(full, 0);
}

// calls the queued finalisers (an exception escapes when propagate is set,
// as from OCaml's Gc.full_major; otherwise, at an allocation, it is reported)
void rt_gc_run_finalisers(int propagate) { run_finalisers(propagate); }

static void run_finalisers(int propagate) {
	if (finals_running) return;
	finals_running = 1;
	for (;;) {
		rt_lock(&finals_lock);
		if (final_qhead >= final_qlen) {
			rt_unlock(&finals_lock);
			break;
		}
		void **r = rt_sp;
		rt_sp += 2;
		r[0] = final_queue[final_qhead].fn;
		r[1] = final_queue[final_qhead].val;
		if (++final_qhead == final_qlen) final_qhead = final_qlen = 0;
		rt_unlock(&finals_lock);
		void *args = hx_arr_new(AK_PTR, 0);
		RT_ROOT(args);
		hx_apush_slow(args_root, AK_PTR, (uint64_t)(uintptr_t)&r[1]);
		RT_TRY(h)
			hx_dyn_call(r[0], *args_root);
		RT_CATCH(h)
			if (propagate) {
				finals_running = 0;
				rt_sp = r;
				rt_throw(rt_exn);
			}
			char *s = hx_str_to_utf8(hx_std_string(rt_exn));
			rt_exn = 0;
			fflush(stdout);
			fprintf(stderr, "Uncaught exception in a finaliser: %s\n", s);
			free(s);
		RT_END_TRY(h)
		rt_sp = r;
	}
	finals_running = 0;
}

// old objects whose every slot may hold a young pointer, scanned whole by the
// next minor collection (per thread, rt_mutator); a small cache drops
// repeated entries for one object
static void remember_obj(void *obj) {
	rt_mutator *m = rt_mut;
	size_t h = ((uintptr_t)obj >> 4) & 255;
	if (m->robjs_recent[h] == obj) return;
	m->robjs_recent[h] = obj;
	if (m->robjs_len == m->robjs_cap) {
		m->robjs_cap = m->robjs_cap ? m->robjs_cap * 2 : 256;
		m->robjs = (void **)realloc(m->robjs, m->robjs_cap * sizeof(void *));
	}
	m->robjs[m->robjs_len++] = obj;
}

void rt_write_barrier(void *obj, void **slot, void *val) {
	(void)obj;
	(void)val;
	rt_mutator *m = rt_mut;
	if (m->rem_len == m->rem_cap) {
		m->rem_cap = m->rem_cap ? m->rem_cap * 2 : 4096;
		m->rem = (void ***)realloc(m->rem, m->rem_cap * sizeof(void **));
	}
	m->rem[m->rem_len++] = slot;
}

// after a bulk move or copy of references into obj (memmove in natives): the
// remembered set records slots, so every slot now holding a young pointer is
// recorded again. A long range (e.g. Array.insert at the front of a large
// array, as the port does for OCaml's `x :: l`) remembers the whole object
// once instead: recording its slots made the set grow by the array's length
// at every insertion (16M entries, 128 MB, on the self-compile).
void rt_barrier_range(void *obj, void **from, int32_t n) {
	if (in_young(obj)) return;
	if (n > 16) {
		remember_obj(obj);
		return;
	}
	for (int32_t i = 0; i < n; i++)
		if (in_young(from[i])) rt_write_barrier(obj, &from[i], from[i]);
}

static void census_now(const char *when) {
	rt_census_info gi;
	memset(&gi, 0, sizeof gi);
	gi.when = when;
	gi.young = minor_size;
	gi.old_used = old_ptr - old_start;
	gi.old_limit = old_end - old_start;
#ifndef __EMSCRIPTEN__
	for (int i = 0; i < 2; i++)
		gi.populated[i] = populated[cur_region ^ i] > regions[cur_region ^ i] ? (size_t)(populated[cur_region ^ i] - regions[cur_region ^ i]) : 0;
#endif
	gi.remembered = (rt_mut->rem_cap + rt_mut->robjs_cap) * sizeof(void *); // the calling thread's
	gi.gcstack = gc_cap * sizeof(gc_frame);
	gi.shadow = (char *)rt_sp - (char *)rt_stack_base;
	gi.minors = minors;
	gi.majors = majors;
	gi.nglobals = nglobals;
	rt_census(old_start, old_ptr, &gi);
}

static void report(void) {
	if (stats) {
		long rss, hwm;
		rt_proc_rss(&rss, &hwm);
		fprintf(stderr, "gc: RSS %ld MB, peak %ld MB; old %zu MB used of %zu MB limit\n", rss >> 10, hwm >> 10, (size_t)(old_ptr - old_start) >> 20, (size_t)(old_end - old_start) >> 20);
	}
	if (census) {
		int c = census;
		census = 0;
		major(0);
		census_now("exit");
		census = c;
	}
	if (stats) fprintf(stderr, "gc: %lu minor (%.2fs), %lu major (%.2fs), old %zu MB used\n", minors, minor_secs, majors, major_secs, (size_t)(old_ptr - old_start) >> 20);
}

// small Int boxes and the two Bool boxes are static
#define SMALL_MIN (-128)
#define SMALL_MAX 1023
static uint64_t small_ints[2 * (SMALL_MAX - SMALL_MIN + 1)];
static uint64_t bool_boxes[4];

void rt_init(int ng, int argc, char **argv) {
	rt_argc = argc;
	rt_argv = argv;
#ifdef __COSMOPOLITAN__
	// an APE build may carry the Haxe standard library in its own zip (site/build.sh)
	if (!getenv("HAXE_STD_PATH") && access("/zip/std/StdTypes.hx", R_OK) == 0) setenv("HAXE_STD_PATH", "/zip/std/", 1);
#endif
	const char *m = getenv("RT_MINOR_KB");
	minor_size = (m ? (size_t)atoi(m) : 4096) << 10;
	stats = getenv("RT_STATS") != NULL;
#ifndef __EMSCRIPTEN__
	const char *ah = getenv("RT_AHEAD_MB");
	if (ah) populate_ahead = (size_t)atoi(ah) << 20;
#endif
	const char *cs = getenv("RT_CENSUS");
	census = cs ? atoi(cs) : 0;
	const char *rp = getenv("RT_RELEASE");
	release_pages = rp ? atoi(rp) : 1;
	gc_bfs = getenv("RT_BFS") != NULL;
#if defined(MADV_HUGEPAGE) && !defined(__EMSCRIPTEN__)
	// transparent huge pages for the heap: the old space grows by hundreds of
	// MB and is copied into fresh pages, so 4 KB page faults add up
	const char *hp = getenv("RT_HUGE");
	int huge = hp && atoi(hp); // opt-in: it costs more kernel time than it saves here
	rt_young_start = (char *)aligned_alloc(2u << 20, (minor_size + (2u << 20) - 1) & ~(size_t)((2u << 20) - 1));
	if (huge) madvise(rt_young_start, minor_size, MADV_HUGEPAGE);
#else
	rt_young_start = (char *)malloc(minor_size);
#endif
	rt_young_end = rt_young_start + minor_size;
	young_next = rt_young_start; // rt_young_ptr = rt_young_limit = NULL: the first allocation takes a TLAB
	const char *tk = getenv("RT_TLAB_KB");
	tlab_size = tk ? (size_t)atoi(tk) << 10 : minor_size / 16;
	if (tlab_size < 4096) tlab_size = 4096;
#ifdef __EMSCRIPTEN__
	old_start = old_ptr = (char *)malloc(32u << 20);
	old_end = old_start + (32u << 20);
	size_t stack_slots = 4u << 20;
#else
	for (int i = 0; i < 2; i++) {
		regions[i] = mmap(NULL, REGION, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
		if (regions[i] == MAP_FAILED) {
			fputs("cannot reserve heap\n", stderr);
			exit(2);
		}
#ifdef MADV_HUGEPAGE
		if (huge) madvise(regions[i], REGION, MADV_HUGEPAGE);
#endif
	}
	old_start = old_ptr = regions[0];
	const char *om = getenv("RT_OLD_MB");
	old_end = old_start + ((size_t)(om ? atoi(om) : 256) << 20); // fewer major collections early on
	size_t stack_slots = 16u << 20;
#endif
#ifdef __EMSCRIPTEN__
	rt_stack_base = rt_sp = (void **)calloc(stack_slots, sizeof(void *));
#else
	// reserved, committed as touched, with a guard page above it: as deep as
	// the main C stack (rt_run_main)
	(void)stack_slots;
	size_t sbytes = (size_t)1 << 30, page = (size_t)sysconf(_SC_PAGESIZE);
	char *sstack = mmap(NULL, sbytes + page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (sstack == MAP_FAILED) {
		fputs("cannot reserve the shadow stack\n", stderr);
		exit(2);
	}
	mprotect(sstack + sbytes, page, PROT_NONE);
	rt_stack_base = rt_sp = (void **)sstack;
#endif
	rt_threads_init();
	nglobals = ng;
	rt_globals = (void **)calloc(ng + 1, sizeof(void *));
	for (int i = SMALL_MIN; i <= SMALL_MAX; i++) {
		uint64_t *b = &small_ints[2 * (i - SMALL_MIN)];
		b[0] = MKHDR(1, K_OBJ, T_BOXINT);
		*(int32_t *)&b[1] = i;
	}
	for (int i = 0; i < 2; i++) {
		bool_boxes[2 * i] = MKHDR(1, K_OBJ, T_BOXBOOL);
		*(int32_t *)&bool_boxes[2 * i + 1] = i;
	}
	for (int t = 0; t < rt_ntypes; t++) {
		rt_type_objs[2 * t] = MKHDR(1, K_RAW, T_TYPEOBJ);
		*(int32_t *)&rt_type_objs[2 * t + 1] = t;
	}
	atexit(report);
}

// binds a mutator to the calling thread's runtime state
void rt_mutator_bind(rt_mutator *m) {
	m->sp_ref = &rt_sp;
	m->base_ref = &rt_stack_base;
	m->exn_ref = &rt_exn;
	m->yptr_ref = &rt_young_ptr;
	m->ylim_ref = &rt_young_limit;
	rt_mut = m;
}

// ---- exceptions

#if !(defined(__cplusplus) && defined(__EMSCRIPTEN__))
__attribute__((noreturn)) void rt_throw(void *v) {
	rt_exn = v;
	if (!rt_hcur) {
		char *s = hx_str_to_utf8(hx_std_string(v));
		fprintf(stderr, "Uncaught exception: %s\n", s);
		exit(1);
	}
	RT_LONGJMP(rt_hcur->buf);
}
#endif

__attribute__((noreturn)) void hx_throw_str(const char *msg) {
	rt_throw(hx_str_of_ascii(msg));
}

int32_t hx_f2i(double f) {
	if (!(f == f)) return 0;
	if (f >= 2147483648.0 || f <= -2147483649.0) return (int32_t)(uint32_t)(int64_t)fmod(f, 4294967296.0);
	return (int32_t)f;
}

// ---- boxes

void *hx_box_int(int32_t v) {
	if (v >= SMALL_MIN && v <= SMALL_MAX) return &small_ints[2 * (v - SMALL_MIN) + 1];
	void *b = rt_alloc_init(1, T_BOXINT, K_OBJ);
	FP(b, 0) = 0;
	FI(b, 0) = v;
	return b;
}

void *hx_box_float(double v) {
	void *b = rt_alloc_init(1, T_BOXFLOAT, K_OBJ);
	FD(b, 0) = v;
	return b;
}

void *hx_box_bool(int32_t v) {
	return &bool_boxes[v ? 3 : 1];
}

int32_t hx_unbox_int(void *v) {
	if (!v) return 0;
	switch (TINDEX(v)) {
	case T_BOXINT:
	case T_BOXBOOL: return FI(v, 0);
	case T_BOXFLOAT: return hx_f2i(FD(v, 0));
	default: return 0;
	}
}

double hx_unbox_float(void *v) {
	if (!v) return 0;
	switch (TINDEX(v)) {
	case T_BOXINT:
	case T_BOXBOOL: return FI(v, 0);
	case T_BOXFLOAT: return FD(v, 0);
	default: return 0;
	}
}

int32_t hx_unbox_bool(void *v) {
	if (!v) return 0;
	switch (TINDEX(v)) {
	case T_BOXINT:
	case T_BOXBOOL: return FI(v, 0) != 0;
	case T_BOXFLOAT: return FD(v, 0) != 0;
	default: return 1;
	}
}

// ---- arrays

// data for at least `cap` elements (exactly: literals and copies have their
// length; growth rounds up, see hx_arr_grow); *real: the capacity in elements
static void *data_alloc(int32_t kind, int32_t cap, int32_t *real) {
	if (cap < 1) cap = 1;
	switch (kind) {
	case AK_I32:
		*real = (cap + 1) & ~1;
		return rt_alloc((cap + 1) / 2, T_ADATA_RAW, K_RAW);
	case AK_F64: *real = cap; return rt_alloc(cap, T_ADATA_RAW, K_RAW);
	default: *real = cap; return rt_alloc(cap, T_ADATA_P, K_PARR);
	}
}

// arrays with elements (empty arrays have no data until the first store: rt.h)
void *hx_arr_new_n(int32_t kind, int32_t len) {
	int32_t cap;
	void *d = data_alloc(kind, len, &cap);
	RT_ROOT(d);
	void *a = rt_alloc(2, T_ARRAY, K_OBJ);
	RT_RELOAD(d);
	RT_UNROOT(1);
	ARR_LEN(a) = len;
	ARR_KIND(a) = kind;
	FP(a, 1) = d; // a is young
	if (!in_young(a)) rt_set_ptr(a, &FP(a, 1), d);
	return a;
}

// room for `need` elements
// With green threads (rt_thread.c), another thread can run at the allocation
// (rt_alloc_slow -> rt_preempt) and change the array: its length, capacity or
// kind are read again after allocating, and the growth is retried if another
// thread replaced the data meanwhile.
void hx_arr_grow(void **slot, int32_t need) {
	void *a = *slot;
	uint32_t cap = ARR_CAP(a);
	if ((uint32_t)need <= cap) return;
	void *d0 = ARR_DATA(a);
	uint32_t ncap = cap * 2;
	if (ncap < 2) ncap = 2; // from empty: 2, 4, 8... (most arrays stay small)
	if (ncap < (uint32_t)need) ncap = need;
	int32_t real;
	int32_t kind = ARR_KIND(a);
	void *nd = data_alloc(kind, ncap, &real);
	a = *slot;
	if (ARR_DATA(a) != d0 || ARR_KIND(a) != kind) {
		hx_arr_grow(slot, need);
		return;
	}
	void *d = ARR_DATA(a);
	uint32_t len = ARR_LEN(a);
	switch (ARR_KIND(a)) {
	case AK_I32: memcpy(nd, d, 4 * len); break;
	case AK_F64: memcpy(nd, d, 8 * len); break;
	default:
		memcpy(nd, d, 8 * len);
		// large data is allocated old: its elements may point to young objects
		if (!in_young(nd)) rt_barrier_range(nd, (void **)nd, len);
		break;
	}
	rt_set_ptr(a, &ARR_DATA(a), nd);
}

// convert an Int/Float array to boxed elements (generic code stored something else)
void hx_arr_to_ptr(void **slot) {
	void *a = *slot;
	if (ARR_KIND(a) == AK_PTR) return;
	uint32_t len = ARR_LEN(a);
	int32_t real;
	void *nd = data_alloc(AK_PTR, len, &real);
	RT_ROOT(nd);
	for (uint32_t i = 0; i < len; i++) {
		a = *slot;
		void *v = ARR_KIND(a) == AK_I32 ? hx_box_int(((int32_t *)ARR_DATA(a))[i]) : hx_box_float(((double *)ARR_DATA(a))[i]);
		RT_RELOAD(nd);
		rt_set_ptr(nd, &FP(nd, i), v);
	}
	RT_RELOAD(nd);
	RT_UNROOT(1);
	a = *slot;
	ARR_KIND(a) = AK_PTR;
	rt_set_ptr(a, &ARR_DATA(a), nd);
}

int32_t hx_aget_i_slow(void *a, int32_t i) {
	if (!a || (uint32_t)i >= (uint32_t)ARR_LEN(a)) return 0;
	switch (ARR_KIND(a)) {
	case AK_I32: return ((int32_t *)ARR_DATA(a))[i];
	case AK_F64: return hx_f2i(((double *)ARR_DATA(a))[i]);
	default: return hx_unbox_int(FP(ARR_DATA(a), i));
	}
}

double hx_aget_f_slow(void *a, int32_t i) {
	if (!a || (uint32_t)i >= (uint32_t)ARR_LEN(a)) return 0;
	switch (ARR_KIND(a)) {
	case AK_I32: return ((int32_t *)ARR_DATA(a))[i];
	case AK_F64: return ((double *)ARR_DATA(a))[i];
	default: return hx_unbox_float(FP(ARR_DATA(a), i));
	}
}

void *hx_aget_p_slow(void *a, int32_t i) {
	if (!a || (uint32_t)i >= (uint32_t)ARR_LEN(a)) return 0;
	switch (ARR_KIND(a)) {
	case AK_I32: return hx_box_int(((int32_t *)ARR_DATA(a))[i]);
	case AK_F64: return hx_box_float(((double *)ARR_DATA(a))[i]);
	default: return FP(ARR_DATA(a), i);
	}
}

// store v (of kind vk; AK_PTR: v is the address of a rooted slot) at i < length
static void store_conv(void **slot, int32_t i, int32_t vk, uint64_t v) {
	void *a = *slot;
	int32_t ak = ARR_KIND(a);
	if (ak == AK_PTR) {
		void *p;
		switch (vk) {
		case AK_I32: p = hx_box_int((int32_t)v); break;
		case AK_F64: { double d; memcpy(&d, &v, 8); p = hx_box_float(d); break; }
		default: p = *(void **)(uintptr_t)v; break;
		}
		a = *slot;
		rt_set_ptr(ARR_DATA(a), &FP(ARR_DATA(a), i), p);
		return;
	}
	if (vk == AK_PTR) {
		void *p = *(void **)(uintptr_t)v;
		int num = !p || TINDEX(p) == T_BOXINT || TINDEX(p) == T_BOXFLOAT || TINDEX(p) == T_BOXBOOL;
		if (!num || (ak == AK_I32 && TINDEX(p) == T_BOXFLOAT)) {
			hx_arr_to_ptr(slot);
			store_conv(slot, i, vk, v);
			return;
		}
		if (ak == AK_I32) ((int32_t *)ARR_DATA(a))[i] = hx_unbox_int(p);
		else ((double *)ARR_DATA(a))[i] = hx_unbox_float(p);
		return;
	}
	double d;
	memcpy(&d, &v, 8);
	if (ak == AK_I32 && vk == AK_F64) {
		hx_arr_to_ptr(slot);
		store_conv(slot, i, vk, v);
		return;
	}
	if (ak == AK_I32) ((int32_t *)ARR_DATA(a))[i] = (int32_t)v;
	else ((double *)ARR_DATA(a))[i] = vk == AK_I32 ? (double)(int32_t)v : d;
}

void hx_aset_slow(void **slot, int32_t i, int32_t vk, uint64_t v) {
	if (i < 0) return;
	void *a = *slot;
	if ((uint32_t)i >= (uint32_t)ARR_LEN(a)) {
		hx_arr_grow(slot, i + 1);
		a = *slot;
		// the data is zeroed: new elements are 0 / null (another thread may have grown it meanwhile)
		if ((uint32_t)i >= (uint32_t)ARR_LEN(a)) ARR_LEN(a) = i + 1;
	}
	store_conv(slot, i, vk, v);
}

// returns the index of the new element (the length is read after growing:
// another thread may have changed it at the allocation, see hx_arr_grow)
int32_t hx_apush_slow(void **slot, int32_t vk, uint64_t v) {
	void *a = *slot;
	int32_t n = ARR_LEN(a);
	while ((uint32_t)n >= ARR_CAP(a)) {
		hx_arr_grow(slot, n + 1);
		a = *slot;
		n = ARR_LEN(a);
	}
	ARR_LEN(a) = n + 1;
	store_conv(slot, n, vk, v);
	return n;
}

// ---- hxc.NativeGc

void hxc_NativeGc_finalise(void *fn, void *val) { rt_gc_finalise(fn, val); }
void hxc_NativeGc_collect(int32_t full) { rt_gc_collect(full); }
void hxc_NativeGc_runFinalisers(void) { rt_gc_run_finalisers(1); }
