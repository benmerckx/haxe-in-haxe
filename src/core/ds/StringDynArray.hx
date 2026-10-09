package core.ds;

// Port of haxe/src/core/ds/stringDynArray.ml.
class StringDynArray {
	var values:Array<String>;

	public var length(default, null):Int = 0;

	public function new(capacity:Int) {
		values = [];
		for (_ in 0...capacity) values.push("");
	}

	public function add(value:String):Void {
		var capacity = values.length;
		if (length == capacity) {
			var expanded:Array<String> = [];
			for (_ in 0...(capacity * 2)) expanded.push("");
			for (index in 0...capacity) expanded[index] = values[index];
			values = expanded;
		}
		values[length] = value;
		length++;
	}

	public function get(index:Int):String {
		return values[index];
	}

	public function iter(callback:String->Void):Void {
		for (index in 0...length) callback(values[index]);
	}
}
