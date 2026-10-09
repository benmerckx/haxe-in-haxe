abstract Celsius(Float) from Float {
	public inline function toFahrenheit():Float
		return this * 9 / 5 + 32;
}

class Stack<T> {
	var items:Array<T> = [];
	public var length(get, never):Int;

	public function new() {}

	public function push(x:T)
		items.push(x);

	public function pop():Null<T>
		return items.pop();

	function get_length()
		return items.length;
}

class Main {
	static function main() {
		var s = new Stack<String>();
		for (w in "the quick brown fox".split(" "))
			s.push(w);
		var out = [];
		while (s.length > 0)
			out.push(s.pop());
		trace(out.join(" "));

		var t:Celsius = 21.5;
		trace('21.5 C = ${t.toFahrenheit()} F');

		var squares = [for (i in 1...6) i * i];
		trace('squares: $squares');
	}
}
