package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): an array guarded by a mutex, with a condition for
// blocking pops (rt_thread.c).
class Deque<T> {
	final mutex:Dynamic = NativeThread.mutexNew();
	final cond:Dynamic = NativeThread.condNew();
	var items:Array<T> = [];

	public function new():Void {}

	public function add(i:T):Void {
		NativeThread.mutexAcquire(mutex);
		items.push(i);
		NativeThread.condSignal(cond);
		NativeThread.mutexRelease(mutex);
	}

	public function push(i:T):Void {
		NativeThread.mutexAcquire(mutex);
		items.unshift(i);
		NativeThread.condSignal(cond);
		NativeThread.mutexRelease(mutex);
	}

	public function pop(block:Bool):Null<T> {
		NativeThread.mutexAcquire(mutex);
		while (items.length == 0) {
			if (!block) {
				NativeThread.mutexRelease(mutex);
				return null;
			}
			NativeThread.condWait(cond, mutex, -1);
		}
		var v = items.shift();
		NativeThread.mutexRelease(mutex);
		return v;
	}
}
