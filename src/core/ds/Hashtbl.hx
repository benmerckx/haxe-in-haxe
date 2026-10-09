package core.ds;

import Type as StdType;

/** Structurally keyed table. Binding stacks preserve OCaml add/find/remove behavior.
	Iteration is deterministic insertion order; callers must not use it as binary pool order. */
class Hashtbl<K, V> {
	// Bounded structural hashing for grouping tables; hash values are not serialized.
	public static function hash(value:Dynamic):Int {
		var budget = 100, meaningful = 10, result = 0;
		inline function mix(v:Int):Void result = (result * 65599 + v) | 0;
		function visit(v:Dynamic):Void {
			if (budget-- <= 0 || meaningful <= 0) return;
			if (v == null) {
				mix(0);
				meaningful--;
				return;
			}
			if (Std.isOfType(v, Array)) {
				var a:Array<Dynamic> = v;
				mix(a.length);
				for (x in a) visit(x);
				return;
			}
			switch StdType.typeof(v) {
				case TInt:
					mix(v);
					meaningful--;
				case TFloat:
					var f:Float = v;
					var bytes = haxe.io.Bytes.alloc(8);
					bytes.setDouble(0, f);
					for (i in 0...8) mix(bytes.get(i));
					meaningful--;
				case TBool:
					mix(v ? 1 : 0);
					meaningful--;
				case TClass(c) if (c == String):
					var text:String = v;
					for (i in 0...text.length) mix(text.charCodeAt(i));
					meaningful--;
				case TEnum(_):
					mix(StdType.enumIndex(v));
					for (x in StdType.enumParameters(v)) visit(x);
				case TObject, TClass(_):
					var fields = Reflect.fields(v);
					fields.sort(Reflect.compare);
					for (f in fields) visit(Reflect.field(v, f));
				case _:
					mix(0);
			}
		}
		visit(value);
		return result & 0x3fffffff;
	}

	// Newest binding first, as upstream's bucket lists; this is also the iteration order.
	var entries:Array<MapEntry<K, V>> = [];
	// Lookup index by Key.canonical (newest binding first per bucket). A key
	// without a canonical form switches the table to linear scans with
	// Key.compare, which is the reference behavior.
	var index:Null<haxe.ds.StringMap<Array<MapEntry<K, V>>>> = new haxe.ds.StringMap();

	public function new(size:Int = 0) {}

	function bucketOf(key:K, create:Bool):Null<Array<MapEntry<K, V>>> {
		var c = Key.canonical(key);
		if (c == null) {
			index = null;
			return null;
		}
		var b = index.get(c);
		if (b == null && create) {
			b = [];
			index.set(c, b);
		}
		return b;
	}

	public function add(key:K, value:V):Void {
		var e = new MapEntry(key, value);
		entries.unshift(e);
		if (index != null) {
			var b = bucketOf(key, true);
			if (b != null) b.unshift(e);
		}
	}

	public function replace(key:K, value:V):Void {
		if (index != null) {
			var b = bucketOf(key, false);
			if (index != null) {
				if (b != null && b.length > 0) {
					var e = b[0];
					e.key = key;
					e.value = value;
					return;
				}
				add(key, value);
				return;
			}
		}
		for (e in entries) if (Key.compare(e.key, key) == 0) {
			e.key = key;
			e.value = value;
			return;
		}
		add(key, value);
	}

	public function remove(key:K):Void {
		if (index != null) {
			var b = bucketOf(key, false);
			if (index != null) {
				if (b != null && b.length > 0) {
					var e = b.shift();
					entries.remove(e);
				}
				return;
			}
		}
		for (i in 0...entries.length) if (Key.compare(entries[i].key, key) == 0) {
			entries.splice(i, 1);
			return;
		}
	}

	function lookup(key:K):Null<MapEntry<K, V>> {
		if (index != null) {
			var b = bucketOf(key, false);
			if (index != null) return b == null || b.length == 0 ? null : b[0];
		}
		for (e in entries) if (Key.compare(e.key, key) == 0) return e;
		return null;
	}

	public function find(key:K):V {
		var e = lookup(key);
		if (e == null) throw NotFound.raise();
		return e.value;
	}

	public function findOpt(key:K):Null<V> {
		var e = lookup(key);
		return e == null ? null : e.value;
	}

	public function mem(key:K):Bool return lookup(key) != null;

	public function iter(f:K->V->Void):Void for (e in entries) f(e.key, e.value);

	public function fold<A>(f:K->V->A->A, acc:A):A {
		for (e in entries) acc = f(e.key, e.value, acc);
		return acc;
	}

	public function clear():Void {
		entries = [];
		index = new haxe.ds.StringMap();
	}
}
