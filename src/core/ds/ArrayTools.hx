package core.ds;

/**
	Lambda.exists/foreach/count for arrays. Lambda takes an Iterable, so on
	static targets the iterator() call and every step go through dynamic calls.
**/
class ArrayTools {
	public static inline function exists<T>(a:Array<T>, f:T->Bool):Bool {
		var found = false;
		for (x in a) if (f(x)) {
			found = true;
			break;
		}
		return found;
	}

	public static inline function foreach<T>(a:Array<T>, f:T->Bool):Bool {
		var all = true;
		for (x in a) if (!f(x)) {
			all = false;
			break;
		}
		return all;
	}

	public static inline function count<T>(a:Array<T>, ?pred:T->Bool):Int {
		var n = 0;
		if (pred == null) n = a.length;
		else for (x in a) if (pred(x)) n++;
		return n;
	}

	public static inline function has<T>(a:Array<T>, elt:T):Bool {
		var found = false;
		for (x in a) if (x == elt) {
			found = true;
			break;
		}
		return found;
	}

	public static inline function find<T>(a:Array<T>, f:T->Bool):Null<T> {
		var r:Null<T> = null;
		for (x in a) if (f(x)) {
			r = x;
			break;
		}
		return r;
	}

	public static inline function iter<T>(a:Array<T>, f:T->Void):Void {
		for (x in a) f(x);
	}

	public static inline function empty<T>(a:Array<T>):Bool return a.length == 0;
}
