package typing.matcher;

import core.MetaList.StrictMeta as MetaTag;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting;
import core.Meta;
import core.Abstract;

// haxe/src/typing/matcher/matcherGlobals.ml — mechanical draft; not compile-validated.
class InternalMatchFailure extends haxe.Exception {
	public function new() super("Internal_match_failure");
}

class MatcherGlobals {
	public static function sType(t:T):String return TPrinting.sType(TPrinting.printContext(), t);

	public static function sExprPretty(e:TExpr):String return TPrinting.sExprPretty(false, "", false, sType, e);

	public static function makeOffsetList<A>(left:Int, right:Int, middle:A, other:A):Array<A> {
		if (left < 0 || right < 0) throw "Invalid_argument";
		return [for (_ in 0...left) other].concat([middle]).concat([for (_ in 0...right) other]);
	}

	public static function isExplicitNullOrAbstractOverThat(t:T):Bool return switch t {
		case TMono(r): r.tmType != null && isExplicitNullOrAbstractOverThat(r.tmType);
		case TAbstract(a, [_]) if (a.aPath.pack.length == 0 && a.aPath.name == "Null"): true;
		case TAbstract(a,
			tl) if (!Meta.has(MetaTag.CoreType, a.aMeta)): isExplicitNullOrAbstractOverThat(Abstract.getUnderlyingType(a, tl));
		case TLazy(f): isExplicitNullOrAbstractOverThat(lazyType(f));
		case TType(t, tl): isExplicitNullOrAbstractOverThat(applyTypedef(t, tl));
		case _: false;
	};
}
