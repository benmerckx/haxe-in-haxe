package typing.matcher;

import core.Globals.Pos;
import core.TType;
import core.Ast;
import core.Ast.*;
import core.Error;
import core.Texpr;
import core.TUnification;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import context.Typecore.*;
import context.Typecore;
import typing.matcher.Pattern;
import typing.matcher.Constructor;
import typing.matcher.DecisionTree;
import typing.matcher.DecisionTree.*;
import typing.matcher.Case;
import typing.matcher.Bind;
import typing.matcher.MatcherGlobals.*;
import typing.matcher.MatcherGlobals;
import core.TUnification.typeIseq;

// haxe/src/typing/matcher/compile.ml — mechanical draft; not compile-validated.
private class ExtractorFound extends haxe.Exception {
	public function new() super("Extractor");
}

typedef MatcherContext = {var ctx:Typer; var dtTable:haxe.ds.IntMap<Array<DecisionTreeData>>; var matchPos:Pos; var matchDebug:Bool; var dtCount:Int;}

class Compile {
	// DtTable (Hashtbl.Make(DecisionTree)) as buckets under a key built only from
	// what DecisionTree.equal compares, so equal trees share a bucket.
	static function hashconsKey(dt:DecisionTreeKind):Int return switch dt {
		case Leaf(c): 1 + c.casePos.pmin * 8;
		case Switch(_, cases, def): 2 + (cases.length * 31 + def.dtI + (cases.length > 0 ? cases[0].scDt.dtI * 131 : 0)) * 8;
		case Bind(l, d): 3 + (l.length * 31 + d.dtI) * 8;
		case Fail: 4;
		case Guard(_, a, b): 5 + (a.dtI * 31 + b.dtI) * 8;
		case GuardNull(_, a, b): 6 + (a.dtI * 31 + b.dtI) * 8;
	};

	public static function hashcons(m:MatcherContext, dt:DecisionTreeKind, p:Pos):DecisionTreeData {
		var key = hashconsKey(dt);
		var bucket = m.dtTable.get(key);
		if (bucket == null) {
			bucket = [];
			m.dtTable.set(key, bucket);
		}
		for (existing in bucket) if (DecisionTree.equal(existing.dtT, dt)) return existing;
		var d = ({
			dtT: dt,
			dtI: m.dtCount++,
			dtPos: p,
			dtGotoTarget: false,
			dtTexpr: null
		} : typing.matcher.DecisionTree.DecisionTreeData);
		bucket.push(d);
		return d;
	}

	static function leaf(m:MatcherContext, c:CaseData):DecisionTreeData return hashcons(m, Leaf(c), c.casePos);

	static function fail(m:MatcherContext, p:Pos):DecisionTreeData return hashcons(m, Fail, p);

	static function switchTree(m:MatcherContext, e:TExpr, cases:Array<DecisionSwitchCase>,
			def:DecisionTreeData):DecisionTreeData return hashcons(m, Switch(e, cases, def), e.epos);

	static function bind(m:MatcherContext, bl:Array<Bind>, dt:DecisionTreeData):DecisionTreeData return hashcons(m, Bind(bl, dt), dt.dtPos);

	static function guard(m:MatcherContext, e:TExpr, a:DecisionTreeData,
			b:DecisionTreeData):DecisionTreeData return hashcons(m, Guard(e, a, b), punion(a.dtPos, b.dtPos));

	static function guardNull(m:MatcherContext, e:TExpr, a:DecisionTreeData,
			b:DecisionTreeData):DecisionTreeData return hashcons(m, GuardNull(e, a, b), punion(a.dtPos, b.dtPos));

