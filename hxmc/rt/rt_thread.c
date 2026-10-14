// The runtime of hxmc's programs: threads behind
// hxmc.NativeThread (hxmc/std/hxmc/NativeThread.hx), the base of the hxmc
// sys.thread package (hxmc/std/sys/thread) and of haxe.atomic.
//
// Three implementations (rt.h RT_MT / RT_GREEN):
//
// - 1:1 (gcc, clang, cosmocc builds): every Haxe thread is an OS thread
//   (pthreads) and threads run in parallel. The per-thread runtime state
//   (shadow stack, allocation buffer, exception handlers, current exception)
//   is thread-local (rt.h RT_TLS). The collector stops the world: a thread
//   that needs a collection sets rt_gc_requested and waits until every other
//   thread is stopped at a safepoint (an allocation slow path, rt_safepoint)
//   or in a safe region (a blocking native between rt_blocking_enter and
//   rt_blocking_leave, which holds no heap pointer outside its shadow
//   stack); it then scans every thread's roots (rt_threads_scan) and
//   remembered set (rt_mutators_foreach) and resumes them. The world lock
//   `wl` guards the thread list and the collection handshake.
//
// - Green (tcc builds, -DRT_GREEN_THREADS; tcc has no thread-local storage):
//   M:1 cooperative threads. Every Haxe thread runs on the one OS thread, and
//   a thread only gives way at a blocking point (park, sleep, yield, waiting
//   for a file descriptor) or at a minor collection. Each thread has its own
//   C stack (ucontext), shadow stack and exception handler chain; a switch
//   saves the globals rt_sp, rt_stack_base, rt_hcur and rt_exn into the
//   thread record and loads the next thread's. When no thread can run, the
//   scheduler waits in poll() over the descriptors threads wait for, up to
//   the nearest timer deadline; if no thread can ever be woken again, the
//   program reports the deadlock and exits.
//
// - None (__EMSCRIPTEN__, the wasm playground): spawn throws, and waiting
//   forever throws instead of blocking.
//
// The synchronization primitives (re-entrant mutex, condition variable,
// counting semaphore, thread-local values) are natives with the same
// interface in the three: pthread mutexes and conditions in 1:1, queues of
// parked threads otherwise. Their handles are T_NATIVE objects freed by the
// collector (rt_native_new).
#define _GNU_SOURCE
#ifdef __APPLE__
// macOS: the ucontext routines (rt_run_main, green threads) need _XOPEN_SOURCE,
// and _DARWIN_C_SOURCE keeps the rest (MAP_ANONYMOUS, ...) visible
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#endif
#include "rt_gc.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int32_t rt_nthreads = 1;
void (*rt_spawn_hook)(void);

