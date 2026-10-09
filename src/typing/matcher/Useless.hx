package typing.matcher;

import core.Message;
import core.Globals;
import core.Globals.Pos;
import typing.matcher.Pattern;
import typing.matcher.Constructor;
import typing.matcher.Case;
import context.Typecore;

// haxe/src/typing/matcher/useless.ml — mechanical draft; not compile-validated.
enum UselessResult {
	False;
	Pos(pos:Pos);
	True;
}

typedef PatternMatrix = Array<Array<PatternData>>;

@:structInit class LocatedUseless {
	public var result:UselessResult;
	public var pos:Pos;

	public inline function new(result:UselessResult, pos:Pos) {
		this.result = result;
		this.pos = pos;
	}

	public inline function clone():LocatedUseless return new LocatedUseless(result, pos);
}

class Useless {
	public static function specialize(isTuple:Bool, con:ConstructorData, matrix:PatternMatrix):PatternMatrix {
		var acc:PatternMatrix = [], remaining = matrix.copy();
		while (remaining.length > 0) {
			var row = remaining.shift();
			if (row.length == 0) continue;
			var first = row[0], tail = row.slice(1);
			switch first.kind {
				case PatConstructor(other, patterns) if (!isTuple && Constructor.equal(con, other)):
					acc.push(patterns.concat(tail));
				case PatTuple(patterns) if (isTuple):
					acc.push(patterns.concat(tail));
				case PatAny:
					var any:PatternData = {kind: PatAny, pos: first.pos};
					acc.push([for (_ in 0...Constructor.arity(con)) any].concat(tail));
				case PatBind(_, pat):
					remaining.unshift([pat].concat(tail));
				case _:
			}
		}
		return acc;
	}

	public static function defaultMatrix(matrix:PatternMatrix):PatternMatrix {
		var acc:PatternMatrix = [];
		for (row in matrix) if (row.length > 0) switch row[0].kind {
			case PatBind(_, {kind: PatAny}) | PatAny:
				acc.push(row.slice(1));
			case _:
		}
		return acc;
	}

	public static function u(matrix:PatternMatrix, q:Array<PatternData>):Bool {
		if (q.length == 0) return matrix.length == 0;
		var ql = q.slice(1);
		function loop(pat:PatternData):Bool return switch pat.kind {
			case PatConstructor(con, patterns): u(specialize(false, con, matrix), patterns.concat(ql));
			case PatTuple(patterns): u(specialize(true, {kind: ConConst(TNull), pos: pat.pos}, matrix), patterns.concat(ql));
			case PatAny: u(defaultMatrix(matrix), ql);
			case PatOr(pat1, pat2): u(matrix, [pat1].concat(ql)) || u(matrix, [pat2].concat(ql));
			case PatBind(_, pat1): loop(pat1);
			case PatExtractor(_): true;
		};
		return loop(q[0]);
	}

	public static function transferColumn(source:PatternMatrix, target:PatternMatrix):{source:PatternMatrix, target:PatternMatrix} {
		if (source.length != target.length) throw "Invalid_argument: List.fold_left2";
		var from:PatternMatrix = [], into:PatternMatrix = [];
		for (i in 0...source.length) if (source[i].length > 0) {
			from.push(source[i].slice(1));
			into.push([source[i][0]].concat(target[i]));
		}
		return {source: from, target: into};
	}

	public static function copy(matrix:PatternMatrix):PatternMatrix return matrix.map(function(_) return []);

	public static function specializePrime(isTuple:Bool, con:ConstructorData, pM:PatternMatrix, qM:PatternMatrix,
			rM:PatternMatrix):{p:PatternMatrix, q:PatternMatrix, r:PatternMatrix} {
		var arity = Constructor.arity(con);
		var pAcc:PatternMatrix = [],
			qAcc:PatternMatrix = [],
			rAcc:PatternMatrix = [];
		var ps = pM.copy(), qs = qM.copy(), rs = rM.copy();
		while (ps.length > 0) {
			if (qs.length == 0 || rs.length == 0) throw "Invalid pattern matrices";
			var p1 = ps.shift(), q1 = qs.shift(), r1 = rs.shift();
			function loop2(row:Array<PatternData>):Void {
				if (row.length == 0) return;
				var first = row[0], tail = row.slice(1);
				var selected:Null<Array<PatternData>> = null;
				switch first.kind {
					case PatConstructor(other, patterns) if (!isTuple && Constructor.equal(con, other)):
						selected = patterns.concat(tail);
					case PatTuple(patterns) if (isTuple):
						selected = patterns.concat(tail);
					case PatAny:
						var any:PatternData = {kind: PatAny, pos: first.pos};
						selected = [for (_ in 0...arity) any].concat(tail);
					case PatOr(pat1, pat2):
						ps.unshift([pat2].concat(tail));
						ps.unshift([pat1].concat(tail));
						qs.unshift(q1);
						qs.unshift(q1);
						rs.unshift(r1);
						rs.unshift(r1);
					case PatBind(_, pat):
						loop2([pat].concat(tail));
					case _:
				}
				if (selected != null) {
					pAcc.push(selected);
					qAcc.push(q1);
					rAcc.push(r1);
				}
			}
			loop2(p1);
		}
		return {p: pAcc, q: qAcc, r: rAcc};
	}