	static function getSubSubjects(m:MatcherContext, e:TExpr, con:ConstructorData,
			positions:Array<Pos>):Array<{name:String, e:TExpr}> return switch con.kind {
			case ConEnum(en, ef):
				var tl = Monomorph.spawnConstrainedMonos(function(t) return t, en.eParams);
				var ten = TEnum(en, tl);
				if (!typeIseq(ten, e.etype)) e = mk(TCast(e, null), ten, e.epos);
				switch follow(ef.efType) {
					case TFun(s): [
							for (i in 0...s.args.length) {
								var a = s.args[i];
								var p = i < positions.length ? positions[i] : e.epos;
								{
									name: a.name,
									e: mk(TEnumParameter(core.ds.Record.withFields(e, {epos: p}), ef, i),
										applyParams(en.eParams, tl, monomorphs(ef.efParams, a.type)), p)
								};
							}
						];
					case _: [];
				}
			case ConFields(sl): sl.map(function(s) return {name: s, e: ExprToPattern.typeFieldAccess(m.ctx, e, s)});
			case ConArray(i): [
					for (i in 0...i) {
						var ei = Texpr.Builder.makeInt(m.ctx.com.basic, i, e.epos);
						{name: 'a$i', e: Calls.accGet(m.ctx, Calls.arrayAccess(m.ctx, e, ei, MGet, e.epos))};
					}
				];
			case ConConst(_) | ConTypeExpr(_) | ConStatic(_, _): [];
		};

	static function specialize(subject:TExpr, con:ConstructorData, cases:Array<CaseRow>):Array<CaseRow> {
		var arity = Constructor.arity(con);
		function row(c:CaseRow):Null<CaseRow> {
			if (c.patterns.length == 0) return null;
			var p = c.patterns[0], tail = c.patterns.slice(1);
			return switch p.kind {
				case PatConstructor(other,
					ps) if (Constructor.equal(con, other)): {caseData: c.caseData, bindings: c.bindings, patterns: ps.concat(tail)};
				case PatAny: {caseData: c.caseData, bindings: c.bindings, patterns: [for (_ in 0...arity) p].concat(tail)};
				case PatBind(v, p1): row({
						caseData: c.caseData,
						bindings: [makeBind(v, p.pos, subject)].concat(c.bindings),
						patterns: [p1].concat(tail)
					});
				case _: null;
			};
		}
		var result = [];
		for (c in cases) {
			var r = row(c);
			if (r != null) result.push(r);
		}
		return result;
	}

	static function defaultRows(subject:TExpr, cases:Array<CaseRow>):Array<CaseRow> {
		function row(c:CaseRow):Null<CaseRow> {
			if (c.patterns.length == 0) return null;
			var p = c.patterns[0], tail = c.patterns.slice(1);
			return switch p.kind {
				case PatAny: {caseData: c.caseData, bindings: c.bindings, patterns: tail};
				case PatBind(v, p1): row({
						caseData: c.caseData,
						bindings: [makeBind(v, p.pos, subject)].concat(c.bindings),
						patterns: [p1].concat(tail)
					});
				case _: null;
			};
		}
		var result = [];
		for (c in cases) {
			var r = row(c);
			if (r != null) result.push(r);
		}
		return result;
	}

	static function isWildcardPattern(p:PatternData):Bool return switch p.kind {
		case PatAny: true;
		case PatBind(_, p): isWildcardPattern(p);
		case _: false;
	};

	static function expand(cases:Array<CaseRow>):Array<CaseRow> {
		function expandRow(f:PatternData->PatternData, c:CaseRow):Array<CaseRow> {
			if (c.patterns.length == 0) return [c];
			var p = c.patterns[0], tail = c.patterns.slice(1);
			inline function row(ps:Array<PatternData>):CaseRow return {caseData: c.caseData, bindings: c.bindings, patterns: ps};
			return switch p.kind {
				case PatOr(a, b): expandRow(f, row([a].concat(tail))).concat(expandRow(f, row([b].concat(tail))));
				case PatBind(v, p1): expandRow(function(p2) return f({kind: PatBind(v, p2), pos: p.pos}), row([p1].concat(tail)));
				case PatTuple(ps): expandRow(f, row(ps.concat(tail)));
				case _: [row([f(p)].concat(tail))];
			};
		}
		var result = [];
		for (c in cases) result = result.concat(expandRow(function(p) return p, c));
		return result;
	}

	static function sSubjects(s:Array<Subject>):String return s.map(function(s) return s.toString()).join(" ");

