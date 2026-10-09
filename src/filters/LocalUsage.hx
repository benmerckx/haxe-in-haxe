package filters;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;

// haxe/src/filters/localUsage.ml — mechanical draft; not compiled or validated.
enum Usage {
	Block(visit:(Usage->Void)->Void);
	Loop(visit:(Usage->Void)->Void);
	Function(visit:(Usage->Void)->Void);
	Declare(variable:TVar);
	Use(variable:TVar);
	Assign(variable:TVar);
}

class LocalUsage {
	public static function localUsage(f:Usage->Void, e:TExpr):Void {
		switch e.eexpr {
			case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, e2):
				localUsage(f, e2);
				f(Assign(v));
			case TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
				f(Assign(v));
			case TLocal(v):
				f(Use(v));
			case TVar(v, eo):
				if (eo != null) localUsage(f, eo);
				f(Declare(v));
			case TFunction(tf):
				f(Function(function(f) {
					for (a in tf.tfArgs) f(Declare(a.variable));
					localUsage(f, tf.tfExpr);
				}));
			case TBlock(l):
				f(Block(function(f) {
					for (e in l) localUsage(f, e);
				}));
			case TWhile(_, _, _):
				f(Loop(function(f) {
					iterLocalUsage(f, e);
				}));
			case TTry(body, catches):
				localUsage(f, body);
				for (c in catches) f(Block(function(f) {
					f(Declare(c.variable));
					localUsage(f, c.expr);
				}));
			case _:
				iterLocalUsage(f, e);
		}
	}

	// Texpr.iter specialised to localUsage: a typed function passed to the generic
	// Texpr.iterWith is wrapped in a new closure per call on HashLink.
	static function iterLocalUsage(f:Usage->Void, e:TExpr):Void switch e.eexpr {
		case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
		case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
			localUsage(f, a);
			localUsage(f, b);
		case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
			TMeta(_, a):
			localUsage(f, a);
		case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
			for (a in el) localUsage(f, a);
		case TObjectDecl(fl):
			for (a in fl) localUsage(f, a.expr);
		case TCall(a, el):
			localUsage(f, a);
			for (a in el) localUsage(f, a);
		case TVar(_, eo) | TReturn(eo):
			if (eo != null) localUsage(f, eo);
		case TFunction(fu):
			for (arg in fu.tfArgs) if (arg.defaultValue != null) localUsage(f, arg.defaultValue);
			localUsage(f, fu.tfExpr);
		case TIf(c, a, b):
			localUsage(f, c);
			localUsage(f, a);
			if (b != null) localUsage(f, b);
		case TSwitch(s):
			localUsage(f, s.switchSubject);
			for (c in s.switchCases) {
				for (a in c.casePatterns) localUsage(f, a);
				localUsage(f, c.caseExpr);
			}
			if (s.switchDefault != null) localUsage(f, s.switchDefault);
		case TTry(a, catches):
			localUsage(f, a);
			for (c in catches) localUsage(f, c.expr);
	}
}
