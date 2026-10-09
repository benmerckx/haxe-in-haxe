package core.ds;

/**
	Array-backed OCaml list operations; paired operations reject unequal lengths.
	Inline: HashLink passes an Array<T> of a type parameter as a boxed ArrayDyn
	(an allocation and dynamic element access per call); inlining keeps the
	caller's concrete array type.
**/
class List {
	static function sameLength(a:Int, b:Int):Void {
		if (a != b) throw new haxe.exceptions.ArgumentException("lists", "different lengths");
	}

	public static inline function iter2<A, B>(f:A->B->Void, a:Array<A>, b:Array<B>):Void {
		sameLength(a.length, b.length);
		for (i in 0...a.length) f(a[i], b[i]);
	}

	public static inline function forAll2<A, B>(f:A->B->Bool, a:Array<A>, b:Array<B>):Bool {
		var n = Std.int(Math.min(a.length, b.length)), r = true;
		for (i in 0...n) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		if (r) sameLength(a.length, b.length);
		return r;
	}

	public static inline function exists2<A, B>(f:A->B->Bool, a:Array<A>, b:Array<B>):Bool {
		var n = Std.int(Math.min(a.length, b.length)), r = false;
		for (i in 0...n) if (f(a[i], b[i])) {
			r = true;
			break;
		}
		if (!r) sameLength(a.length, b.length);
		return r;
	}

	public static inline function map2<A, B, C>(f:A->B->C, a:Array<A>, b:Array<B>):Array<C> {
		sameLength(a.length, b.length);
		return [for (i in 0...a.length) f(a[i], b[i])];
	}

	public static inline function foldLeft<A, B>(f:A->B->A, acc:A, l:Array<B>):A {
		for (v in l) acc = f(acc, v);
		return acc;
	}

	public static inline function foldRight<A, B>(f:A->B->B, l:Array<A>, acc:B):B {
		var i = l.length;
		while (i > 0) acc = f(l[--i], acc);
		return acc;
	}

	public static inline function find<A>(f:A->Bool, l:Array<A>):A {
		var i = 0;
		while (i < l.length && !f(l[i])) i++;
		if (i == l.length) throw NotFound.raise();
		return l[i];
	}

	public static inline function hd<A>(l:Array<A>):A {
		if (l.length == 0) throw new haxe.Exception("hd");
		return l[0];
	}

	public static inline function tl<A>(l:Array<A>):Array<A> {
		if (l.length == 0) throw new haxe.Exception("tl");
		return l.slice(1);
	}

	public static inline function rev<A>(l:Array<A>):Array<A> {
		var out = l.copy();
		out.reverse();
		return out;
	}

	public static inline function exists<A>(f:A->Bool, l:Array<A>):Bool return core.ds.ArrayTools.exists(l, f);

	public static inline function forAll<A>(f:A->Bool, l:Array<A>):Bool return core.ds.ArrayTools.foreach(l, f);
}
