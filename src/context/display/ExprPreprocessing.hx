package context.display;

import core.Globals;
import core.Globals.Pos;
import core.DisplayTypes.DisplayModeValue;
import core.display.DisplayPosition;
import core.Ast;

// haxe/src/context/display/exprPreprocessing.ml
class ExprPreprocessing {
	public static function findBeforePos(wasAutoTriggered:Bool, dm:DisplayModeValue, e:Expr):Expr {
		var displayPos = DisplayPosition.displayPosition.get();
		var wasAnnotated = false;
		var isCompletion = false;
		var isAnnotated:Pos->Bool = switch dm {
			case DMDefault:
				isCompletion = true;
				function(p) return !wasAnnotated && DisplayPosition.enclosesPosition(displayPos, p);
			case DMHover:
				function(p) return !wasAnnotated && DisplayPosition.enclosesPositionGt(displayPos, p);
			case _:
				function(p) return !wasAnnotated && DisplayPosition.enclosesPosition(displayPos, p);
		};
		function annotate(e:Expr, dk:DisplayKind):Expr {
			wasAnnotated = true;
			return {expr: EDisplay(e, dk), pos: e.pos};
		}
		function annotateMarked(e:Expr):Expr return annotate(e, DKMarked);
		function mkNull(p:Pos):Expr return annotateMarked({expr: EConst(Ident("null")), pos: p});
		function loopEl(el:Array<Expr>):Array<Expr> {
			var pr = DisplayPosition.displayPosition.withPos(e.pos);
			function loop(i:Int):Array<Expr> {
				if (i >= el.length) return [mkNull(pr)];
				var e = el[i];
				if (e.pos.pmin >= pr.pmax) return [mkNull(pr)].concat(el.slice(i));
				return [e].concat(loop(i + 1));
			}
			if (el.length == 0) return [mkNull(pr)];
			if (el[0].pos.pmin >= pr.pmax) return [mkNull(pr)].concat(el);
			return loop(0);
		}
		var inPattern = false;
		function loop(e:Expr):Expr {
			return switch e.expr {
				case EFunction(FKNamed({pos: p}, _), _) if (isAnnotated(p) && isCompletion):
					throw core.ds.Exit.raise();
				case EVars(vl) if (isAnnotated(e.pos) && isCompletion):
					var acc = [];
					var mark = false;
					for (v in vl) {
						if (mark) acc.push(v);
						else if (isAnnotated(v.evName.pos)) {
							// If the name is the display position, mark the expression
							acc.push(v);
							mark = true;
						} else if (v.evExpr == null) {
							// If there is no expression, we don't have to do anything.
							// Should the display position be on the type-hint, it will
							// be picked up while loading the type.
							acc.push(v);
						} else {
							var e = v.evExpr;
							// Determine the area between the `|` in `var x| = | e`. This is not really
							// correct because we don't want completion on the left side of the `=`, but
							// we cannot determine that correctly without knowing its position.
							// Note: We know `e` itself isn't the display position because this entire
							// algorithm is bottom-up and it would be marked already if it was.
							var p0 = v.evType != null ? v.evType.pos : v.evName.pos;
							var p:Pos = {pfile: p0.pfile, pmin: p0.pmin, pmax: e.pos.pmin};
							var e = if (isAnnotated(p)) annotateMarked(e) else e;
							var v2 = v.clone();
							v2.evExpr = e;
							acc.push(v2);
						}
					}
					// loop2 returns the variables in order, then `EVars (List.rev vl)` reverses them
					acc.reverse();
					var e:Expr = {expr: EVars(acc), pos: e.pos};
					if (wasAnnotated) e else throw core.ds.Exit.raise();
				case EBinop(op = OpAssign | OpAssignOp(_), e1, e2) if (isAnnotated(e.pos) && isCompletion):
					// Special case for assign ops: If the expression is marked, but none of its operands are,
					// we are "probably" interested in the rhs. Like with EVars, this isn't accurate because we
					// could be on the left side of the `=`. I don't think there's a reason for requesting
					// completion there though.
					{expr: EBinop(op, e1, annotateMarked(e2)), pos: e.pos};
				case EBinop(OpOr, e1, {expr: EIf(_, {expr: EConst(Ident("null"))}, null), pos: p1})
					if (isAnnotated(e.pos) && isCompletion && inPattern):
					// This HAS TO come from an attempted `case pattern | guard:` completion (issue #7068).
					var p:Pos = {pfile: p1.pfile, pmin: e1.pos.pmax, pmax: p1.pmin};
					{expr: EBinop(OpOr, e1, mkNull(p)), pos: e.pos};
				case EIf(_, {expr: EConst(Ident("null"))}, null) if (isCompletion && inPattern):
					// This is fine.
					mkNull(e.pos);
				case EBlock([]) if (isAnnotated(e.pos)):
					annotate(e, DKStructure);
				case EBlock([{expr: EDisplay({expr: EConst(Ident(s)), pos: pn}, DKMarked)}]) if (isCompletion):
					var e:Expr = {
						expr: EObjectDecl([
							{key: {name: s, pos: pn, quote: NoQuotes}, expr: {expr: EConst(Ident("null")), pos: Globals.nullPos}}
						]),
						pos: e.pos
					};
					annotate(e, DKStructure);
				case EBlock(el) if (isAnnotated(e.pos) && isCompletion):
					var el = loopEl(el);
					{expr: EBlock(el), pos: e.pos};
				case ECall(e1, el) if (isAnnotated(e.pos) && isCompletion):
					var el = loopEl(el);
					{expr: ECall(e1, el), pos: e.pos};
				case ENew(ptp, el) if (isAnnotated(e.pos) && isCompletion):
					if (isAnnotated(ptp.posFull)
						|| ptp.posFull.pmax >= DisplayPosition.displayPosition.get().pmax) annotateMarked(e) else {
						var el = loopEl(el);
						{expr: ENew(ptp, el), pos: e.pos};
					}
				case EArrayDecl(el) if (isAnnotated(e.pos) && isCompletion):
					var el = loopEl(el);
					{expr: EArrayDecl(el), pos: e.pos};
				case EObjectDecl(fl) if (isAnnotated(e.pos) && isCompletion):
					annotate(e, DKStructure);
				case ESwitch(e1, cases, def) if (isAnnotated(e.pos)):
					// We must be "between" two cases, or at the end of the last case.
					// Let's find the last case which has a position that is < the display
					// position and mark it.
					var didMark = false;
					function markCase(ec:Null<Expr>, p:Pos):Null<Expr> {
						didMark = true;
						var ep = mkNull(p);
						if (ec != null) {
							var ec:Expr = switch ec.expr {
								case EBlock(el): {expr: EBlock(el.concat([ep])), pos: p};
								case _: {expr: EBlock([ec, ep]), pos: p};
							};
							return ec;
						}
						return mkNull(p);
					}
					function loop(i:Int):Array<SwitchCase> {
						if (i >= cases.length) return [];
						var c1 = cases[i];
						if (i == cases.length - 1) {
							var p1 = c1.pos;
							var ec = if (def == null) {
								if (e.pos.pmax > displayPos.pmin) markCase(c1.expr, p1) // no default, must be the last case
								else c1.expr;
							} else {
								var p2 = def.pos;
								if (p1.pmax <= displayPos.pmin && p2.pmin >= displayPos.pmax) markCase(c1.expr,
									p1) // default is beyond display position, mark
								else c1.expr; // default contains display position, don't mark
							};
							return [
								({
									values: c1.values,
									guard: c1.guard,
									expr: ec,
									pos: p1
								} : SwitchCase)
							];
						}
						var c2 = cases[i + 1];
						var p1 = c1.pos, p2 = c2.pos;
						if (p1.pmax <= displayPos.pmin && p2.pmin >= displayPos.pmax) return [
							({
								values: c1.values,
								guard: c1.guard,
								expr: markCase(c1.expr, p1),
								pos: p1
							} : SwitchCase)
						].concat(cases.slice(i + 1));
						return [c1].concat(loop(i + 1));
					}
					var cases = loop(0);
					var def = if (didMark) def else {
						if (def != null && e.pos.pmax > displayPos.pmin) ({expr: markCase(def.expr, def.pos), pos: def.pos} : SwitchDefault)
						else def;
					};
					{expr: ESwitch(e1, cases, def), pos: e.pos};
				case EDisplay(_):
					throw core.ds.Exit.raise();
				case EMeta({meta: m}, {expr: EConst(String(_)), pos: p})
					if (core.Meta.metaEq(core.MetaList.StrictMeta.Markup, m) && isAnnotated(p)):
					annotateMarked(e);
				case EConst(String(_, q)) if ((q != SSingleQuotes || wasAutoTriggered) && isAnnotated(e.pos) && isCompletion):
					// TODO: check if this makes any sense
					throw core.ds.Exit.raise();
				case EConst(Regexp(_)) if (isAnnotated(e.pos) && isCompletion):
					throw core.ds.Exit.raise();
				case EVars(vl) if (isAnnotated(e.pos)):
					// We only want to mark EVars if we're on a var name.
					if (core.ds.ArrayTools.exists(vl, v -> isAnnotated(v.evName.pos))) annotateMarked(e) else throw core.ds.Exit.raise();
				case _:
					if (isAnnotated(e.pos)) annotateMarked(e) else e;
			};
		}
		function map(e:Expr):Expr {
			return switch e.expr {
				case ESwitch(e1, cases, def) if (isAnnotated(e.pos)):
					var e1 = map(e1);
					var cases = cases.map(function(c) {
						var old = inPattern;
						inPattern = true;
						var el = c.values.map(map);
						inPattern = old;
						var eg = c.guard == null ? null : map(c.guard);
						var e = c.expr == null ? null : map(c.expr);
						return ({
							values: el,
							guard: eg,
							expr: e,
							pos: c.pos
						} : SwitchCase);
					});
					var def = def == null ? null : ({expr: def.expr == null ? null : map(def.expr), pos: def.pos} : SwitchDefault);
					loop({expr: ESwitch(e1, cases, def), pos: e.pos});
				case _:
					loop(Ast.mapExpr(map, e));
			};
		}
		return try map(e) catch (_:core.ds.Exit) e;
	}

	public static function findDisplayCall(wasAutoTriggered:Bool, e:Expr):Expr {
		var found = false;
		function handleEl(e:Expr, el:Array<Expr>):Expr {
			function callArgIsMarked():Bool {
				return el.length == 0 || core.ds.ArrayTools.exists(el, e -> e.expr.match(EDisplay(_, DKMarked)));
			}
			if (!wasAutoTriggered || callArgIsMarked()) {
				found = true;
				return syntax.Parser.mkDisplayExpr(e, DKCall);
			}
			return e;
		}
		function loop(e:Expr):Expr {
			return switch e.expr {
				case ECall(_, el) | ENew(_, el) if (!found && DisplayPosition.displayPosition.enclosedIn(e.pos)):
					handleEl(e, el);
				case EArray(e1, e2) if (!found && DisplayPosition.displayPosition.enclosedIn(e2.pos)):
					handleEl(e, [e2]);
				case EDisplay(_, DKCall):
					throw core.ds.Exit.raise();
				case _: e;
			};
		}
		function map(e:Expr):Expr return loop(Ast.mapExpr(map, e));
		return try map(e) catch (_:core.ds.Exit) e;
	}
}