	static function sCase(c:CaseRow):String {
		var bindings = c.bindings.map(function(b) return '${b.bVar.vName}<${b.bVar.vId}> = ${sExprPretty(b.bExpr)}').join(", ");
		var patterns = c.patterns.map(Pattern.toString).join(" ");
		var expr = c.caseData.caseExpr == null ? "" : core.TPrinting.sExprPretty(false, "\t\t", false, sType, c.caseData.caseExpr);
		var guard = c.caseData.caseGuard == null ? "" : core.TPrinting.sExprPretty(false, "\t\t", false, sType, c.caseData.caseGuard);
		return '\n\t\tbindings: $bindings\n\t\tpatterns: $patterns\n\t\tguard: $guard\n\t\texpr: $expr';
	}

	static function sCases(c:Array<CaseRow>):String return c.map(sCase).join("\n");

	static function selectColumn(subjects:Array<Subject>, cases:Array<CaseRow>):{subjects:Array<Subject>, cases:Array<CaseRow>} {
		var ps = cases[0].patterns.copy();
		var i = 0;
		while (ps.length > 0) {
			var p = ps.shift();
			switch p.kind {
				case PatAny | PatExtractor(_):
					i++;
				case PatBind(_, p):
					ps.unshift(p);
				case _:
					break;
			}
			if (switch p.kind {
					case PatAny | PatExtractor(_) | PatBind(_, _): false;
					case _: true;
				}) break;
		}
		if (ps.length == 0 && i >= cases[0].patterns.length) i = 0;
		function sort<A>(a:Array<A>):Array<A> {
			if (i == 0) return a;
			var acc = [];
			for (j in 0...a.length) {
				if (j == i) return [a[j]].concat(acc).concat(a.slice(j + 1));
				acc.unshift(a[j]);
			}
			return acc;
		}
		return {
			subjects: sort(subjects),
			cases: cases.map(function(c) return ({
				caseData: c.caseData,
				bindings: c.bindings,
				patterns: sort(c.patterns)
			} : typing.matcher.Case.CaseRow))
		};
	}

	static function compileRows(m:MatcherContext, subjects:Array<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		if (cases.length == 0) return fail(m, subjects.length > 0 ? subjects[0].getPos() : m.matchPos);
		if (cases[0].patterns.filter(function(p) return !isWildcardPattern(p))
			.length == 0) return compileLeaf(m, subjects, cases[0], cases.slice(1));
		cases = expand(cases);
		var column = selectColumn(subjects, cases);
		subjects = column.subjects;
		cases = expand(column.cases);
		return try compileSwitch(m, subjects, cases) catch (e:ExtractorFound) compileExtractors(m, subjects, cases);
	}

	static function compileLeaf(m:MatcherContext, subjects:Array<Subject>, row:CaseRow, cases:Array<CaseRow>):DecisionTreeData {
		if (m.matchDebug)
			Sys.println('compile_leaf:\n\tsubjects: ${sSubjects(subjects)}\n\tcase: ${sCase(row)}\n\tcases: ${sCases(cases)}');
		var dt = leaf(m, row.caseData);
		if (row.caseData.caseGuard != null) dt = guard(m, row.caseData.caseGuard, dt, compileRows(m, subjects, cases));
		var ps = row.patterns.copy(),
			ss = subjects.copy(),
			bs = row.bindings.copy();
		while (true) {
			if (ps.length == 1 && ps[0].kind == PatAny) break;
			if (ps.length == 0 && ss.length == 0) break;
			if (ps.length == 0) Error.raiseTypingError("Invalid match: Not enough patterns", ss[0].getPos());
			if (ss.length == 0) Error.raiseTypingError("Invalid match: Too many patterns", ps[0].pos);
			var p = ps.shift();
			switch p.kind {
				case PatBind(v, p1):
					bs.unshift(makeBind(v, p.pos, ss[0].getAssignedExpr()));
					ps.unshift(p1);
				case _:
					ss.shift();
			}
		}
		if (bs.length == 0) return dt;
		bs.reverse();
		return bind(m, bs, dt);
	}