static double now_secs(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void sleep_secs(double seconds) {
	if (seconds <= 0) return;
	struct timespec t;
	t.tv_sec = (time_t)seconds;
	t.tv_nsec = (long)((seconds - (double)t.tv_sec) * 1e9);
	while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
}

int32_t hxmc_NativeThread_park(double timeout);
void hxmc_NativeThread_unpark(int32_t id);
int32_t hxmc_NativeThread_current(void);

#if !RT_MT

// ---- synchronization over park/unpark (green threads, or none): only one
// thread runs at a time and these functions do not allocate between looking
// at a primitive and parking, so they need no atomics; a park can return
// early (see hxmc_NativeThread_unpark), so waits look at their state again.

typedef struct {
	int32_t *ids; // FIFO of waiting thread ids
	int n, cap;
} waitq;

static void wq_push(waitq *q, int32_t id) {
	if (q->n == q->cap) {
		q->cap = q->cap ? q->cap * 2 : 4;
		q->ids = (int32_t *)realloc(q->ids, q->cap * sizeof(int32_t));
	}
	q->ids[q->n++] = id;
}

static int32_t wq_shift(waitq *q) {
	int32_t id = q->ids[0];
	memmove(q->ids, q->ids + 1, (q->n - 1) * sizeof(int32_t));
	q->n--;
	return id;
}

static int wq_remove(waitq *q, int32_t id) {
	for (int i = 0; i < q->n; i++)
		if (q->ids[i] == id) {
			memmove(q->ids + i, q->ids + i + 1, (q->n - i - 1) * sizeof(int32_t));
			q->n--;
			return 1;
		}
	return 0;
}

static int wq_has(waitq *q, int32_t id) {
	for (int i = 0; i < q->n; i++)
		if (q->ids[i] == id) return 1;
	return 0;
}

typedef struct {
	int32_t owner; // thread id, 0: free
	int depth;
	waitq w;
} hx_mutex;

typedef struct {
	waitq w;
} hx_cond;

typedef struct {
	int32_t count;
	waitq w;
} hx_sem;

static void free_mutex(void *p) {
	free(((hx_mutex *)p)->w.ids);
	free(p);
}

static void free_cond(void *p) {
	free(((hx_cond *)p)->w.ids);
	free(p);
}

static void free_sem(void *p) {
	free(((hx_sem *)p)->w.ids);
	free(p);
}

void *hxmc_NativeThread_mutexNew(void) { return rt_native_new(calloc(1, sizeof(hx_mutex)), free_mutex); }

static void mutex_take(hx_mutex *m, int depth) {
	int32_t me = hxmc_NativeThread_current();
	if (m->owner == 0) {
		m->owner = me;
		m->depth = depth;
		return;
	}
	wq_push(&m->w, me);
	while (m->owner != me) hxmc_NativeThread_park(-1); // a release hands it over
	m->depth = depth;
}

void hxmc_NativeThread_mutexAcquire(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (m->owner == hxmc_NativeThread_current()) {
		m->depth++;
		return;
	}
	RT_ROOT(mo); // the handle stays alive while this thread waits
	mutex_take(m, 1);
	RT_UNROOT(1);
}

int32_t hxmc_NativeThread_mutexTryAcquire(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	int32_t me = hxmc_NativeThread_current();
	if (m->owner == 0) {
		m->owner = me;
		m->depth = 1;
		return 1;
	}
	if (m->owner == me) {
		m->depth++;
		return 1;
	}
	return 0;
}

static void mutex_give(hx_mutex *m) {
	if (m->w.n > 0) {
		m->owner = wq_shift(&m->w);
		hxmc_NativeThread_unpark(m->owner);
	} else
		m->owner = 0;
}

void hxmc_NativeThread_mutexRelease(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (m->owner != hxmc_NativeThread_current()) return;
	if (--m->depth > 0) return;
	mutex_give(m);
}

void *hxmc_NativeThread_condNew(void) { return rt_native_new(calloc(1, sizeof(hx_cond)), free_cond); }

// waits for a signal (1) or until timeout seconds pass (0; < 0: no timeout);
// the calling thread holds mutex m, which is released meanwhile (fully) and
// taken back at the same depth
int32_t hxmc_NativeThread_condWait(void *co, void *mo, double timeout) {
	hx_cond *c = (hx_cond *)FP(co, 0);
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	int32_t me = hxmc_NativeThread_current();
	if (m->owner != me) hx_throw_str("Condition.wait: the mutex is not held");
	RT_ROOT(co);
	RT_ROOT(mo);
	int depth = m->depth;
	wq_push(&c->w, me);
	mutex_give(m);
	double deadline = timeout < 0 ? -1 : now_secs() + timeout;
	int signaled;
	for (;;) {
		if (!wq_has(&c->w, me)) {
			signaled = 1;
			break;
		}
		double left = deadline < 0 ? -1 : deadline - now_secs();
		if (deadline >= 0 && left <= 0) {
			signaled = !wq_remove(&c->w, me);
			break;
		}
		hxmc_NativeThread_park(left);
	}
	mutex_take(m, depth);
	RT_UNROOT(2);
	return signaled;
}

void hxmc_NativeThread_condSignal(void *co) {
	hx_cond *c = (hx_cond *)FP(co, 0);
	if (c->w.n > 0) hxmc_NativeThread_unpark(wq_shift(&c->w));
}

void hxmc_NativeThread_condBroadcast(void *co) {
	hx_cond *c = (hx_cond *)FP(co, 0);
	while (c->w.n > 0) hxmc_NativeThread_unpark(wq_shift(&c->w));
}

void *hxmc_NativeThread_semNew(int32_t value) {
	hx_sem *s = (hx_sem *)calloc(1, sizeof(hx_sem));
	s->count = value;
	return rt_native_new(s, free_sem);
}

// takes a unit (1), or times out (0) after timeout seconds (0: just try; < 0:
// no timeout). A release with waiters hands its unit to the longest waiting.
int32_t hxmc_NativeThread_semAcquire(void *so, double timeout) {
	hx_sem *s = (hx_sem *)FP(so, 0);
	if (s->count > 0) {
		s->count--;
		return 1;
	}
	if (timeout == 0) return 0;
	RT_ROOT(so);
	int32_t me = hxmc_NativeThread_current();
	double deadline = timeout < 0 ? -1 : now_secs() + timeout;
	wq_push(&s->w, me);
	int r;
	for (;;) {
		if (!wq_has(&s->w, me)) {
			r = 1;
			break;
		}
		double left = deadline < 0 ? -1 : deadline - now_secs();
		if (deadline >= 0 && left <= 0) {
			r = !wq_remove(&s->w, me);
			break;
		}
		hxmc_NativeThread_park(left);
	}
	RT_UNROOT(1);
	return r;
}

void hxmc_NativeThread_semRelease(void *so) {
	hx_sem *s = (hx_sem *)FP(so, 0);
	if (s->w.n > 0) hxmc_NativeThread_unpark(wq_shift(&s->w));
	else s->count++;
}

#endif // !RT_MT

// ---- thread-local values (sys.thread.Tls): per thread, a K_PARR object
// indexed by Tls id (a root of the thread record)
static int32_t tls_next;

int32_t hxmc_NativeThread_tlsNew(void) {
#if RT_MT
	return __atomic_fetch_add(&tls_next, 1, __ATOMIC_RELAXED);
#else
	return tls_next++;
#endif
}

static void *tls_get(void **tls, int32_t id) {
	void *a = *tls;
	return a && (uint32_t)id < NSLOTS(a) ? FP(a, id) : NULL;
}

// `tls` is a GC root of the running thread's record (updated by a collection)
static void tls_set(void **tls, int32_t id, void *v) {
	if (id < 0) return;
	void *a = *tls;
	if (!a || (uint32_t)id >= NSLOTS(a)) {
		RT_ROOT(v);
		uint32_t n = a ? NSLOTS(a) * 2 : 8;
		if (n <= (uint32_t)id) n = id + 1;
		void *na = rt_alloc(n, T_ADATA_P, K_PARR);
		a = *tls;
		if (a)
			for (uint32_t i = 0; i < NSLOTS(a); i++) rt_set_ptr(na, &FP(na, i), FP(a, i));
		*tls = na;
		a = na;
		RT_RELOAD(v);
		RT_UNROOT(1);
	}
	rt_set_ptr(a, &FP(a, id), v);
}

// (the haxe.atomic cells, hxmc.NativeAtomic: hxmc/std/hxmc/rt/Atomics.hx)

#ifdef __EMSCRIPTEN__

static rt_mutator main_mut;
static void *main_tls;
void rt_threads_init(void) { rt_mutator_bind(&main_mut); }
void rt_mutators_foreach(void (*f)(rt_mutator *, void *), void *arg) { f(&main_mut, arg); }
void rt_threads_scan(void *(*fwd)(void *)) {
	if (main_tls) main_tls = fwd(main_tls);
}
void *hxmc_NativeThread_tlsGet(int32_t id) { return tls_get(&main_tls, id); }
void hxmc_NativeThread_tlsSet(int32_t id, void *v) { tls_set(&main_tls, id, v); }
int rt_wait_fd(int fd, int write, double timeout) { return 1; }
int rt_wait_fds(void *pollfds, int n, double timeout) { return 1; }
void rt_sleep(double seconds) { sleep_secs(seconds); }
void rt_preempt(void) {}
void rt_fd_closed(int fd) { (void)fd; }
int32_t hxmc_NativeThread_spawn(void *job) { hx_throw_str("threads are not supported in this build of haxe-in-haxe"); }
int32_t hxmc_NativeThread_current(void) { return 1; }
int32_t hxmc_NativeThread_count(void) { return 1; }
int32_t hxmc_NativeThread_park(double timeout) {
	if (timeout < 0) hx_throw_str("this wait would block forever (threads are not supported in this build)");
	sleep_secs(timeout);
	return 0;
}
void hxmc_NativeThread_unpark(int32_t id) { (void)id; }
void hxmc_NativeThread_yield(void) {}
int32_t hxmc_NativeThread_parallel(void) { return 0; }
void rt_run_main(void (*body)(void)) { body(); }

#else

#ifdef _WIN32
#if RT_GREEN
#error "green threads (tcc, RT_GREEN_THREADS) are not supported on Windows"
#endif
// Windows: the subset of pthreads used below over slim reader/writer locks,
// condition variables and CreateThread; poll is WSAPoll (sockets only); the
// stacks are reservations (rt_win.h)
#include "rt_win.h"
typedef SRWLOCK pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef int pthread_condattr_t;
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define PTHREAD_COND_INITIALIZER CONDITION_VARIABLE_INIT
#define pthread_mutex_init(m, a) InitializeSRWLock(m)
#define pthread_mutex_destroy(m) ((void)(m))
#define pthread_mutex_lock(m) AcquireSRWLockExclusive(m)
#define pthread_mutex_trylock(m) (TryAcquireSRWLockExclusive(m) ? 0 : EBUSY)
#define pthread_mutex_unlock(m) ReleaseSRWLockExclusive(m)
#define pthread_condattr_init(a) ((void)(a))
#define pthread_condattr_setclock(a, c) ((void)(a))
#define pthread_cond_init(c, a) InitializeConditionVariable(c)
#define pthread_cond_destroy(c) ((void)(c))
#define pthread_cond_signal(c) WakeConditionVariable(c)
#define pthread_cond_broadcast(c) WakeAllConditionVariable(c)
#define pthread_cond_wait(c, m) (SleepConditionVariableSRW((c), (m), INFINITE, 0) ? 0 : EINVAL)
// the deadline is on CLOCK_MONOTONIC (deadline_ts)
static int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *ts) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	double left = (double)(ts->tv_sec - now.tv_sec) + (double)(ts->tv_nsec - now.tv_nsec) * 1e-9;
	DWORD ms = left <= 0 ? 0 : left > 4e6 ? 4000000000u : (DWORD)(left * 1000.0 + 0.999);
	if (SleepConditionVariableSRW(c, m, ms, 0)) return 0;
	return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}
