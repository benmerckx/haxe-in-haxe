// Closures passed to methods that declare the argument with another
// signature: a method takes it as the type of its root declaration (type
// parameters are Dynamic there), so the caller converts it to that type.
// Dispatched calls converted it to the selector's signature, which keeps
// every reference as Dynamic (a generic method of an interface or of an
// erased superclass, run by a @:generic class: a crash, or the closure
// called with the wrong representation), and the closures of methods and
// static functions passed it on unconverted (a crash).
private interface Source<T> {
	function apply<R>(f:T->R):R;
	function callback():T->T;
}

@:generic
private class Value<T> implements Source<T> {
	final value:T;

	public function new(value:T)
		this.value = value;

	public function apply<R>(f:T->R):R
		return f(value);

	public function callback():T->T
		return x -> x;
}

private class Base<T> {
	public function new() {}

	public function apply<R>(f:T->R):R
		return null;
}

@:generic
private class Sub<T> extends Base<T> {
	final value:T;

	public function new(value:T) {
		super();
		this.value = value;
	}

	override public function apply<R>(f:T->R):R
		return f(value);
}

private class Plain {
	public function new() {}

	public function apply(f:Dynamic->Dynamic):Dynamic
		return f(7);
}

class ClosureArgs {
	static function apply(f:Dynamic->Dynamic):Dynamic
		return f(7);

	static function main() {
		// through an interface
		var ints:Source<Int> = new Value(7);
		Sys.println(ints.apply((i:Int) -> i * 3));
		Sys.println(ints.apply((i:Int) -> "int=" + i));
		Sys.println(ints.callback()(8));
		var floats:Source<Float> = new Value(1.5);
		Sys.println(floats.apply((f:Float) -> f * 2));
		Sys.println(floats.callback()(2.25));
		var strings:Source<String> = new Value("abc");
		Sys.println(strings.apply((s:String) -> s.length));
		// through a superclass
		var floatBase:Base<Float> = new Sub(1.5);
		Sys.println(floatBase.apply((f:Float) -> f * 4));
		var intBase:Base<Int> = new Sub(7);
		Sys.println(intBase.apply((i:Int) -> i + 1));
		// closures of those methods
		var a:(Int->Int)->Int = ints.apply;
		Sys.println(a(i -> i * 5));
		var b:(Int->String)->String = ints.apply;
		Sys.println(b(i -> "i=" + i));
		var c:(String->Int)->Int = strings.apply;
		Sys.println(c(s -> s.length * 2));
		var d:(Int->Int)->Int = intBase.apply;
		Sys.println(d(i -> i * 6));
		var e:(Float->String)->String = floatBase.apply;
		Sys.println(e(f -> "f=" + f));
		// closures of a static function and of a method that is not dispatched
		var f:(Int->Int)->Int = apply;
		Sys.println(f(i -> i * 5));
		var g:(Int->Int)->Int = new Plain().apply;
		Sys.println(g(i -> i * 3));
		Sys.println(apply((i:Int) -> i * 2));
	}
}
