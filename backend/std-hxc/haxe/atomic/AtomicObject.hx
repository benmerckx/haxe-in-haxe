package haxe.atomic;

import hxc.NativeAtomic;

/**
	Atomic object. Use with care, this does not magically make it thread-safe to mutate objects.
	(hxc target, backend/: an atomic cell of rt_thread.c, see hxc.NativeAtomic.)
**/
abstract AtomicObject<T:{}>(Dynamic) {
	public inline function new(value:T):Void {
		this = NativeAtomic.objNew(value);
	}

	/**
		Atomically compares the value of `a` with `expected` and replaces `a` with `replacement` if they are equal..
		Returns the original value of `a`.

		Note that comparison is done by reference, and not by value.
		While this is expected for most objects, this might give unexpected behaviour for strings.
	**/
	public inline function compareExchange(expected:T, replacement:T):T {
		return NativeAtomic.objCompareExchange(this, expected, replacement);
	}

	/**
		Atomically exchanges `a` with `value`.
		Returns the original value of `a`.
	**/
	public inline function exchange(value:T):T {
		return NativeAtomic.objExchange(this, value);
	}

	/**
		Atomically fetches the value of `a`.
	**/
	public inline function load():T {
		return NativeAtomic.objLoad(this);
	}

	/**
		Atomically stores `value` into `a`.
		Returns the value that has been stored.
	**/
	public inline function store(value:T):T {
		return NativeAtomic.objStore(this, value);
	}
}
