package sys.thread;

import hxc.NativeThread;

// hxc target (backend/): per-thread values (rt_thread.c keeps them with each
// thread; they go when the thread ends).
class Tls<T> {
	public var value(get, set):Null<T>;

	final id:Int = NativeThread.tlsNew();

	public function new():Void {}

	function get_value():Null<T> {
		return NativeThread.tlsGet(id);
	}

	function set_value(v:Null<T>):Null<T> {
		NativeThread.tlsSet(id, v);
		return v;
	}
}
