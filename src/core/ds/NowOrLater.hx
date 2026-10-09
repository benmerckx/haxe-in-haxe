package core.ds;

import sys.thread.Mutex;

// Port of haxe/src/core/ds/nowOrLater.ml.
class NowOrLater {
	var now:Mutex = new Mutex();
	var running:Bool = false;
	var laterMutex:Mutex = new Mutex();
	var later:Array<Void->Void> = [];

	public function new() {}

	public function tryNow(callback:Void->Void):Void {
		if (!running && now.tryAcquire()) {
			try {
				running = true;
				callback();
				running = false;
				now.release();
			} catch (error:haxe.Exception) {
				running = false;
				now.release();
				throw error;
			}
		} else {
			laterMutex.acquire();
			later.push(callback);
			laterMutex.release();
		}
	}

	public function handleLater():Void {
		while (true) {
			laterMutex.acquire();
			var callback = later.shift();
			laterMutex.release();
			if (callback == null) return;
			callback();
		}
	}
}
