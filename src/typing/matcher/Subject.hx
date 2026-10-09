package typing.matcher;

import core.TType;
import core.Globals.Pos;
import core.Texpr.Builder;
import typing.matcher.Bind;

// haxe/src/typing/matcher/subject.ml — mechanical draft; not compile-validated.
class Subject {
	final e:TExpr;
	final bind:Null<Bind>;

	public function new(e:TExpr, bind:Null<Bind>) {
		this.e = e;
		this.bind = bind;
	}

	public function getExpr():TExpr {
		if (bind != null) bind.bStatus = BindUsed;
		return e;
	}

	public function getScopedExpr():{expr:TExpr, reset:Void->Void} {
		if (bind != null && bind.bStatus == BindDeferred) {
			var assigned = Builder.binop(OpAssign, e, bind.bExpr, e.etype, e.epos);
			bind.bStatus = BindUsed;
			return {
				expr: assigned,
				reset: function() {
					bind.bStatus = BindDeferred;
				}
			};
		}
		if (bind != null && bind.bStatus == BindUnused) bind.bStatus = BindUsed;
		return {expr: e, reset: function() {}};
	}

	public function getAssignedExpr():TExpr {
		var scoped = getScopedExpr();
		scoped.reset();
		return scoped.expr;
	}

	public function getPos():Pos return e.epos;

	public function toString():String return MatcherGlobals.sExprPretty(e);
}
