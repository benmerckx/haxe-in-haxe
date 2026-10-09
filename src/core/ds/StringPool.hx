package core.ds;

// Port of haxe/src/core/ds/stringPool.ml.
class StringPool {
	var indices:Map<String, Int> = new Map();
	var items:StringDynArray = new StringDynArray(16);
	var closed:Bool = false;

	public function new() {}

	// Deviation: HashLink's StringMap truncates keys at the first NUL ("\x00"
	// and "" collide), so on HL keys containing NUL (or starting with the
	// escape character) are escaped injectively into a NUL-free form.
	static inline function key(value:String):String {
		#if hl
		return value.indexOf("\x00") < 0
			&& value.charCodeAt(0) != 1 ? value : "\x01" + value.split("\x01").join("\x01\x01").split("\x00").join("\x01\x02");
		#else
		return value;
		#end
	}

	public function add(value:String):Int {
		if (closed) throw "String pool is finalized";
		var index = items.length;
		indices.set(key(value), index);
		items.add(value);
		return index;
	}

	// The plain key is tried first and the hit verified against the stored string;
	// only misses and NUL-truncation collisions compute the escaped key (scanning
	// every string on every lookup was a large share of HXB writing).
	inline function find(value:String):Null<Int> {
		var i = indices.get(value);
		#if hl
		if (i == null || items.get(i) != value) {
			var k = key(value);
			i = k == value ? null : indices.get(k);
		}
		#end
		return i;
	}

	public function get(value:String):Int {
		var i = find(value);
		if (i == null) throw "Not_found";
		return i;
	}

	public function getOrAdd(value:String):Int {
		var i = find(value);
		return i != null ? i : add(value);
	}

	public function finalize():StringDynArray {
		if (closed) throw "String pool is finalized";
		closed = true;
		return items;
	}
}