#define sched_yield() SwitchToThread()
static int win_poll(struct pollfd *fds, int n, int ms) {
	int r = WSAPoll(fds, (ULONG)n, ms);
	if (r < 0) errno = rt_win_sock_errno(WSAGetLastError());
	return r;
}
#define poll(fds, n, ms) win_poll((fds), (n), (ms))
void rt_win_lock(rt_lock_t *l) { AcquireSRWLockExclusive((SRWLOCK *)l); }
void rt_win_unlock(rt_lock_t *l) { ReleaseSRWLockExclusive((SRWLOCK *)l); }
#else
#include <poll.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#endif
#ifdef __COSMOPOLITAN__
#include <cosmo.h> // IsWindows
#endif

#define CSTACK_BYTES ((size_t)64 << 20) // reserved, committed as touched
#define SSTACK_BYTES ((size_t)64 << 20) // shadow stack (the main thread's is 1 GB, rt.c)

static void *map_stack(size_t bytes) {
	void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	return p == MAP_FAILED ? NULL : p;
}

#if RT_GREEN

// ======== green threads (M:1)

enum { TS_RUNNING, TS_RUNNABLE, TS_PARKED, TS_DONE };

typedef struct rt_thread {
	int32_t id;
	int state;
	int woken; // result of a park: 1 unparked or descriptor ready, 0 timeout
	int unparkable; // parked in hxmc_NativeThread_park (not sleeping or waiting for a descriptor)
	int permit; // unparked while not parked: the next park returns at once
	ucontext_t ctx;
	char *cstack; // NULL for the main thread (its stack is rt_run_main's)
	void **sbase, **sp, **hw; // shadow stack (saved while not running; hw: rt_sp_hw)
	rt_handler *hcur;
	void *exn;
	void *job; // the entry closure until the thread starts (a GC root)
	void *tls; // Tls values (a GC root)
	double deadline; // parked: wake at this time (now_secs), < 0: no deadline
	struct pollfd *fds; // parked on descriptors (on the thread's C stack)
	int nfds;
	struct rt_thread *next; // run queue
	struct rt_thread *all_next, *all_prev; // live threads
} rt_thread;

static rt_thread main_thread;
static rt_thread *cur; // NULL until the first thread operation
static rt_thread *runq_head, *runq_tail;
static rt_thread *all_threads;
static rt_thread **by_id;
static int32_t by_id_cap, next_id = 2;
static rt_thread *zombies; // finished threads whose stacks are freed after switching away
static size_t page_size;
static rt_mutator main_mut; // the one mutator: green threads swap the globals it points at

void rt_threads_init(void) { rt_mutator_bind(&main_mut); }
void rt_mutators_foreach(void (*f)(rt_mutator *, void *), void *arg) { f(&main_mut, arg); }
int32_t hxmc_NativeThread_parallel(void) { return 0; }

// per descriptor: incremented by rt_fd_closed, so a thread woken after its
// descriptor was closed (and the number maybe reused) does not touch it
static uint32_t *fd_gens;
static int fd_gens_cap;

static uint32_t fd_gen(int fd) { return fd >= 0 && fd < fd_gens_cap ? fd_gens[fd] : 0; }

static void ensure_init(void) {
	if (cur) return;
	page_size = (size_t)sysconf(_SC_PAGESIZE);
	main_thread.id = 1;
	main_thread.state = TS_RUNNING;
	main_thread.deadline = -1;
	all_threads = &main_thread;
	by_id_cap = 64;
	by_id = (rt_thread **)calloc(by_id_cap, sizeof(rt_thread *));
	by_id[1] = &main_thread;
	cur = &main_thread;
}

static void enqueue(rt_thread *t) {
	t->state = TS_RUNNABLE;
	t->next = NULL;
	if (runq_tail) runq_tail->next = t;
	else runq_head = t;
	runq_tail = t;
}

static void wake(rt_thread *t, int woken) {
	t->woken = woken;
	enqueue(t);
}

void rt_fd_closed(int fd) {
	if (fd < 0 || cur == NULL) return; // no thread was ever created: nobody waits
	if (fd >= fd_gens_cap) {
		int n = fd_gens_cap ? fd_gens_cap : 256;
		while (n <= fd) n *= 2;
		fd_gens = (uint32_t *)realloc(fd_gens, n * sizeof(uint32_t));
		memset(fd_gens + fd_gens_cap, 0, (n - fd_gens_cap) * sizeof(uint32_t));
		fd_gens_cap = n;
	}
	fd_gens[fd]++;
	// threads parked on it wake now (their poll would watch whatever reuses the number)
	for (rt_thread *t = all_threads; t; t = t->all_next)
		if (t->state == TS_PARKED)
			for (int i = 0; i < t->nfds; i++)
				if (t->fds[i].fd == fd) {
					t->fds[i].revents = POLLNVAL;
					wake(t, 1);
					break;
				}
}

void rt_threads_scan(void *(*fwd)(void *)) {
	if (!cur) {
		if (main_thread.tls) main_thread.tls = fwd(main_thread.tls);
		return;
	}
	for (rt_thread *t = all_threads; t; t = t->all_next) {
		if (t->job) t->job = fwd(t->job);
		if (t->tls) t->tls = fwd(t->tls);
		if (t == cur) continue; // its stack and rt_exn are the globals rt.c scans
		for (void **s = t->sbase; s < t->sp; s++)
			if (*s) *s = fwd(*s);
		rt_zero_above(t->sp, &t->hw);
		if (t->exn) t->exn = fwd(t->exn);
	}
}

static rt_thread *cur_or_main(void) { return cur ? cur : &main_thread; }
void *hxmc_NativeThread_tlsGet(int32_t id) { return tls_get(&cur_or_main()->tls, id); }
void hxmc_NativeThread_tlsSet(int32_t id, void *v) {
	rt_thread *t = cur_or_main(); // the running thread: it cannot end while this runs
	tls_set(&t->tls, id, v);
}

static void reap(void) {
	rt_thread **p = &zombies;
	while (*p) {
		rt_thread *z = *p;
		if (z == cur) {
			p = &z->next;
			continue;
		}
		*p = z->next;
		munmap(z->cstack, CSTACK_BYTES);
		munmap(z->sbase, SSTACK_BYTES);
		free(z);
	}
}

// Waits for the descriptors and timers of parked threads, waking those whose
// event came. block: wait until at least one thread wakes (else just look).
// Returns 0 when no parked thread can ever be woken by an event.
static struct pollfd *poll_buf;
static int poll_cap;

static int wait_events(int block) {
	int nf = 0, any = 0;
	double nearest = -1;
	for (rt_thread *t = all_threads; t; t = t->all_next) {
		if (t->state != TS_PARKED) continue;
		if (t->nfds) {
			any = 1;
			nf += t->nfds;
		}
		if (t->deadline >= 0) {
			any = 1;
			if (nearest < 0 || t->deadline < nearest) nearest = t->deadline;
		}
	}
	if (!any) return 0;
	double now = nearest >= 0 ? now_secs() : 0;
	if (nf > 0) {
		if (nf > poll_cap) {
			poll_cap = nf * 2;
			poll_buf = (struct pollfd *)realloc(poll_buf, poll_cap * sizeof(struct pollfd));
		}
		int k = 0;
		for (rt_thread *t = all_threads; t; t = t->all_next)
			if (t->state == TS_PARKED)
				for (int i = 0; i < t->nfds; i++) {
					poll_buf[k] = t->fds[i];
					poll_buf[k++].revents = 0;
				}
		int ms = 0;
		if (block) {
			if (nearest < 0) ms = -1;
			else if (nearest > now) {
				double d = (nearest - now) * 1000.0 + 0.999;
				ms = d > 2e9 ? 2000000000 : (int)d;
			}
		}
		int r = poll(poll_buf, nf, ms);
		if (r < 0) r = 0; // EINTR: look again
		if (nearest >= 0) now = now_secs();
		k = 0;
		for (rt_thread *t = all_threads; t; t = t->all_next) {
			if (t->state != TS_PARKED || !t->nfds) continue;
			int ready = 0;
			for (int i = 0; i < t->nfds; i++, k++) {
				t->fds[i].revents = poll_buf[k].revents;
				if (poll_buf[k].revents) ready = 1;
			}
			if (ready) wake(t, 1);
		}
	} else if (block && nearest > now) {
		sleep_secs(nearest - now);
		now = now_secs();
	}
	if (nearest >= 0)
		for (rt_thread *t = all_threads; t; t = t->all_next)
			if (t->state == TS_PARKED && t->deadline >= 0 && now >= t->deadline) wake(t, 0);
	return 1;
}

