package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): a counting semaphore (rt_thread.c).
class Semaphore {
	final sem:Dynamic;

	public function new(value:Int):Void {
		sem = NativeThread.semNew(value);
	}

	public function acquire():Void {
		NativeThread.semAcquire(sem, -1);
	}

	// timeout: null or 0 just tries, < 0 waits forever
	public function tryAcquire(?timeout:Float):Bool {
		return NativeThread.semAcquire(sem, timeout == null ? 0 : timeout);
	}

	public function release():Void {
		NativeThread.semRelease(sem);
	}
}
