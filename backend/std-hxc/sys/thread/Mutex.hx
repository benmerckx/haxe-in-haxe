package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): a re-entrant mutex (rt_thread.c: a pthread mutex
// with OS threads, a queue of parked threads with green threads). A thread
// blocked on it is in a safe region, so a collection never waits for it.
class Mutex {
	final handle:Dynamic = NativeThread.mutexNew();

	public function new():Void {}

	public function acquire():Void {
		NativeThread.mutexAcquire(handle);
	}

	public function tryAcquire():Bool {
		return NativeThread.mutexTryAcquire(handle);
	}

	public function release():Void {
		NativeThread.mutexRelease(handle);
	}
}
