package hxc;

// hxc target (backend/): threads (rt_thread.c), the base of the hxc
// sys.thread package and of haxe.atomic. Native gcc/clang/cosmocc builds run
// threads on OS threads in parallel (1:1); tcc builds run them as green
// threads on one OS thread (M:1, switching where a thread blocks or
// allocates); the wasm build has none. The primitives below behave the same
// in all of them. Threads are ids; the main thread is 1.
extern class NativeThread {
	static function spawn(job:() -> Void):Int; // a new thread running job
	static function current():Int;
	static function count():Int; // live threads
	static function parallel():Bool; // threads run in parallel (1:1 build)
	// blocks until unpark (true) or until `timeout` seconds pass (false); timeout < 0: no timeout
	static function park(timeout:Float):Bool;
	// wakes a thread blocked in park, else makes its next park return at once;
	// park can return early, so callers check their condition again
	static function unpark(id:Int):Void;
	static function yield():Void;

	// re-entrant mutex (handles are freed by the GC)
	static function mutexNew():Dynamic;
	static function mutexAcquire(m:Dynamic):Void;
	static function mutexTryAcquire(m:Dynamic):Bool;
	static function mutexRelease(m:Dynamic):Void; // ignored unless the calling thread holds it
	// condition variable: wait releases the held mutex `m` fully and takes it
	// back at the same depth; true when signaled, false after `timeout`
	// seconds (< 0: none); it may also return early (spuriously)
	static function condNew():Dynamic;
	static function condWait(c:Dynamic, m:Dynamic, timeout:Float):Bool;
	static function condSignal(c:Dynamic):Void;
	static function condBroadcast(c:Dynamic):Void;
	// counting semaphore: acquire takes a unit (true) or gives up after
	// `timeout` seconds (0: just try; < 0: no timeout)
	static function semNew(value:Int):Dynamic;
	static function semAcquire(s:Dynamic, timeout:Float):Bool;
	static function semRelease(s:Dynamic):Void;
	// thread-local values by id
	static function tlsNew():Int;
	static function tlsGet(id:Int):Dynamic;
	static function tlsSet(id:Int, v:Dynamic):Void;
}