// The running thread has given way (it is parked, runnable again or done):
// run the next runnable thread. Returns when the calling thread is resumed.
static void schedule(void) {
	rt_thread *prev = cur;
	wait_events(0);
	while (!runq_head) {
		if (!wait_events(1)) {
			fflush(stdout);
			fputs("fatal: deadlock, every thread is blocked forever\n", stderr);
			exit(1);
		}
	}
	rt_thread *next = runq_head;
	runq_head = next->next;
	if (!runq_head) runq_tail = NULL;
	next->state = TS_RUNNING;
	if (next == prev) return;
	prev->sp = rt_sp;
	prev->hw = rt_sp_hw;
	prev->sbase = rt_stack_base;
	prev->hcur = rt_hcur;
	prev->exn = rt_exn;
	rt_sp = next->sp;
	rt_sp_hw = next->hw;
	rt_stack_base = next->sbase;
	rt_hcur = next->hcur;
	rt_exn = next->exn;
	cur = next;
	swapcontext(&prev->ctx, &next->ctx);
	reap();
}

static void thread_exit(void) {
	rt_thread *t = cur;
	t->state = TS_DONE;
	if (t->all_prev) t->all_prev->all_next = t->all_next;
	else all_threads = t->all_next;
	if (t->all_next) t->all_next->all_prev = t->all_prev;
	by_id[t->id] = NULL;
	rt_nthreads--;
	t->tls = NULL;
	t->next = zombies;
	zombies = t;
	schedule();
	abort(); // not reached: a finished thread is never resumed
}

static void thread_main(void) {
	reap();
	rt_thread *t = cur;
	void **job = rt_push(1);
	*job = t->job;
	t->job = NULL;
	RT_TRY(h)
		hx_dyn_call(*job, NULL);
	RT_CATCH(h)
		// the hxmc sys.thread.Thread catches everything: only a raw spawn gets here
		void *e = rt_exn;
		rt_exn = 0;
		char *s = hx_str_to_utf8(hx_std_string(e));
		fflush(stdout);
		fprintf(stderr, "Uncaught exception in thread %d: %s\n", (int)t->id, s);
		free(s);
	RT_END_TRY(h)
	thread_exit();
}

int32_t hxmc_NativeThread_spawn(void *job) {
	ensure_init();
	rt_thread *t = (rt_thread *)calloc(1, sizeof(rt_thread));
	if (t) {
		t->cstack = (char *)map_stack(CSTACK_BYTES);
		t->sbase = (void **)map_stack(SSTACK_BYTES);
	}
	if (!t || !t->cstack || !t->sbase) {
		if (t && t->cstack) munmap(t->cstack, CSTACK_BYTES);
		if (t && t->sbase) munmap(t->sbase, SSTACK_BYTES);
		free(t);
		hx_throw_str("cannot allocate the stacks of a new thread");
	}
	mprotect(t->cstack, page_size, PROT_NONE); // guard page: overflow faults
	t->sp = t->hw = t->sbase;
	t->deadline = -1;
	t->job = job;
	getcontext(&t->ctx);
	t->ctx.uc_stack.ss_sp = t->cstack;
	t->ctx.uc_stack.ss_size = CSTACK_BYTES;
	t->ctx.uc_link = NULL;
	makecontext(&t->ctx, thread_main, 0);
	t->id = next_id++;
	if (t->id >= by_id_cap) {
		int32_t n = by_id_cap * 2;
		while (n <= t->id) n *= 2;
		by_id = (rt_thread **)realloc(by_id, n * sizeof(rt_thread *));
		memset(by_id + by_id_cap, 0, (n - by_id_cap) * sizeof(rt_thread *));
		by_id_cap = n;
	}
	by_id[t->id] = t;
	t->all_next = all_threads;
	all_threads->all_prev = t;
	all_threads = t;
	rt_nthreads++;
	enqueue(t);
	if (rt_spawn_hook) rt_spawn_hook();
	return t->id;
}

int32_t hxmc_NativeThread_current(void) { return cur ? cur->id : 1; }

int32_t hxmc_NativeThread_count(void) { return rt_nthreads; }

// blocks until unparked (1) or timeout seconds pass (0); timeout < 0: no timeout
int32_t hxmc_NativeThread_park(double timeout) {
	ensure_init();
	rt_thread *t = cur;
	if (t->permit) {
		t->permit = 0;
		return 1;
	}
	t->deadline = timeout < 0 ? -1 : now_secs() + timeout;
	t->woken = 0;
	t->unparkable = 1;
	t->state = TS_PARKED;
	schedule();
	t->unparkable = 0;
	t->deadline = -1;
	return t->woken;
}

// wakes thread id if it is parked in hxmc_NativeThread_park; else its next park
// returns at once (a thread can be switched out at an allocation between
// queueing itself and parking). A park may thus return early: the waits check
// their state again after each park.
void hxmc_NativeThread_unpark(int32_t id) {
	if (!cur || id <= 0 || id >= by_id_cap) return;
	rt_thread *t = by_id[id];
	if (!t) return;
	if (t->state == TS_PARKED && t->unparkable) wake(t, 1);
	else t->permit = 1;
}

void hxmc_NativeThread_yield(void) {
	if (rt_nthreads <= 1) return;
	enqueue(cur);
	schedule();
}

// called by rt_alloc_slow (each minor collection) while several threads
// exist: a thread that computes without blocking (e.g. spinning on an atomic)
// does not starve the others
void rt_preempt(void) {
	if (!cur) return;
	wait_events(0);
	if (!runq_head) return;
	enqueue(cur);
	schedule();
}

void rt_sleep(double seconds) {
	if (rt_nthreads <= 1) {
		sleep_secs(seconds);
		return;
	}
	if (seconds <= 0) {
		hxmc_NativeThread_yield();
		return;
	}
	rt_thread *t = cur;
	t->deadline = now_secs() + seconds;
	t->state = TS_PARKED;
	schedule();
	t->deadline = -1;
}

