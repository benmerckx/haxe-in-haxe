package core;

import core.Ast;

// haxe/src/core/ast.ml: map_expr's mutually recursive local functions.
class AstExprMapper {
	final loop:Expr->Expr;

	public function new(loop:Expr->Expr) this.loop = loop;

	function optExpr(e:Null<Expr>):Null<Expr> return e == null ? null : loop(e);

	function optHint(t:Null<TypeHint>):Null<TypeHint> return t == null ? null : typeHint(t);

	function tparam(t:TypeParamOrConst):TypeParamOrConst return switch t {
		case TPType(t): TPType(typeHint(t));
		case TPExpr(e): TPExpr(loop(e));
	};

	function tpath(t:PlacedTypePath):PlacedTypePath return {
		path: {
			tpackage: t.path.tpackage,
			tname: t.path.tname,
			tsub: t.path.tsub,
			tparams: t.path.tparams.map(tparam)
		},
		posFull: t.posFull,
		posPath: t.posPath
	};

	function cfield(f:ClassField):ClassField {
		var kind = switch f.cffKind {
			case FVar(t, e):
				var t = optHint(t);
				FVar(t, optExpr(e));
			case FFun(f): FFun(func(f));
			case FProp(get, set, t, e):
				var t = optHint(t);
				FProp(get, set, t, optExpr(e));
		};
		return {
			cffKind: kind,
			cffName: f.cffName,
			cffDoc: f.cffDoc,
			cffPos: f.cffPos,
			cffMeta: f.cffMeta,
			cffAccess: f.cffAccess
		};
	}

	function typeHint(t:TypeHint):TypeHint {
		var ct = switch t.type {
			case CTPath(p): CTPath(tpath(p));
			case CTFunction(args, ret):
				var args = args.map(typeHint);
				CTFunction(args, typeHint(ret));
			case CTAnonymous(fl): CTAnonymous(fl.map(cfield));
			case CTParent(t): CTParent(typeHint(t));
			case CTExtend(tl, fl):
				var tl = tl.map(tpath);
				CTExtend(tl, fl.map(cfield));
			case CTOptional(t): CTOptional(typeHint(t));
			case CTNamed(n, t): CTNamed(n, typeHint(t));
			case CTIntersection(tl): CTIntersection(tl.map(typeHint));
		};
		return {type: ct, pos: t.pos};
	}

	function tparamDecl(t:TypeParam):TypeParam {
		var constraints = optHint(t.tpConstraints),
			def = optHint(t.tpDefault),
			params = t.tpParams.map(tparamDecl);
		return {
			tpName: t.tpName,
			tpConstraints: constraints,
			tpDefault: def,
			tpParams: params,
			tpMeta: t.tpMeta
		};
	}

	function func(f:Func):Func {
		var params = f.fParams.map(tparamDecl);
		var args = f.fArgs.map(function(a) {
			var t = optHint(a.type);
			var e = optExpr(a.expr);
			return ({
				name: a.name,
				optional: a.optional,
				meta: a.meta,
				type: t,
				expr: e
			} : core.Ast.FuncArg);
		});
		var t = optHint(f.fType), e = optExpr(f.fExpr);
		return {
			fParams: params,
			fArgs: args,
			fType: t,
			fExpr: e
		};
	}

	public function map(e:Expr):Expr {
		var def:ExprDef = switch e.expr {
			case EConst(_): e.expr;
			case EArray(a, b):
				var a = loop(a);
				EArray(a, loop(b));
			case EBinop(op, a, b):
				var a = loop(a);
				EBinop(op, a, loop(b));
			case EField(e, f, k): EField(loop(e), f, k);
			case EParenthesis(e): EParenthesis(loop(e));
			case EObjectDecl(fl): EObjectDecl(fl.map(f -> ({key: f.key, expr: loop(f.expr)} : core.Ast.ObjectField)));
			case EArrayDecl(el): EArrayDecl(el.map(loop));
			case ECall(e, el):
				var e = loop(e);
				ECall(e, el.map(loop));
			case ENew(t, el):
				var t = tpath(t);
				ENew(t, el.map(loop));
			case EUnop(op, flag, e): EUnop(op, flag, loop(e));
			case EVars(vl): EVars(vl.map(function(v) {
					var t = optHint(v.evType), e = optExpr(v.evExpr);
					return ({
						evName: v.evName,
						evFinal: v.evFinal,
						evStatic: v.evStatic,
						evMeta: v.evMeta,
						evType: t,
						evExpr: e
					} : core.Ast.EVar);
				}));
			case EFunction(k, f): EFunction(k, func(f));
			case EBlock(el): EBlock(el.map(loop));
			case EFor(a, b):
				var a = loop(a);
				EFor(a, loop(b));
			case EIf(e, a, b):
				var e = loop(e), a = loop(a);
				EIf(e, a, optExpr(b));
			case EWhile(c, e, f):
				var c = loop(c);
				EWhile(c, loop(e), f);
			case ESwitch(e, cases, def):
				var e = loop(e);
				var cases = cases.map(function(c) {
					var el = c.values.map(loop), guard = optExpr(c.guard), expr = optExpr(c.expr);
					return ({
						values: el,
						guard: guard,
						expr: expr,
						pos: c.pos
					} : core.Ast.SwitchCase);
				});
				var def = def == null ? null : ({expr: optExpr(def.expr), pos: def.pos} : core.Ast.SwitchDefault);
				ESwitch(e, cases, def);
			case ETry(e, catches):
				var e = loop(e);
				ETry(e, catches.map(function(c) {
					var t = optHint(c.type);
					return ({
						name: c.name,
						type: t,
						expr: loop(c.expr),
						pos: c.pos
					} : core.Ast.Catch);
				}));
			case EReturn(e): EReturn(optExpr(e));
			case EBreak: EBreak;
			case EContinue: EContinue;
			case EUntyped(e): EUntyped(loop(e));
			case EThrow(e): EThrow(loop(e));
			case ECast(e, t):
				var e = loop(e);
				ECast(e, optHint(t));
			case EIs(e, t):
				var e = loop(e);
				EIs(e, typeHint(t));
			case EDisplay(e, k): EDisplay(loop(e), k);
			case ETernary(a, b, c):
				var a = loop(a), b = loop(b);
				ETernary(a, b, loop(c));
			case ECheckType(e, t):
				var e = loop(e);
				ECheckType(e, typeHint(t));
			case EMeta(m, e): EMeta(m, loop(e));
		};
		return {expr: def, pos: e.pos};
	}
}
