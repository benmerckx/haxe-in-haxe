import haxe.macro.Expr;

class Main {
	// runs inside the compiler, in the port's Eval interpreter
	static macro function fib(n:Int):ExprOf<Int> {
		function f(n:Int):Int return n < 2 ? n : f(n - 1) + f(n - 2);
		return macro $v{f(n)};
	}

	static macro function compiledAt():ExprOf<String>
		return macro $v{Date.now().toString()};

	static function main() {
		trace('fib(24) = ${fib(24)}, computed at compile time');
		trace('compiled at ${compiledAt()}');
	}
}