	static function compileSwitch(m:MatcherContext, subjects:Array<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		if (subjects.length == 0) throw new InternalMatchFailure();
		var first = subjects[0];
		subjects = subjects.slice(1);
		var scoped = first.getScopedExpr();
		var subject = first.getExpr();
		var sigma:Array<{con:ConstructorData, unguarded:Bool, positions:Array<Pos>}> = [];
		var nullRows:Array<CaseRow> = [];
		for (row in cases) {
			function loop(bs:Array<Bind>, p:PatternData):Void switch p.kind {
				case PatConstructor({kind: ConConst(TNull)}, _):
					nullRows.push({caseData: row.caseData, bindings: bs, patterns: row.patterns.slice(1)});
				case PatConstructor(con, ps):
					var found = null;
					for (s in sigma) if (Constructor.equal(s.con, con)) {
						found = s;
						break;
					}
					if (found == null) sigma.push({
						con: con,
						unguarded: row.caseData.caseGuard == null,
						positions: ps.map(function(p) return p.pos)
					});
					else {
						found.con = con;
						found.positions = ps.map(function(p) return p.pos);
						if (row.caseData.caseGuard == null) found.unguarded = true;
					}
				case PatBind(_, {kind: PatAny}):
				case PatBind(v, p1):
					loop([makeBind(v, p.pos, subject)].concat(bs), p1);
				case PatAny:
				case PatExtractor(_):
					throw core.ds.FastThrow.of(new ExtractorFound());
				case _:
					Error.raiseTypingError("Unexpected pattern: " + Pattern.toString(p), row.caseData.casePos);
			};
			loop(row.bindings, row.patterns[0]);
		}
		sigma.sort(function(a, b) return a.con.pos.pmin - b.con.pos.pmin);
		if (m.matchDebug)
			Sys.println('compile_switch:\n\tsubject: ${sExprPretty(subject)}\n\ttsubjects: ${sSubjects(subjects)}\n\tcases: ${sCases(cases)}');
		var switchCases = sigma.map(function(s) {
			var sub = getSubSubjects(m, subject, s.con, s.positions);
			var bs = [], ss = [];
			for (sub in sub) {
				var v = addLocal(m.ctx, VGenerated, genLocalPrefix + sub.name, sub.e.etype, sub.e.epos);
				var ev = mk(TLocal(v), v.vType, v.vPos);
				var b = makeBindGen(v, v.vPos, sub.e, BindUnused);
				bs.push(b);
				ss.push(new Subject(ev, b));
			}
			var dt = compileRows(m, ss.concat(subjects), specialize(subject, s.con, cases));
			return ({scCon: s.con, scUnguarded: s.unguarded, scDt: bind(m, bs, dt)} : typing.matcher.DecisionTree.DecisionSwitchCase);
		});
		var subjectNull = subject,
			subjectSwitch = subject,
			subjectDefault = subject;
		if (nullRows.length > 0 || isExplicitNullOrAbstractOverThat(subject.etype)) subjectNull = scoped.expr;
		else if (switchCases.length == 0) subjectDefault = scoped.expr;
		else subjectSwitch = scoped.expr;
		var defaults = defaultRows(subjectDefault, cases);
		var switchDefault = compileRows(m, subjects, defaults);
		var dt = switchCases.length == 0 ? switchDefault : switchTree(m, subjectSwitch, switchCases, switchDefault);
		if (nullRows.length == 0) {
			if (isExplicitNullOrAbstractOverThat(subject.etype)) dt = guardNull(m, subjectNull, switchDefault, dt);
		} else dt = guardNull(m, subjectNull, compileRows(m, subjects, nullRows.concat(defaults)), dt);
		scoped.reset();
		return dt;
	}