int rt_wait_fds(void *pollfds, int n, double timeout) {
	struct pollfd *fds = (struct pollfd *)pollfds;
	for (int i = 0; i < n; i++) fds[i].revents = 0;
	int r = poll(fds, n, 0);
	if (r != 0 || timeout == 0 || rt_nthreads <= 1 || cur == NULL) {
		if (r == 0 && timeout != 0) { // the only thread: just block
			int ms = timeout < 0 ? -1 : (int)(timeout * 1000.0 + 0.999);
			r = poll(fds, n, ms);
		}
		return r != 0; // a poll failure: let the caller's own call report it
	}
	rt_thread *t = cur;
	uint32_t gens_buf[8];
	uint32_t *gens = n <= 8 ? gens_buf : (uint32_t *)malloc(n * sizeof(uint32_t));
	for (int i = 0; i < n; i++) gens[i] = fd_gen(fds[i].fd);
	t->fds = fds;
	t->nfds = n;
	t->deadline = timeout < 0 ? -1 : now_secs() + timeout;
	t->woken = 0;
	t->state = TS_PARKED;
	schedule();
	t->fds = NULL;
	t->nfds = 0;
	t->deadline = -1;
	int closed = 0;
	for (int i = 0; i < n; i++)
		if (fd_gen(fds[i].fd) != gens[i]) closed = 1;
	if (gens != gens_buf) free(gens);
	if (closed) {
		errno = EBADF;
		return -1;
	}
	return t->woken;
}

#else // RT_MT

// ======== OS threads (1:1)

#ifndef _WIN32
#include <sched.h>
#endif

enum { TS_RUNNING, TS_SAFE }; // TS_SAFE: in a safe region or stopped at a safepoint

typedef struct rt_thread {
	rt_mutator mut; // bound when the thread starts (refs to its TLS variables)
	int32_t id;
	int state; // atomic
	int started; // the mutator is bound (under wl)
	void *job; // the entry closure until the thread starts (a GC root)
	void *tls; // Tls values (a GC root)
	void **sbase; // shadow stack mapping (the main thread's is rt.c's)
	struct parker *pk; // park/unpark (never freed: an unpark may find it after the thread ended)
	struct rt_thread *next, *prev; // live threads
} rt_thread;

typedef struct parker {
	pthread_mutex_t m;
	pthread_cond_t c;
	int permit;
} parker;

int rt_mt; // a second thread was started (rt.h rt_lock)
volatile int rt_gc_requested;
static pthread_mutex_t wl = PTHREAD_MUTEX_INITIALIZER; // the world lock
static pthread_cond_t wl_stopped = PTHREAD_COND_INITIALIZER; // a thread became safe (the collector waits)
static pthread_cond_t wl_resumed = PTHREAD_COND_INITIALIZER; // a collection ended
static rt_thread main_thread;
static rt_thread *all_threads; // under wl
static rt_thread **by_id; // under wl
static int32_t by_id_cap, next_id = 2;
static rt_mutator dead_mut; // remembered sets of threads that ended (under wl)
static RT_TLS rt_thread *self;
// dead_mut's remembered set has no TLAB or stack: its refs point here
static void **dead_sp, **dead_hw, **dead_base;
static void *dead_exn;
static char *dead_yptr, *dead_ylim;

static pthread_condattr_t mono_attr; // conditions waiting on CLOCK_MONOTONIC (CLOCK_REALTIME on macOS)

// RT_STATS: threads started, contended mutex acquisitions and their waits,
// collections and the time from a request until every thread had stopped
static int thr_stats;
static unsigned long st_spawned, st_contended, st_stw, st_stw_max_us;
static double st_contended_secs, st_stw_secs;
static void thr_report(void) {
	fprintf(stderr, "threads: %lu started; %lu contended mutex acquisitions (%.3fs waiting); %lu stops of the world, %.3fs until stopped (max %lu us)\n",
		st_spawned, st_contended, st_contended_secs, st_stw, st_stw_secs, st_stw_max_us);
}


int32_t hxmc_NativeThread_parallel(void) { return 1; }

static void cond_init(pthread_cond_t *c) { pthread_cond_init(c, &mono_attr); }

static parker *new_parker(void) {
	parker *p = (parker *)calloc(1, sizeof(parker));
	pthread_mutex_init(&p->m, NULL);
	cond_init(&p->c);
	return p;
}

void rt_threads_init(void) {
	pthread_condattr_init(&mono_attr);
#ifndef __APPLE__
	pthread_condattr_setclock(&mono_attr, CLOCK_MONOTONIC);
#endif
	main_thread.id = 1;
	main_thread.state = TS_RUNNING;
	main_thread.started = 1;
	main_thread.pk = new_parker();
	dead_mut.sp_ref = &dead_sp;
	dead_mut.hw_ref = &dead_hw;
	dead_mut.base_ref = &dead_base;
	dead_mut.exn_ref = &dead_exn;
	dead_mut.yptr_ref = &dead_yptr;
	dead_mut.ylim_ref = &dead_ylim;
	rt_mutator_bind(&main_thread.mut);
	all_threads = &main_thread;
	by_id_cap = 64;
	by_id = (rt_thread **)calloc(by_id_cap, sizeof(rt_thread *));
	by_id[1] = &main_thread;
	self = &main_thread;
	thr_stats = getenv("RT_STATS") != NULL;
	if (thr_stats) atexit(thr_report);
}

static int get_state(rt_thread *t) { return __atomic_load_n(&t->state, __ATOMIC_SEQ_CST); }
static void set_state(rt_thread *t, int s) { __atomic_store_n(&t->state, s, __ATOMIC_SEQ_CST); }
static int gc_requested(void) { return __atomic_load_n(&rt_gc_requested, __ATOMIC_SEQ_CST); }

// under wl, while a collection is requested: stopped until it ends
static void stop_here(void) {
	set_state(self, TS_SAFE);
	pthread_cond_broadcast(&wl_stopped);
	while (gc_requested()) pthread_cond_wait(&wl_resumed, &wl);
	set_state(self, TS_RUNNING);
}

int rt_world_stop(void) {
	double t0 = thr_stats ? now_secs() : 0;
	pthread_mutex_lock(&wl);
	if (gc_requested()) { // another thread is collecting: wait for it as at a safepoint
		stop_here();
		pthread_mutex_unlock(&wl);
		return 0;
	}
	__atomic_store_n(&rt_gc_requested, 1, __ATOMIC_SEQ_CST);
	for (;;) {
		int all = 1;
		for (rt_thread *t = all_threads; t; t = t->next)
			if (t != self && get_state(t) == TS_RUNNING) {
				all = 0;
				break;
			}
		if (all) break;
		pthread_cond_wait(&wl_stopped, &wl);
	}
	if (thr_stats && all_threads->next) {
		double d = now_secs() - t0;
		st_stw++;
		st_stw_secs += d;
		if (d * 1e6 > st_stw_max_us) st_stw_max_us = (unsigned long)(d * 1e6);
	}
	return 1; // wl stays held during the collection
}

void rt_world_resume(void) {
	__atomic_store_n(&rt_gc_requested, 0, __ATOMIC_SEQ_CST);
	pthread_cond_broadcast(&wl_resumed);
	pthread_mutex_unlock(&wl);
}

void rt_safepoint_slow(void) {
	pthread_mutex_lock(&wl);
	if (gc_requested()) stop_here();
	pthread_mutex_unlock(&wl);
}

// Entering a safe region publishes the thread's state (seq_cst): a collector
// that set rt_gc_requested before this thread looked sees TS_SAFE, else this
// thread sees the request and wakes the collector.
// Both keep errno (natives read it after their blocking call).
void rt_blocking_enter(void) {
	set_state(self, TS_SAFE);
	if (gc_requested()) {
		int e = errno;
		pthread_mutex_lock(&wl);
		pthread_cond_broadcast(&wl_stopped);
		pthread_mutex_unlock(&wl);
		errno = e;
	}
}

