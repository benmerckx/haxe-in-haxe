package core.ds;

import sys.thread.Mutex;

// Port of haxe/src/core/ds/threadSafeHashtbl.ml.
class ThreadSafeHashtbl<Key, Value> {
	var values:Array<{key:Key, value:Value}> = [];
	var mutex:Mutex = new Mutex();

	public function new(size:Int) {}

	public function add(key:Key, value:Value):Void {
		protect(function() values.push({key: key, value: value}));
	}

	public function replace(key:Key, value:Value):Void {
		protect(function() {
			removeUnsafe(key);
			values.push({key: key, value: value});
		});
	}

	public function find(key:Key):Value {
		return protect(function() {
			return findUnsafe(key);
		});
	}

	public function findOrAdd(key:Key, create:Void->Value):Value {
		mutex.acquire();
		try {
			var result:Value;
			try result = findUnsafe(key)
			catch (_:Dynamic) {
				result = create();
				values.push({key: key, value: result});
			}
			mutex.release();
			return result;
		} catch (error:haxe.Exception) {
			mutex.release();
			throw error;
		}
	}

	public function exists(key:Key):Bool {
		return protect(function() return hasUnsafe(key));
	}

	public function remove(key:Key):Void {
		protect(function() removeUnsafe(key));
	}

	public function fold<Result>(callback:Key->Value->Result->Result, initial:Result):Result {
		return protect(function() {
			var result = initial;
			for (entry in values) result = callback(entry.key, entry.value, result);
			return result;
		});
	}

	function protect<Result>(callback:Void->Result):Result {
		mutex.acquire();
		try {
			var result = callback();
			mutex.release();
			return result;
		} catch (error:haxe.Exception) {
			mutex.release();
			throw error;
		}
	}

	function findUnsafe(key:Key):Value {
		for (index in 0...values.length) {
			var entry = values[values.length - index - 1];
			if (entry.key == key) return entry.value;
		}
		throw "Not_found";
	}

	function hasUnsafe(key:Key):Bool {
		try {
			findUnsafe(key);
			return true;
		} catch (_:Dynamic) return false;
	}

	function removeUnsafe(key:Key):Void {
		var retained = [];
		for (entry in values) if (entry.key != key) retained.push(entry);
		values = retained;
	}
}
