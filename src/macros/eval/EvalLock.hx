package macros.eval;

/**
	OCaml's runtime lock for Eval threads (no upstream module: a deviation).

	Upstream's Eval threads are OCaml threads and domains. OCaml threads of a
	domain share its runtime lock: one runs at a time, switching where a
	thread blocks (Mutex.lock, Condition.wait, Unix I/O, Thread.yield,
	Unix.sleepf, Thread.join, uv_run, ...) and on the tick thread's signal at
	the next allocation or poll point. OCaml values are memory safe under
	races, so upstream relies on that and on its own atomics for the shared
	interpreter state (contexts, prototypes, caches, the global eval state).
	The port runs Eval threads on host threads, which on HashLink run in
	parallel: the same races crash the host or corrupt its tables.

	So every host thread executing Eval code holds this lock:
	- It becomes active (`activate`) when an Eval native is about to start a
	  second host thread that runs Eval code (`EvalThread.spawn`, eval.luv
	  `Thread.create`, the eval.luv thread pool). The calling thread holds it
	  from then on, and so does the thread that drives the compiler: it gives
	  the lock up only where it blocks or yields, as an OCaml thread does
	  (the compilation server's idle wait is such a point). Until then only
	  one thread runs Eval code and nothing is locked (`tick` reads one
	  static).
	- The threads it starts `enter` before running Eval code and `leave`
	  when done.
	- Natives that block release it around the host call (`blocking`, or
	  `leave`/`enter`): the sys.thread and eval.luv primitives, joins, thread
	  messages, sleeps and yields, socket, process and file input, uv_run
	  (whose callbacks `enter` again). Lock order: the lock is never acquired
	  while a host mutex of the natives is held, so a native releases it
	  before it blocks on a host primitive and reacquires it after.
	- The interpreter calls `tick` at function entries and loop iterations.
	  A thread that has waited for the lock for a time slice asks the holder
	  to give way (`yieldRequested`), which it does at its next tick: the
	  lock is handed to the waiters in FIFO order. OCaml's tick is 50 ms;
	  a waiter here asks after `SLICE`.

	Upstream runs domains (`eval.vm.Thread`) in parallel; serialising them is
	one of their possible schedules.
**/
class EvalLock {
	/** Whether more than one host thread may run Eval code (never reset). **/
	public static var active(default, null) = false;

	/** Set by a thread that waited a time slice: the holder gives way at its next `tick`. **/
	public static var yieldRequested = false;

	static inline final SLICE = 0.002;

	static var guard:Null<sys.thread.Mutex> = null;
	static var held = false;
	// FIFO of waiting threads; nothing is allocated while `guard` is held
	static var first:Null<Waiter> = null;
	static var last:Null<Waiter> = null;

	/**
		Called by a thread running Eval code (and so the only one) before it
		starts another host thread that runs Eval code: from then on it holds
		the lock.
	**/
	public static function activate():Void {
		if (active) return;
		guard = new sys.thread.Mutex();
		held = true;
		active = true;
	}

	/** The interpreter's switch point (function entries, loop iterations). **/
	public static inline function tick():Void {
		if (yieldRequested) giveWay();
	}

	/** Takes the lock (when active), waiting for it in FIFO order. **/
	public static function enter():Void {
		if (!active) return;
		var w = new Waiter();
		guard.acquire();
		if (!held) {
			held = true;
			guard.release();
			return;
		}
		if (last == null) first = w
		else last.next = w;
		last = w;
		guard.release();
		// `leave` hands the lock over by releasing `w.lock`
		while (!w.lock.wait(SLICE)) yieldRequested = true;
	}

	/** Gives the lock up (when active): to the first waiter, if any. **/
	public static function leave():Void {
		if (!active) return;
		guard.acquire();
		var w = first;
		if (w != null) {
			first = w.next;
			if (first == null) last = null;
			yieldRequested = false;
			w.lock.release();
		} else {
			held = false;
		}
		guard.release();
	}

	static function giveWay():Void {
		yieldRequested = false;
		leave();
		enter();
	}

	/** `Thread.yield`: gives the lock to the waiters, if any, and lets the host switch. **/
	public static function yieldNow():Void {
		if (!active) {
			Sys.sleep(0.0);
			return;
		}
		leave();
		Sys.sleep(0.0);
		enter();
	}

	/**
		Runs `f`, a host call that may block, without the lock. Activation only
		happens on the thread holding the lock, so a thread that finds the lock
		inactive here has nothing to release, and one that activates it inside
		`f` (a callback of uv_run) gives it up itself (see `EvalLuv.loopRun`).
	**/
	public static inline function blocking<T>(f:Void->T):T {
		return if (active) blockingSlow(f) else f();
	}

	static function blockingSlow<T>(f:Void->T):T {
		leave();
		var r = try f() catch (e:Dynamic) {
			enter();
			throw e;
		}
		enter();
		return r;
	}

	/** `blocking` for a host mutex: tries it first, as OCaml's Mutex.lock does. **/
	public static inline function acquireMutex(m:sys.thread.Mutex):Void {
		if (!m.tryAcquire()) blocking(() -> {
			m.acquire();
			true;
		});
	}

	/** `blocking` for the mutex of a host condition. **/
	public static inline function acquireCondition(c:sys.thread.Condition):Void {
		if (!c.tryAcquire()) blocking(() -> {
			c.acquire();
			true;
		});
	}
}

private class Waiter {
	public final lock = new sys.thread.Lock();
	public var next:Null<Waiter> = null;

	public function new() {}
}