void rt_blocking_leave(void) {
	set_state(self, TS_RUNNING);
	if (gc_requested()) {
		int e = errno;
		pthread_mutex_lock(&wl);
		if (gc_requested()) stop_here();
		pthread_mutex_unlock(&wl);
		errno = e;
	}
}

// Takes a mutex that a thread may hold while it leaves a safe region (and so
// waits for a collection): a thread blocked on it must be in a safe region.
static void lock_safe(pthread_mutex_t *m) {
	if (pthread_mutex_trylock(m) == 0) return;
	rt_blocking_enter();
	pthread_mutex_lock(m);
	rt_blocking_leave();
}

// under wl (a collection): every started thread, and the remembered sets of
// the threads that ended
void rt_mutators_foreach(void (*f)(rt_mutator *, void *), void *arg) {
	for (rt_thread *t = all_threads; t; t = t->next)
		if (t->started) f(&t->mut, arg);
	f(&dead_mut, arg);
}

void rt_threads_scan(void *(*fwd)(void *)) {
	for (rt_thread *t = all_threads; t; t = t->next) {
		if (t->job) t->job = fwd(t->job);
		if (t->tls) t->tls = fwd(t->tls);
		if (t == self || !t->started) continue; // the collector's own stack and rt_exn: rt.c
		void **sp = *t->mut.sp_ref;
		for (void **s = *t->mut.base_ref; s < sp; s++)
			if (*s) *s = fwd(*s);
		rt_frames_scan(*t->mut.last_fp_ref, *t->mut.last_pc_ref, fwd);
		if (*t->mut.exn_ref) *t->mut.exn_ref = fwd(*t->mut.exn_ref);
	}
}


static void thread_exit(void) {
	rt_thread *t = self;
	rt_blocking_enter(); // touches no heap object from here on
	pthread_mutex_lock(&wl);
	if (t->prev) t->prev->next = t->next;
	else all_threads = t->next;
	if (t->next) t->next->prev = t->prev;
	by_id[t->id] = NULL;
	// its old-to-young slots stay remembered until the next minor collection
	rt_mutator *m = &t->mut;
	if (m->rem_len) {
		if (dead_mut.rem_len + m->rem_len > dead_mut.rem_cap) {
			dead_mut.rem_cap = (dead_mut.rem_len + m->rem_len) * 2;
			dead_mut.rem = (void ***)realloc(dead_mut.rem, dead_mut.rem_cap * sizeof(void **));
		}
		memcpy(dead_mut.rem + dead_mut.rem_len, m->rem, m->rem_len * sizeof(void **));
		dead_mut.rem_len += m->rem_len;
	}
	if (m->robjs_len) {
		if (dead_mut.robjs_len + m->robjs_len > dead_mut.robjs_cap) {
			dead_mut.robjs_cap = (dead_mut.robjs_len + m->robjs_len) * 2;
			dead_mut.robjs = (void **)realloc(dead_mut.robjs, dead_mut.robjs_cap * sizeof(void *));
		}
		memcpy(dead_mut.robjs + dead_mut.robjs_len, m->robjs, m->robjs_len * sizeof(void *));
		dead_mut.robjs_len += m->robjs_len;
	}
	__atomic_fetch_sub(&rt_nthreads, 1, __ATOMIC_SEQ_CST);
	pthread_mutex_unlock(&wl);
	free(m->rem);
	free(m->robjs);
	rt_dyn_thread_exit();
	munmap(t->sbase, SSTACK_BYTES);
	free(t);
}

static void *thread_start(void *arg) {
	rt_thread *t = (rt_thread *)arg;
	self = t;
	rt_sp = rt_stack_base = rt_sp_hw = t->sbase;
	rt_young_ptr = rt_young_limit = NULL;
	rt_hcur = NULL;
	rt_exn = NULL;
	pthread_mutex_lock(&wl); // no collection runs: bind the mutator (the thread is safe until it leaves)
	rt_mutator_bind(&t->mut);
	t->started = 1;
	pthread_mutex_unlock(&wl);
	rt_blocking_leave();
	void **job = rt_push(1);
	*job = t->job;
	t->job = NULL;
	RT_TRY(h)
		hx_dyn_call(*job, NULL);
	RT_CATCH(h)
		// the hxmc sys.thread.Thread catches everything: only a raw spawn gets here
		void *e = rt_exn;
		rt_exn = 0;
		char *s = hx_str_to_utf8(hx_std_string(e));
		fflush(stdout);
		fprintf(stderr, "Uncaught exception in thread %d: %s\n", (int)t->id, s);
		free(s);
	RT_END_TRY(h)
	thread_exit();
	return NULL;
}

#ifdef _WIN32
static DWORD WINAPI win_thread_start(void *arg) {
	thread_start(arg);
	return 0;
}
#endif

