package core.ds;

/**
	An Int -> Int map with cheap snapshots, standing in for an OCaml persistent
	map that is saved and restored around a scope (`let old = !vars in ...;
	vars := old`). Copying a mutable map at every scope is quadratic in large
	functions; `mark` and `rollback` undo just the sets and removes made since
	the mark.
**/
class ScopedIntMap {
	final map = new haxe.ds.IntMap<Int>();
	final logKeys:Array<Int> = [];
	final logPrev:Array<Int> = [];
	final logHad:Array<Bool> = [];

	public function new() {}

	public inline function exists(k:Int):Bool return map.exists(k);

	public inline function get(k:Int):Int return map.get(k);

	public function set(k:Int, v:Int):Void {
		record(k);
		map.set(k, v);
	}

	public function remove(k:Int):Void {
		if (map.exists(k)) {
			record(k);
			map.remove(k);
		}
	}

	function record(k:Int):Void {
		var had = map.exists(k);
		logKeys.push(k);
		logHad.push(had);
		logPrev.push(had ? map.get(k) : 0);
	}

	public inline function mark():Int return logKeys.length;

	public function rollback(m:Int):Void {
		var i = logKeys.length;
		while (i > m) {
			i--;
			var k = logKeys[i];
			if (logHad[i]) map.set(k, logPrev[i])
			else map.remove(k);
		}
		logKeys.resize(m);
		logHad.resize(m);
		logPrev.resize(m);
	}
}