	public static function combine(et1:LocatedUseless, et2:LocatedUseless):UselessResult return switch [et1.result, et2.result] {
		case [True, True]: True;
		case [False, False]: False;
		case [True, False]: Pos(et2.pos);
		case [False, True]: Pos(et1.pos);
		case [True, Pos(_)]: et2.result;
		case [Pos(_), True]: et1.result;
		case [False, Pos(_)]: Pos(et1.pos);
		case [Pos(_), _]: et1.result;
	};

	public static function uPrime(pM:PatternMatrix, qM:PatternMatrix, rM:PatternMatrix, p:Array<PatternData>, q:Array<PatternData>,
			r:Array<PatternData>):UselessResult {
		if (p.length == 0) {
			if (r.length == 0) return u(qM, q) ? True : False;
			var et = True;
			for (i in 0...r.length) switch r[i].kind {
				case PatOr(pat1, pat2):
					inline function processRow(index:Int, row:Array<PatternData>,
							q:Array<PatternData>):{pattern:PatternData, rest:Array<PatternData>} {
						if (index >= row.length) throw "Invalid pattern column";
						return {pattern: row[index], rest: row.slice(0, index).concat(row.slice(index + 1)).concat(q)};
					}
					if (rM.length != qM.length) throw "Invalid_argument: List.fold_left2";
					var col:PatternMatrix = [], mat:PatternMatrix = [];
					for (j in 0...rM.length) {
						var processed = processRow(i, rM[j], qM[j]);
						col.push([processed.pattern]);
						mat.push(processed.rest);
					}
					var rest = processRow(i, r, q).rest;
					var et1 = uPrime(col, mat, copy(mat), [pat1], rest, []);
					var extended = mat.concat([rest]);
					var et2 = uPrime(col.concat([[pat1]]), extended, copy(extended), [pat2], rest, []);
					var et3 = combine({result: et1, pos: pat1.pos}, {result: et2, pos: pat2.pos});
					var pos = core.Ast.punion(pat1.pos, pat2.pos);
					et = combine({result: et, pos: pos}, {result: et3, pos: pos});
				case _:
					throw "Expected or-pattern";
			}
			return et;
		}
		var pl = p.slice(1);
		function loop(pat:PatternData):UselessResult return switch pat.kind {
			case PatConstructor(con, patterns):
				var m = specializePrime(false, con, pM, qM, rM);
				uPrime(m.p, m.q, m.r, patterns.concat(pl), q, r);
			case PatTuple(patterns):
				var m = specializePrime(true, {kind: ConConst(TNull), pos: pat.pos}, pM, qM, rM);
				uPrime(m.p, m.q, m.r, patterns.concat(pl), q, r);
			case PatAny:
				var m = transferColumn(pM, qM);
				uPrime(m.source, m.target, rM, pl, [pat].concat(q), r);
			case PatOr(_, _):
				var m = transferColumn(pM, rM);
				uPrime(m.source, qM, m.target, pl, q, [pat].concat(r));
			case PatBind(_, pat1): loop(pat1);
			case PatExtractor(_): True;
		};
		return loop(p[0]);
	}

	public static function checkCase(ctx:context.Typecore.Typer, previous:Array<CaseRow>, row:CaseRow):Void {
		var matrix = previous.map(function(row) return row.patterns);
		switch uPrime(matrix, copy(matrix), copy(matrix), row.patterns, [], []) {
			case False:
				Typecore.warning(ctx, WUnusedPattern, "This case is unused", row.caseData.casePos);
			case Pos(p):
				Typecore.warning(ctx, WUnusedPattern, "This pattern is unused", p);
			case True:
		}
	}

	public static function check(ctx:context.Typecore.Typer, cases:Array<CaseRow>):Void {
		var acc:Array<CaseRow> = [];
		for (row in cases) {
			checkCase(ctx, acc, row);
			if (row.caseData.caseGuard == null) acc.push(row);
		}
	}
}