int32_t hxmc_NativeThread_spawn(void *job) {
	rt_thread *t = (rt_thread *)calloc(1, sizeof(rt_thread));
	if (t) t->sbase = (void **)map_stack(SSTACK_BYTES);
	if (!t || !t->sbase) {
		free(t);
		hx_throw_str("cannot allocate the stacks of a new thread");
	}
	t->state = TS_SAFE;
	t->pk = new_parker();
	// no safepoint from here to the insertion: `job` is not rooted
	pthread_mutex_lock(&wl);
	t->job = job;
	t->id = next_id++;
	if (t->id >= by_id_cap) {
		int32_t n = by_id_cap * 2;
		while (n <= t->id) n *= 2;
		by_id = (rt_thread **)realloc(by_id, n * sizeof(rt_thread *));
		memset(by_id + by_id_cap, 0, (n - by_id_cap) * sizeof(rt_thread *));
		by_id_cap = n;
	}
	by_id[t->id] = t;
	t->next = all_threads;
	all_threads->prev = t;
	all_threads = t;
	__atomic_fetch_add(&rt_nthreads, 1, __ATOMIC_SEQ_CST);
	st_spawned++;
	rt_mt = 1;
	int32_t id = t->id;
	pthread_mutex_unlock(&wl);
#ifdef _WIN32
	// the C stack reserved (committed as it grows); the thread is not joined
	HANDLE th = CreateThread(NULL, CSTACK_BYTES, win_thread_start, t, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
	int r = th == NULL;
	if (th) CloseHandle(th);
#else
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setstacksize(&attr, CSTACK_BYTES);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_t pt;
	int r = pthread_create(&pt, &attr, thread_start, t);
	pthread_attr_destroy(&attr);
#endif
	if (r != 0) {
		// never started: take it out again (it is safe, its job a root until now)
		pthread_mutex_lock(&wl);
		if (t->prev) t->prev->next = t->next;
		else all_threads = t->next;
		if (t->next) t->next->prev = t->prev;
		by_id[t->id] = NULL;
		__atomic_fetch_sub(&rt_nthreads, 1, __ATOMIC_SEQ_CST);
		pthread_mutex_unlock(&wl);
		munmap(t->sbase, SSTACK_BYTES);
		free(t);
		hx_throw_str("cannot start a new thread");
	}
	if (rt_spawn_hook) rt_spawn_hook();
	return id;
}

int32_t hxmc_NativeThread_current(void) { return self->id; }

int32_t hxmc_NativeThread_count(void) { return __atomic_load_n(&rt_nthreads, __ATOMIC_RELAXED); }

void *hxmc_NativeThread_tlsGet(int32_t id) { return tls_get(&self->tls, id); }
void hxmc_NativeThread_tlsSet(int32_t id, void *v) { tls_set(&self->tls, id, v); }

static void deadline_ts(struct timespec *ts, double timeout) {
#ifdef __APPLE__
	clock_gettime(CLOCK_REALTIME, ts); // macOS: no pthread_condattr_setclock, conditions wait on the real-time clock
#else
	clock_gettime(CLOCK_MONOTONIC, ts);
#endif
	double s = (double)ts->tv_sec + (double)ts->tv_nsec * 1e-9 + timeout;
	ts->tv_sec = (time_t)s;
	ts->tv_nsec = (long)((s - (double)ts->tv_sec) * 1e9);
	if (ts->tv_nsec >= 1000000000L) {
		ts->tv_sec++;
		ts->tv_nsec -= 1000000000L;
	}
}

// waits on c (m held), in a safe region: 0 timed out
static int cond_wait_safe(pthread_cond_t *c, pthread_mutex_t *m, int timed, const struct timespec *ts) {
	rt_blocking_enter();
	int r = timed ? pthread_cond_timedwait(c, m, ts) : pthread_cond_wait(c, m);
	rt_blocking_leave();
	return r != ETIMEDOUT;
}

// blocks until unparked (1) or timeout seconds pass (0); timeout < 0: no
// timeout. An unpark of a thread that is not parked makes its next park
// return at once.
int32_t hxmc_NativeThread_park(double timeout) {
	parker *p = self->pk;
	struct timespec ts;
	if (timeout >= 0) deadline_ts(&ts, timeout);
	lock_safe(&p->m);
	int woken = 1;
	while (!p->permit) {
		if (!cond_wait_safe(&p->c, &p->m, timeout >= 0, &ts)) {
			woken = p->permit;
			break;
		}
	}
	p->permit = 0;
	pthread_mutex_unlock(&p->m);
	return woken;
}

void hxmc_NativeThread_unpark(int32_t id) {
	pthread_mutex_lock(&wl);
	rt_thread *t = id > 0 && id < by_id_cap ? by_id[id] : NULL;
	parker *p = t ? t->pk : NULL;
	pthread_mutex_unlock(&wl);
	if (!p) return;
	lock_safe(&p->m);
	p->permit = 1;
	pthread_cond_signal(&p->c);
	pthread_mutex_unlock(&p->m);
}

void hxmc_NativeThread_yield(void) {
	rt_safepoint();
	sched_yield();
}

void rt_preempt(void) { rt_safepoint(); }

void rt_sleep(double seconds) {
	if (seconds <= 0) {
		hxmc_NativeThread_yield();
		return;
	}
	RT_BLOCKING(sleep_secs(seconds));
}

// per descriptor (below FD_GENS): incremented by rt_fd_closed; a thread
// waiting for a descriptor looks at it every POLL_SLICE seconds, so a close
// by another thread makes its wait fail (EBADF), as with green threads
#define FD_GENS 4096
#define POLL_SLICE 0.1
static uint32_t fd_gens[FD_GENS];

static uint32_t fd_gen(int fd) { return fd >= 0 && fd < FD_GENS ? __atomic_load_n(&fd_gens[fd], __ATOMIC_RELAXED) : 0; }

void rt_fd_closed(int fd) {
	if (fd >= 0 && fd < FD_GENS) __atomic_fetch_add(&fd_gens[fd], 1, __ATOMIC_RELAXED);
}

int rt_wait_fds(void *pollfds, int n, double timeout) {
	struct pollfd *fds = (struct pollfd *)pollfds;
	for (int i = 0; i < n; i++) fds[i].revents = 0;
	int r = poll(fds, n, 0);
	if (r != 0 || timeout == 0) return r != 0; // a poll failure: let the caller's own call report it
	uint32_t gens_buf[8];
	uint32_t *gens = n <= 8 ? gens_buf : (uint32_t *)malloc(n * sizeof(uint32_t));
	for (int i = 0; i < n; i++) gens[i] = fd_gen(fds[i].fd);
	double deadline = timeout < 0 ? -1 : now_secs() + timeout;
	int result = 0, closed = 0;
	rt_blocking_enter();
	for (;;) {
		double slice = POLL_SLICE;
		if (deadline >= 0) {
			double left = deadline - now_secs();
			if (left <= 0) break;
			if (left < slice) slice = left;
		}
		r = poll(fds, n, (int)(slice * 1000.0 + 0.999));
		for (int i = 0; i < n; i++)
			if (fd_gen(fds[i].fd) != gens[i]) closed = 1;
		if (closed) break;
		if (r != 0) {
			if (r > 0 || errno != EINTR) {
				result = 1;
				break;
			}
		}
	}
	rt_blocking_leave();
	if (gens != gens_buf) free(gens);
	if (closed) {
		errno = EBADF;
		return -1;
	}
	return result;
}

// ---- synchronization: pthread mutexes and conditions. Their mutexes are
// taken with lock_safe (a holder may wait for a collection when it leaves a
// wait), waits are safe regions; handles are rooted while their thread waits.

typedef struct {
	pthread_mutex_t m;
	rt_thread *owner; // atomic: compared with self without the lock
	int depth;
} hx_mutex;

typedef struct {
	pthread_cond_t c;
} hx_cond;

typedef struct {
	pthread_mutex_t m;
	pthread_cond_t c;
	int32_t count;
} hx_sem;

static void free_mutex(void *p) {
	pthread_mutex_destroy(&((hx_mutex *)p)->m);
	free(p);
}

static void free_cond(void *p) {
	pthread_cond_destroy(&((hx_cond *)p)->c);
	free(p);
}

static void free_sem(void *p) {
	pthread_mutex_destroy(&((hx_sem *)p)->m);
	pthread_cond_destroy(&((hx_sem *)p)->c);
	free(p);
}

static rt_thread *owner_of(hx_mutex *m) { return __atomic_load_n(&m->owner, __ATOMIC_RELAXED); }

void *hxmc_NativeThread_mutexNew(void) {
	hx_mutex *m = (hx_mutex *)calloc(1, sizeof(hx_mutex));
	pthread_mutex_init(&m->m, NULL);
	return rt_native_new(m, free_mutex);
}

void hxmc_NativeThread_mutexAcquire(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (owner_of(m) == self) {
		m->depth++;
		return;
	}
	if (pthread_mutex_trylock(&m->m) != 0) {
		RT_ROOT(mo); // the handle stays alive while this thread waits
		double t0 = thr_stats ? now_secs() : 0;
		rt_blocking_enter();
		pthread_mutex_lock(&m->m);
		rt_blocking_leave();
		if (thr_stats) {
			__atomic_fetch_add(&st_contended, 1, __ATOMIC_RELAXED);
			st_contended_secs += now_secs() - t0; // under the mutex just taken: approximate across mutexes
		}
		RT_UNROOT(1);
	}
	__atomic_store_n(&m->owner, self, __ATOMIC_RELAXED);
	m->depth = 1;
}

int32_t hxmc_NativeThread_mutexTryAcquire(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (owner_of(m) == self) {
		m->depth++;
		return 1;
	}
	if (pthread_mutex_trylock(&m->m) != 0) return 0;
	__atomic_store_n(&m->owner, self, __ATOMIC_RELAXED);
	m->depth = 1;
	return 1;
}

void hxmc_NativeThread_mutexRelease(void *mo) {
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (owner_of(m) != self) return;
	if (--m->depth > 0) return;
	__atomic_store_n(&m->owner, NULL, __ATOMIC_RELAXED);
	pthread_mutex_unlock(&m->m);
}

void *hxmc_NativeThread_condNew(void) {
	hx_cond *c = (hx_cond *)calloc(1, sizeof(hx_cond));
	cond_init(&c->c);
	return rt_native_new(c, free_cond);
}

// waits for a signal (1) or until timeout seconds pass (0; < 0: no timeout);
// the calling thread holds mutex m, which is released meanwhile (fully) and
// taken back at the same depth. May wake spuriously (as pthread conditions).
int32_t hxmc_NativeThread_condWait(void *co, void *mo, double timeout) {
	hx_cond *c = (hx_cond *)FP(co, 0);
	hx_mutex *m = (hx_mutex *)FP(mo, 0);
	if (owner_of(m) != self) hx_throw_str("Condition.wait: the mutex is not held");
	struct timespec ts;
	if (timeout >= 0) deadline_ts(&ts, timeout);
	RT_ROOT(co);
	RT_ROOT(mo);
	int depth = m->depth;
	__atomic_store_n(&m->owner, NULL, __ATOMIC_RELAXED);
	int r = cond_wait_safe(&c->c, &m->m, timeout >= 0, &ts);
	__atomic_store_n(&m->owner, self, __ATOMIC_RELAXED);
	m->depth = depth;
	RT_UNROOT(2);
	return r;
}

void hxmc_NativeThread_condSignal(void *co) { pthread_cond_signal(&((hx_cond *)FP(co, 0))->c); }
void hxmc_NativeThread_condBroadcast(void *co) { pthread_cond_broadcast(&((hx_cond *)FP(co, 0))->c); }

void *hxmc_NativeThread_semNew(int32_t value) {
	hx_sem *s = (hx_sem *)calloc(1, sizeof(hx_sem));
	pthread_mutex_init(&s->m, NULL);
	cond_init(&s->c);
	s->count = value;
	return rt_native_new(s, free_sem);
}

// takes a unit (1), or times out (0) after timeout seconds (0: just try; < 0: no timeout)
int32_t hxmc_NativeThread_semAcquire(void *so, double timeout) {
	hx_sem *s = (hx_sem *)FP(so, 0);
	struct timespec ts;
	if (timeout > 0) deadline_ts(&ts, timeout);
	RT_ROOT(so);
	lock_safe(&s->m);
	int r = 1;
	while (s->count == 0) {
		if (timeout == 0 || !cond_wait_safe(&s->c, &s->m, timeout > 0, &ts)) {
			r = s->count > 0;
			break;
		}
	}
	if (r) s->count--;
	pthread_mutex_unlock(&s->m);
	RT_UNROOT(1);
	return r;
}

void hxmc_NativeThread_semRelease(void *so) {
	hx_sem *s = (hx_sem *)FP(so, 0);
	RT_ROOT(so);
	lock_safe(&s->m);
	s->count++;
	pthread_cond_signal(&s->c);
	pthread_mutex_unlock(&s->m);
	RT_UNROOT(1);
}

#endif // RT_MT

int rt_wait_fd(int fd, int write, double timeout) {
	struct pollfd p;
	p.fd = fd;
	p.events = write ? POLLOUT : POLLIN;
	p.revents = 0;
	return rt_wait_fds(&p, 1, timeout);
}

// The program's main runs on a reserved stack of RT_STACK_MB (default 1024)
// MB, committed as touched, with a guard page: OCaml 5, which the reference
// compiler is built with, lets the main fiber's stack grow to 1 GB, and deep
// recursion in the port (the typer, Eval-interpreted code, the hxmc regular
// expression engine) needs more than the default 8 MB process stack.
#if defined(_WIN32)
// Windows: main runs on a fiber of the main thread, whose stack is reserved
// at that size (committed as it grows, with the system's guard page)
static void *run_main_fiber;
static void (*run_main_body)(void);
static void WINAPI run_main_entry(void *arg) {
	(void)arg;
	run_main_body();
	SwitchToFiber(run_main_fiber);
}
#elif defined(__APPLE__) && defined(__aarch64__) || defined(RT_CALL_ON_STACK)
// macOS on arm64 has no working ucontext (getcontext fails), nor has musl
// (hxmc's static Linux builds define RT_CALL_ON_STACK): rt_call_on_stack
// calls fn on the stack below top, then returns on the caller's stack
void rt_call_on_stack(void *top, void (*fn)(void));
#if !defined(__APPLE__) && defined(__x86_64__)
__asm__(".text\n"
	".p2align 4\n"
	".hidden rt_call_on_stack\n"
	".globl rt_call_on_stack\n"
	"rt_call_on_stack:\n"
	"	push %rbp\n"
	"	mov %rsp, %rbp\n"
	"	mov %rdi, %rsp\n"
	"	call *%rsi\n"
	"	mov %rbp, %rsp\n"
	"	pop %rbp\n"
	"	ret\n");
#elif !defined(__APPLE__) && defined(__aarch64__)
__asm__(".text\n"
	".p2align 2\n"
	".hidden rt_call_on_stack\n"
	".globl rt_call_on_stack\n"
	"rt_call_on_stack:\n"
	"	stp x29, x30, [sp, #-16]!\n"
	"	mov x29, sp\n"
	"	mov sp, x0\n"
	"	blr x1\n"
	"	mov sp, x29\n"
	"	ldp x29, x30, [sp], #16\n"
	"	ret\n");
#else
__asm__(".text\n"
	".p2align 2\n"
	".private_extern _rt_call_on_stack\n"
	".globl _rt_call_on_stack\n"
	"_rt_call_on_stack:\n"
	"	stp x29, x30, [sp, #-16]!\n"
	"	mov x29, sp\n"
	"	mov sp, x0\n"
	"	blr x1\n"
	"	mov sp, x29\n"
	"	ldp x29, x30, [sp], #16\n"
	"	ret\n");
#endif
#else
static ucontext_t run_main_ret, run_main_ctx;
static void (*run_main_body)(void);
static void run_main_entry(void) { run_main_body(); }
#endif

void rt_run_main(void (*body)(void)) {
	const char *e = getenv("RT_STACK_MB");
	int mb = 1024;
#ifdef __COSMOPOLITAN__
	if (IsWindows()) mb = 256; // Windows commits what is mapped
#endif
	size_t bytes = (size_t)(e ? atoi(e) : mb) << 20;
#ifdef _WIN32
	void *fiber = NULL;
	if (bytes) {
		run_main_body = body;
		run_main_fiber = ConvertThreadToFiber(NULL);
		if (run_main_fiber) fiber = CreateFiberEx(64 << 10, bytes, FIBER_FLAG_FLOAT_SWITCH, run_main_entry, NULL);
	}
	if (!fiber) {
		body();
		return;
	}
	SwitchToFiber(fiber);
#else
	char *stack = bytes ? (char *)map_stack(bytes) : NULL;
	if (!stack) {
		body();
		return;
	}
	mprotect(stack, (size_t)sysconf(_SC_PAGESIZE), PROT_NONE);
#if defined(__APPLE__) && defined(__aarch64__) || defined(RT_CALL_ON_STACK)
	rt_call_on_stack(stack + bytes, body);
#else
	run_main_body = body;
	getcontext(&run_main_ctx);
	run_main_ctx.uc_stack.ss_sp = stack;
	run_main_ctx.uc_stack.ss_size = bytes;
	run_main_ctx.uc_link = &run_main_ret;
	makecontext(&run_main_ctx, run_main_entry, 0);
	swapcontext(&run_main_ret, &run_main_ctx);
#endif
#endif
}

#endif
