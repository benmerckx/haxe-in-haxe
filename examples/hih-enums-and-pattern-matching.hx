enum Expr {
	Num(v:Float);
	Add(a:Expr, b:Expr);
	Mul(a:Expr, b:Expr);
	Neg(e:Expr);
}

class Main {
	static function eval(e:Expr):Float
		return switch e {
			case Num(v): v;
			case Add(a, b): eval(a) + eval(b);
			case Mul(a, b): eval(a) * eval(b);
			case Neg(e): -eval(e);
		}

	static function show(e:Expr):String
		return switch e {
			case Num(v): '$v';
			case Add(a, b): '(${show(a)} + ${show(b)})';
			case Mul(a, b): '${show(a)} * ${show(b)}';
			case Neg(e): '-${show(e)}';
		}

	static function main() {
		var e = Mul(Add(Num(1), Num(2)), Neg(Num(4)));
		trace(show(e) + " = " + eval(e));
	}
}
