package core.ds;

/** Persistent ordered lookup for non-string upstream keys. */
class PersistentMap<K, V> {
	final entries:Array<MapEntry<K, V>>;

	public function new(?entries:Array<MapEntry<K, V>>) this.entries = entries == null ? [] : entries;

	public static function empty<K, V>():PersistentMap<K, V> return new PersistentMap();

	// Entries are sorted by Key.compare with unique keys: index of the first entry not below key.
	function lowerBound(key:K):Int {
		var lo = 0, hi = entries.length;
		// String keys (typer locals): compare directly instead of dispatching in Key.compare.
		var sk = Key.asString(key);
		if (sk != null) {
			while (lo < hi) {
				var mid = (lo + hi) >> 1, ek = Key.asString(entries[mid].key);
				if ((ek != null ? Key.compareStrings(ek, sk) : Key.compare(entries[mid].key, key)) < 0) lo = mid + 1;
				else hi = mid;
			}
			return lo;
		}
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (Key.compare(entries[mid].key, key) < 0) lo = mid + 1;
			else hi = mid;
		}
		return lo;
	}

	inline function indexOf(key:K):Int {
		var i = lowerBound(key);
		return i < entries.length && Key.compare(entries[i].key, key) == 0 ? i : -1;
	}

	public function add(key:K, value:V):PersistentMap<K, V> {
		var i = lowerBound(key), out = entries.copy();
		if (i < out.length && Key.compare(out[i].key, key) == 0) out[i] = {key: key, value: value};
		else out.insert(i, {key: key, value: value});
		return new PersistentMap(out);
	}

	public function remove(key:K):PersistentMap<K, V> return new PersistentMap(entries.filter(function(e) return Key.compare(e.key,
		key) != 0));

	public function find(key:K):V {
		var i = indexOf(key);
		if (i < 0) throw NotFound.raise();
		return entries[i].value;
	}

	public function findOpt(key:K):Null<V> {
		var i = indexOf(key);
		return i < 0 ? null : entries[i].value;
	}

	public function mem(key:K):Bool return indexOf(key) >= 0;

	public function iter(f:K->V->Void):Void for (e in entries) f(e.key, e.value);

	public function foldi<A>(f:K->V->A->A, acc:A):A {
		for (e in entries) acc = f(e.key, e.value, acc);
		return acc;
	}

	public function keys():Iterator<K> return entries.map(function(e) return e.key).iterator();

	public function iterator():Iterator<V> return entries.map(function(e) return e.value).iterator();
}
