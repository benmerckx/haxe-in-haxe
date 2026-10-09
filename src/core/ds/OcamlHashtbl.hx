package core.ds;

/**
	OCaml's stdlib `Hashtbl` (5.x, non-randomized), reproduced bucket for
	bucket so that iteration order matches: power-of-two bucket arrays of at
	least 16, new bindings at the head of their bucket, resizing (to twice the
	size once there are more than two bindings per bucket) that keeps each
	bucket's order, and `iter`/`fold` going through buckets 0..n-1 head first.
	The hash and equality functions are those of the `Hashtbl.Make` argument.
**/
class OcamlHashtbl<K, V> {
	final hashFn:K->Int;
	final equalFn:K->K->Bool;
	final initialSize:Int;
	var data:Array<Null<OcamlHashtblCell<K, V>>>;
	var size = 0;

	public function new(hashFn:K->Int, equalFn:K->K->Bool, initialSize = 0) {
		this.hashFn = hashFn;
		this.equalFn = equalFn;
		var s = 16;
		while (s < initialSize) s *= 2;
		this.initialSize = s;
		data = [for (_ in 0...s) null];
	}

	inline function keyIndex(key:K):Int return hashFn(key) & (data.length - 1);

	public function length():Int return size;

	public function clear():Void {
		if (size > 0) {
			size = 0;
			for (i in 0...data.length) data[i] = null;
		}
	}

	public function reset():Void {
		size = 0;
		data = [for (_ in 0...initialSize) null];
	}

	public function copy():OcamlHashtbl<K, V> {
		var h = new OcamlHashtbl<K, V>(hashFn, equalFn, initialSize);
		h.size = size;
		h.data = [
			for (b in data) {
				var head:Null<OcamlHashtblCell<K, V>> = null,
					tail:Null<OcamlHashtblCell<K, V>> = null;
				var c = b;
				while (c != null) {
					var n = new OcamlHashtblCell(c.key, c.data, null);
					if (tail == null) head = n
					else tail.next = n;
					tail = n;
					c = c.next;
				}
				head;
			}
		];
		return h;
	}

	function resize():Void {
		var odata = data;
		var nsize = odata.length * 2;
		var ndata:Array<Null<OcamlHashtblCell<K, V>>> = [for (_ in 0...nsize) null];
		var tails:Array<Null<OcamlHashtblCell<K, V>>> = [for (_ in 0...nsize) null];
		data = ndata;
		for (b in odata) {
			var c = b;
			while (c != null) {
				var next = c.next;
				var nidx = keyIndex(c.key);
				var tail = tails[nidx];
				if (tail == null) ndata[nidx] = c
				else tail.next = c;
				tails[nidx] = c;
				c = next;
			}
		}
		for (t in tails) if (t != null) t.next = null;
	}

	public function add(key:K, value:V):Void {
		var i = keyIndex(key);
		data[i] = new OcamlHashtblCell(key, value, data[i]);
		size++;
		if (size > data.length << 1) resize();
	}

	public function remove(key:K):Void {
		var i = keyIndex(key);
		var prev:Null<OcamlHashtblCell<K, V>> = null;
		var c = data[i];
		while (c != null) {
			if (equalFn(c.key, key)) {
				size--;
				if (prev == null) data[i] = c.next
				else prev.next = c.next;
				return;
			}
			prev = c;
			c = c.next;
		}
	}

	public function find(key:K):V {
		var c = data[keyIndex(key)];
		while (c != null) {
			if (equalFn(key, c.key)) return c.data;
			c = c.next;
		}
		throw NotFound.raise();
	}

	public function findOpt(key:K):Null<V> {
		var c = data[keyIndex(key)];
		while (c != null) {
			if (equalFn(key, c.key)) return c.data;
			c = c.next;
		}
		return null;
	}

	/** `Hashtbl.find_all`: every binding of `key`, most recent first. **/
	public function findAll(key:K):Array<V> {
		var out = [];
		var c = data[keyIndex(key)];
		while (c != null) {
			if (equalFn(c.key, key)) out.push(c.data);
			c = c.next;
		}
		return out;
	}

	public function replace(key:K, value:V):Void {
		var i = keyIndex(key);
		var c = data[i];
		while (c != null) {
			if (equalFn(c.key, key)) {
				c.key = key;
				c.data = value;
				return;
			}
			c = c.next;
		}
		data[i] = new OcamlHashtblCell(key, value, data[i]);
		size++;
		if (size > data.length << 1) resize();
	}

	public function mem(key:K):Bool {
		var c = data[keyIndex(key)];
		while (c != null) {
			if (equalFn(c.key, key)) return true;
			c = c.next;
		}
		return false;
	}

	public function iter(f:K->V->Void):Void {
		for (b in data) {
			var c = b;
			while (c != null) {
				f(c.key, c.data);
				c = c.next;
			}
		}
	}

	public function fold<A>(f:K->V->A->A, acc:A):A {
		for (b in data) {
			var c = b;
			while (c != null) {
				acc = f(c.key, c.data, acc);
				c = c.next;
			}
		}
		return acc;
	}

	/**
		OCaml's `Hashtbl.hash` / `Int.hash` on an int in the 32-bit range
		(caml_hash_mix_intnat, then FINAL_MIX). caml_hash mixes the tagged value
		2n+1; caml_hash_mix_intnat folds its high word into the low one, which for
		32-bit n leaves the low 32 bits of 2n+1.
	**/
	public static function hashInt(n:Int):Int {
		var h = mixWord(0, (n << 1) | 1);
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	static inline function rotl32(x:Int, n:Int):Int return (x << n) | (x >>> (32 - n));

	static inline function mixWord(h:Int, d:Int):Int {
		d = mul32(d, 0xcc9e2d51);
		d = rotl32(d, 15);
		d = mul32(d, 0x1b873593);
		h ^= d;
		h = rotl32(h, 13);
		return (mul32(h, 5) + 0xe6546b64) | 0;
	}
}

class OcamlHashtblCell<K, V> {
	public var key:K;
	public var data:V;
	public var next:Null<OcamlHashtblCell<K, V>>;

	public inline function new(key:K, data:V, next:Null<OcamlHashtblCell<K, V>>) {
		this.key = key;
		this.data = data;
		this.next = next;
	}
}
