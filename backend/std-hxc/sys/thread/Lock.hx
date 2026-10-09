package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): a counting semaphore starting at 0 (rt_thread.c):
// each release lets exactly one wait through.
class Lock {
	final sem:Dynamic = NativeThread.semNew(0);

	public function new():Void {}

	public function wait(?timeout:Float):Bool {
		return NativeThread.semAcquire(sem, timeout == null ? -1 : (timeout > 0 ? timeout : 0));
	}

	public function release():Void {
		NativeThread.semRelease(sem);
	}
}
