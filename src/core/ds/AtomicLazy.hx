package core.ds;

private typedef AtomicLazyMutex = sys.thread.Mutex;

// Port of haxe/src/core/ds/atomicLazy.ml.
private enum AtomicLazyState<T> {
	Unset(callback:Void->T);
	Computing;
	Set(value:T);
}

class AtomicLazy<T> {
	var state:AtomicLazyState<T>;
	var mutex:AtomicLazyMutex = new AtomicLazyMutex();
	// published with release order after `value` (upstream: Atomic.t); read without the mutex
	final ready = new haxe.atomic.AtomicBool(false);
	var value:Null<T> = null;

	function new(state:AtomicLazyState<T>) {
		this.state = state;
		switch state {
			case Set(v):
				value = v;
				ready.store(true);
			case _:
		}
	}

	public static function fromFun<T>(callback:Void->T):AtomicLazy<T> {
		return new AtomicLazy(Unset(callback));
	}

	public static function fromVal<T>(value:T):AtomicLazy<T> {
		return new AtomicLazy(Set(value));
	}

	public function isVal():Bool {
		mutex.acquire();
		var value = switch (state) {
			case Set(_): true;
			case _: false;
		};
		mutex.release();
		return value;
	}

	public function force():T {
		// Lock-free fast path, like upstream's Atomic.get: Set is final once published.
		if (ready.load()) return value;
		while (true) {
			mutex.acquire();
			switch (state) {
				case Set(value):
					mutex.release();
					return value;
				case Computing:
					mutex.release();
					Sys.sleep(0.001);
				case Unset(callback):
					state = Computing;
					mutex.release();
					var v = callback();
					mutex.acquire();
					state = Set(v);
					value = v;
					ready.store(true);
					mutex.release();
					return v;
			}
		}
		throw "Unreachable";
	}
}
