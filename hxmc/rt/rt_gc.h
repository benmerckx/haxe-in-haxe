// The hxmc runtime: the interface between the collector
// (rt.c) and the threads (rt_thread.c). Not included by generated code.
#pragma once
#include "rt.h"

// A mutator is a thread as the collector sees it: where its thread-local
// runtime state lives (the refs point at the owning thread's TLS variables,
// valid while it is registered) and its remembered set. With green threads or
// none, there is one mutator, over the globals (the green scheduler swaps
// them).
typedef struct rt_mutator {
	void ***sp_ref, ***hw_ref, ***base_ref;
	void **last_fp_ref, **last_pc_ref; // stack maps (rt_frames.c)
	void **exn_ref;
	char **yptr_ref, **ylim_ref;
	void ***rem; // remembered set: slots of old objects that may hold young pointers
	size_t rem_len, rem_cap;
	void **robjs; // remembered objects: old objects scanned whole (rt_barrier_range of long ranges)
	size_t robjs_len, robjs_cap;
	void *robjs_recent[256];
	struct rt_mutator *next; // the registered mutators (rt_thread.c)
} rt_mutator;

extern RT_TLS rt_mutator *rt_mut; // the running thread's
void rt_mutator_bind(rt_mutator *m); // points m at the calling thread's TLS variables
void rt_zero_above(void **sp, void ***hw); // rt.c: after a collection, see rt_sp_hw
void rt_threads_init(void); // rt_thread.c, from rt_init: the main thread's record and mutator

// rt_thread.c. Every registered mutator, the caller's (the collector's) and
// the one of the threads that ended included; the others are in a safe region
// or stopped at a safepoint. Only valid between rt_world_stop and
// rt_world_resume.
void rt_mutators_foreach(void (*f)(rt_mutator *m, void *arg), void *arg);
#if RT_MT
// Stops every other thread at a safepoint or in a safe region. Returns 0 if
// another thread was collecting meanwhile (the caller waited for it as at a
// safepoint, and should retry its allocation instead of collecting).
int rt_world_stop(void);
void rt_world_resume(void);
extern volatile int rt_gc_requested;
void rt_safepoint_slow(void);
static inline void rt_safepoint(void) {
	if (__builtin_expect(__atomic_load_n(&rt_gc_requested, __ATOMIC_RELAXED), 0)) rt_safepoint_slow();
}
#else
#define rt_world_stop() 1
#define rt_world_resume() ((void)0)
#define rt_safepoint() ((void)0)
#endif

// rt.c: native handles (T_NATIVE objects whose C resource is freed by the
// collector once the object is unreachable: mutexes, conditions, ...)
void *rt_native_new(void *p, void (*free_fn)(void *));
void *rt_native_new_refs(void *p, void (*free_fn)(void *), uint32_t nrefs);
// rt_dyn.c: per-thread caches, freed when a thread ends
void rt_dyn_thread_exit(void);
