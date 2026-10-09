package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): a condition variable and its own re-entrant mutex
// (rt_thread.c). As with pthread conditions, wait may return spuriously.
class Condition {
	final mutex:Dynamic = NativeThread.mutexNew();
	final cond:Dynamic = NativeThread.condNew();

	public function new():Void {}

	public function acquire():Void {
		NativeThread.mutexAcquire(mutex);
	}

	public function tryAcquire():Bool {
		return NativeThread.mutexTryAcquire(mutex);
	}

	public function release():Void {
		NativeThread.mutexRelease(mutex);
	}

	public function wait():Void {
		NativeThread.condWait(cond, mutex, -1);
	}

	public function signal():Void {
		NativeThread.condSignal(cond);
	}

	public function broadcast():Void {
		NativeThread.condBroadcast(cond);
	}
}
