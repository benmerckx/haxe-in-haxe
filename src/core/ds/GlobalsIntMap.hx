package core.ds;

/**
	Persistent `Globals.IntMap` (haxe/src/core/globals.ml): an OCaml `Map` over
	ints compared with `compare i1 i2 = i2 - i1`, so "increasing" key order is
	decreasing numeric order. Kept as parallel arrays sorted in that order;
	`fold` and `iter` visit keys in it, like `Map.fold` and `Map.iter`.
**/
class GlobalsIntMap<V> {
	final keys:Array<Int>;
	final values:Array<V>;

	function new(keys:Array<Int>, values:Array<V>) {
		this.keys = keys;
		this.values = values;
	}

	// The map is persistent, so one empty instance is shared (OCaml's Map.empty).
	static final emptyMap:GlobalsIntMap<Dynamic> = new GlobalsIntMap([], []);

	public static inline function empty<V>():GlobalsIntMap<V> return cast emptyMap;

	// index of the first key not above `key` (keys are sorted in decreasing order)
	function lowerBound(key:Int):Int {
		var lo = 0, hi = keys.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (keys[mid] > key) lo = mid + 1
			else hi = mid;
		}
		return lo;
	}

	public function isEmpty():Bool return keys.length == 0;

	public function cardinal():Int return keys.length;

	public function mem(key:Int):Bool {
		var i = lowerBound(key);
		return i < keys.length && keys[i] == key;
	}

	public function find(key:Int):V {
		var i = lowerBound(key);
		if (i < keys.length && keys[i] == key) return values[i];
		throw NotFound.raise();
	}

	public function findOpt(key:Int):Null<V> {
		var i = lowerBound(key);
		return i < keys.length && keys[i] == key ? values[i] : null;
	}

	public function add(key:Int, value:V):GlobalsIntMap<V> {
		var i = lowerBound(key);
		var k = keys.copy(), v = values.copy();
		if (i < k.length && k[i] == key) v[i] = value
		else {
			k.insert(i, key);
			v.insert(i, value);
		}
		return new GlobalsIntMap(k, v);
	}

	public function remove(key:Int):GlobalsIntMap<V> {
		var i = lowerBound(key);
		if (i >= keys.length || keys[i] != key) return this;
		var k = keys.copy(), v = values.copy();
		k.splice(i, 1);
		v.splice(i, 1);
		return new GlobalsIntMap(k, v);
	}

	public function iter(f:Int->V->Void):Void for (i in 0...keys.length) f(keys[i], values[i]);

	public function fold<A>(f:Int->V->A->A, acc:A):A {
		for (i in 0...keys.length) acc = f(keys[i], values[i], acc);
		return acc;
	}

	public function map<W>(f:V->W):GlobalsIntMap<W> return new GlobalsIntMap(keys.copy(), [for (v in values) f(v)]);

	public function bindings():Array<{key:Int, value:V}> return [for (i in 0...keys.length) {key: keys[i], value: values[i]}];
}