	static function compileExtractors(m:MatcherContext, subjects:Array<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		if (subjects.length == 0) throw new InternalMatchFailure();
		var subject = subjects[0].getExpr();
		subjects = subjects.slice(1);
		if (m.matchDebug)
			Sys.println('compile_extractor:\n\tsubject: ${sExprPretty(subject)}\n\ttsubjects: ${sSubjects(subjects)}\n\tcases: ${sCases(cases)}');
		var count = 0;
		var extracted:Array<{row:CaseRow, ex:Null<{extractor:Extractor, i:Int, bindings:Array<Bind>}>}> = [];
		for (row in cases) {
			var ex:Null<{extractor:Extractor, i:Int, bindings:Array<Bind>}> = null;
			function loop(bs:Array<Bind>, p:PatternData):Void switch p.kind {
				case PatExtractor(e):
					ex = {extractor: e, i: ++count, bindings: bs};
				case PatBind(v, p1):
					loop([makeBind(v, p.pos, subject)].concat(bs), p1);
				case _:
			};
			loop([], row.patterns[0]);
			extracted.push({row: row, ex: ex});
		}
		var any:PatternData = {kind: PatAny, pos: nullPos};
		var result:Array<CaseRow> = [],
			ss:Array<Subject> = [],
			bs:Array<Bind> = [],
			lut:Array<{e:TExpr, subject:Subject, i:Int}> = [];
		for (item in extracted) {
			var row:CaseRow = item.row;
			if (row.patterns.length == 0) throw "assert";
			var p = row.patterns[0], tail = row.patterns.slice(1);
			if (item.ex == null) {
				result.push({caseData: row.caseData, bindings: row.bindings, patterns: makeOffsetList(0, count, p, any).concat(tail)});
				continue;
			}
			var ex:Extractor = item.ex.extractor;
			function replace(e:TExpr):TExpr return switch e.eexpr {
				case TLocal(v) if (v == ex.exVar): subject;
				case _: core.Texpr.mapExpr(replace, e);
			};
			var e = replace(ex.exExpr);
			var bindings = item.ex.bindings.concat(row.bindings);
			var found:Null<{e:TExpr, subject:Subject, i:Int}> = null;
			for (entry in lut) if (Texpr.equal(e, entry.e)) {
				found = entry;
				break;
			}
			var i:Int = item.ex.i;
			var sub:Subject;
			if (found == null) {
				var v = allocVar(VExtractorVariable, "_hx_tmp", e.etype, e.epos);
				var ev = mk(TLocal(v), v.vType, e.epos);
				var binding = makeBindGen(v, v.vPos, e, BindDeferred);
				sub = new Subject(ev, binding);
				bs.push(binding);
				lut.unshift({e: e, subject: sub, i: i});
			} else {
				i = found.i;
				sub = found.subject;
			}
			ss.push(sub);
			result.push({
				caseData: row.caseData,
				bindings: bindings,
				patterns: makeOffsetList(i, count - i, ex.exPattern, any).concat(tail)
			});
		}
		var dt = compileRows(m, [new Subject(subject, null)].concat(ss).concat(subjects), result);
		return bind(m, bs, dt);
	}

	public static function compile(ctx:Typer, debug:Bool, expressions:Array<TExpr>, cases:Array<CaseRow>, p:Pos):DecisionTreeData {
		var m:MatcherContext = {
			ctx: ctx,
			matchDebug: debug,
			dtTable: new haxe.ds.IntMap(),
			matchPos: p,
			dtCount: 0
		};
		var subjects = [], vars = [];
		for (e in expressions) switch e.eexpr {
			case TConst(_) | TLocal(_):
				subjects.push(new Subject(e, null));
			case _:
				var v = genLocal(ctx, e.etype, e.epos);
				var ev = mk(TLocal(v), e.etype, e.epos);
				var b = makeBind(v, e.epos, e);
				subjects.push(new Subject(ev, b));
				vars.push(b);
		}
		if (cases.length == 0 && subjects.length > 0) {
			var dt = fail(m, subjects[0].getPos());
			return switchTree(m, subjects[0].getExpr(), [], dt);
		}
		var dt = compileRows(m, subjects, cases);
		Useless.check(ctx, cases);
		return vars.length == 0 ? dt : bind(m, vars, dt);
	}
}
