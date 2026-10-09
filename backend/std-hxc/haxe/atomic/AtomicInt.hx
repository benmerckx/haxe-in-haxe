package haxe.atomic;

import hxc.NativeAtomic;

/**
	Atomic integer.
	(hxc target, backend/: an atomic cell of rt_thread.c, see hxc.NativeAtomic.)
**/
abstract AtomicInt(Dynamic) {
	public inline function new(value:Int):Void {
		this = NativeAtomic.intNew(value);
	}

	/**
		Atomically adds `b` to `a`.
		Returns the original value of `a`.
	**/
	public inline function add(b:Int):Int {
		return NativeAtomic.intAdd(this, b);
	}

	/**
		Atomically subtracts `b` from `a`.
		Returns the original value of `a`.
	**/
	public inline function sub(b:Int):Int {
		return NativeAtomic.intSub(this, b);
	}

	/**
		Atomically computes the bitwise and of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function and(b:Int):Int {
		return NativeAtomic.intAnd(this, b);
	}

	/**
		Atomically computes the bitwise or of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function or(b:Int):Int {
		return NativeAtomic.intOr(this, b);
	}

	/**
		Atomically computes the bitwise xor of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function xor(b:Int):Int {
		return NativeAtomic.intXor(this, b);
	}

	/**
		Atomically compares the value of `a` with `expected` and replaces `a` with `replacement` if they are equal..
		Returns the original value of `a`.
	**/
	public inline function compareExchange(expected:Int, replacement:Int):Int {
		return NativeAtomic.intCompareExchange(this, expected, replacement);
	}

	/**
		Atomically exchanges `a` with `value`.
		Returns the original value of `a`.
	**/
	public inline function exchange(value:Int):Int {
		return NativeAtomic.intExchange(this, value);
	}

	/**
		Atomically fetches the value of `a`.
	**/
	public inline function load():Int {
		return NativeAtomic.intLoad(this);
	}

	/**
		Atomically stores `value` into `a`.
		Returns the value that has been stored.
	**/
	public inline function store(value:Int):Int {
		return NativeAtomic.intStore(this, value);
	}
}
