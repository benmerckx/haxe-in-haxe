package coro;

import core.Error;
import core.TPrinting.Printer;
import core.ds.PMap;
import syntax.Lexer;
import core.Texpr;
import core.Texpr.Builder;
import core.TOther;
import core.ds.AtomicLazy;
import context.Common;
import context.SafeCom;
import context.DotGraph;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.Globals;
import core.Globals.*;
import coro.CoroTypes;
import coro.CoroFunctions;
import coro.CoroFunctions.*;
import coro.ContTypes;
import coro.CoroToTexpr;
import coro.CoroElsewhere.TexprBuilder;

// haxe/src/coro/coro.ml — mechanical draft; not compile-validated.
typedef CoroCls = {var params:TypeParams; var paramTypes:Array<T>; var clsT:T; var resultType:T; var contType:T;}
typedef CoroClass = {var cls:TClass; var namePos:Pos; var inside:CoroCls; var outside:CoroCls; var typeParamSubst:Array<{param:TypedTypeParam, t:T}>; var coroType:CoroFor; var continuationApi:ContinuationApi;}

class ContinuationClassBuilder {
	public static function create(ctx:CoroCtx):CoroClass {
		var path = ctx.typer.c.curclass.clPath;
		var mangled = 'HxCoro_${path.pack.join("_")}_${path.name}';
		var name:String;
		var result:T;
		switch ctx.coroType {
			case ClassField(_, cf, tf, _):
				name = mangled + "_" + cf.cfName;
				result = tf.tfType;
			case LocalFunc(tf, v):
				var id = Coro.nextClosureId.get(mangled);
				if (id == null) id = 0;
				Coro.nextClosureId.set(mangled, id + 1);
				name = mangled + '_AnonFunc$id';
				result = tf.tfType;
		}
		var p = ctx.classNamePos;
		if (ExtType.isVoid(follow(result))) result = ctx.typer.t.tunit;
		var mod = ctx.typer.m.curmod;
		var cp:core.Globals.GlobalTypePath = {pack: mod.mPath.pack.concat(["_" + mod.mPath.name]), name: name};
		var cls = mkClass(mod, cp, p, p);
		var outside:TypeParams = ctx.typer.typeParams;
		var inside = outside.map(function(ttp) {
			var c = {
				var recordCopy5 = core.ds.Record.copy(ttp.ttpClass);
				recordCopy5.clPath = {pack: [], name: ttp.ttpName};
				recordCopy5;
			};
			var constraints = ttp.ttpConstraints == null ? null : AtomicLazy.fromFun(function() return (ttp.ttpConstraints).force()
				.map(function(t) return t));
			return mkTypeParam(c, TPHType, ttp.ttpDefault, constraints);
		});
		cls.clParams = inside;
		var api:ContinuationApi = ctx.typer.g.continuationApi;
		if (api == null) api = CoroInit.makeContinuationApi(ctx.typer);
		var pi = extractParamTypes(inside);
		var po = extractParamTypes(outside);
		var subst = [for (i in 0...outside.length) {param: outside[i], t: pi[i]}];
		var ri = Coro.substituteTypeParams(subst, result);
		cls.clSuper = {cls: api.baseContinuationClass, params: [ri]};
		return {
			cls: cls,
			namePos: p,
			inside: {
				params: inside,
				paramTypes: pi,
				clsT: TInst(cls, pi),
				resultType: ri,
				contType: TInst(api.baseContinuationClass, [ri])
			},
			outside: {
				params: outside,
				paramTypes: po,
				clsT: TInst(cls, po),
				resultType: result,
				contType: TInst(api.baseContinuationClass, [result])
			},
			typeParamSubst: subst,
			coroType: ctx.coroType,
			continuationApi: api
		};
	}

	public static function mkCtor(ctx:CoroCtx, cont:ContinuationApi, cc:CoroClass, initial:Int, captured:Null<TClassField>,
			hoisted:Array<{name:String, e:TExpr, field:TClassField}>):TClassField {
		var basic:BasicTypes = ctx.typer.t;
		var b = ctx.builder;
		var p = cc.namePos;
		var ethis = mk(TConst(TThis), cc.inside.clsT, p);
		var completion = allocVar(VGenerated, "completion", cont.continuation, p);
		var esuper = b.call(b.makeSuper(cc.inside.contType, p), [b.local(completion, p), b.int(initial, p)], basic.tvoid);
		inline function thisField(cf:TClassField):TExpr return b.instanceField(ethis, cc.cls, cc.inside.paramTypes, cf, cf.cfType);
		var capture:Null<{v:TVar, e:TExpr}> = null;
		if (captured != null) {
			var v = allocVar(VGenerated, "_hx_captured", captured.cfType, p);
			capture = {v: v, e: b.assign(thisField(captured), b.local(v, p))};
		}
		var hs = hoisted.map(function(h) {
			var v = allocVar(VGenerated, h.name, h.field.cfType, p);
			return {v: v, e: b.assign(thisField(h.field), b.local(v, p))};
		});
		var el = [esuper].concat(hs.map(function(h) return h.e));
		var funArgs:Array<{name:String, optional:Bool, type:T}> = [
			{
				name: "completion",
				optional: false,
				type: cont.continuation
			}
		].concat(hs.map(function(h) return {name: h.v.vName, optional: false, type: h.v.vType}));
		var args:Array<{variable:TVar, defaultValue:Null<TExpr>}> = [{variable: completion, defaultValue: null}].concat(hs.map(function(h)
			return {variable: h.v, defaultValue: null}));
		if (capture != null) {
			el.push(capture.e);
			funArgs.push({name: capture.v.vName, optional: false, type: capture.v.vType});
			args.push({variable: capture.v, defaultValue: null});
		}
		var field = mkField("new", TFun({args: funArgs, ret: basic.tvoid}), p, p);
		var expr = mk(TFunction({tfType: basic.tvoid, tfArgs: args, tfExpr: b.voidBlock(el)}), field.cfType, p);
		field.cfExpr = expr;
		field.cfKind = Method(MethNormal);
		if (ctx.config.debug) Sys.println(core.TPrinting.sExprDebug(expr));
		return field;
	}

	public static function mkInvokeResumeWithBody(ctx:CoroCtx, cc:CoroClass, vcontinuation:TVar, vtmpResult:AtomicLazy<TVar>,
			vtmpError:TVar, vtmpErrorUnwrapped:AtomicLazy<TVar>, eresult:TExpr, eloop:TExpr):TClassField {
		var basic:BasicTypes = ctx.typer.t;
		var b = ctx.builder;
		var p = cc.namePos;
		var ret = TInst((basic.tcoro.suspensionResultClass).force(), [cc.inside.resultType]);
		var ethis = b.makeThis(cc.inside.clsT, p);
		function subst(t:T):T return Coro.substituteTypeParams(cc.typeParamSubst, t);
		var vars:Map<Int, TVar> = [];
		function mapVar(v:TVar):TVar {
			var n = vars.get(v.vId);
			if (n == null) {
				n = {
					var recordCopy4 = core.ds.Record.copy(v);
					recordCopy4.vType = subst(v.vType);
					recordCopy4;
				};
				vars.set(v.vId, n);
			}
			return n;
		}
		function mapLoop(e:TExpr):TExpr return Texpr.mapExprType(mapLoop, subst, mapVar, e);
		var el = [b.varInit(vcontinuation, ethis)];
		if ((vtmpResult).isVal()) el.push(b.varInit((vtmpResult).force(), eresult));
		el.push(b.varInitNull(vtmpError));
		if ((vtmpErrorUnwrapped).isVal()) el.push(b.varInitNull((vtmpErrorUnwrapped).force()));
		el.push(eloop);
		var expr = mk(TFunction({tfType: ret, tfArgs: [], tfExpr: mapLoop(b.voidBlock(el))}), basic.tvoid, p);
		var field = mkField("invokeResume", TFun({args: [], ret: ret}), p, p);
		addClassFieldFlag(field, CfOverride);
		field.cfExpr = expr;
		field.cfKind = Method(MethNormal);
		if (ctx.config.debug) Sys.println(core.TPrinting.sExprDebug(expr));
		return field;
	}

	public static function mkInvokeResumeThunkCall(ctx:CoroCtx, cc:CoroClass, captured:TClassField):TClassField {
		var basic:BasicTypes = ctx.typer.t;
		var b = ctx.builder;
		var p = cc.namePos;
		var ret = TInst((basic.tcoro.suspensionResultClass).force(), [cc.inside.resultType]);
		var ethis = b.makeThis(cc.inside.clsT, p);
		var access = b.instanceField(ethis, cc.cls, cc.inside.paramTypes, captured, captured.cfType);
		var expr = mk(TFunction({tfType: ret, tfArgs: [], tfExpr: b.voidBlock([b.makeReturn(b.call(access, [], ret))])}), basic.tvoid, p);
		var field = mkField("invokeResume", TFun({args: [], ret: ret}), p, p);
		addClassFieldFlag(field, CfOverride);
		field.cfExpr = expr;
		field.cfKind = Method(MethNormal);
		if (ctx.config.debug) Sys.println(core.TPrinting.sExprDebug(expr));
		return field;
	}
}

class Coro {
	public static var nextClosureId:Map<String, Int> = [];

	public static function substituteTypeParams(subst:Array<{param:TypedTypeParam, t:T}>, t:T):T {
		function loop(t:T):T return switch t {
			case TInst({clKind: KTypeParameter(ttp)}, []):
				var result = t;
				for (s in subst) if (s.param == ttp) {
					result = s.t;
					break;
				}
				result;
			case _: core.TFunctions.map(loop, t);
		};
		return loop(t);
	}

	public static function createContinuationClass(ctx:CoroCtx, cont:ContinuationApi, cc:CoroClass, initial:Int, invoke:TClassField,
			mode:CoroGenMode, hoisted:Array<{
			name:String,
			e:TExpr,
			field:TClassField
		}>):Void {
		var captured = switch mode {
			case GenInline(c): c == null ? null : c.cf;
			case GenThunk(cf): cf;
		};
		var ctor = ContinuationClassBuilder.mkCtor(ctx, cont, cc, initial, captured, hoisted);
		core.TOther.TClassTools.addField(cc.cls, invoke);
		if (captured != null) core.TOther.TClassTools.addField(cc.cls, captured);
		cc.cls.clConstructor = ctor;
		if (ctx.config.debug) Sys.println(Printer.sTclass("\t", cc.cls));
		ctx.typer.m.curmod.mTypes = ctx.typer.m.curmod.mTypes.concat([TClassDecl(cc.cls)]);
		}

	public static function checkAssertions(config:Null<coro.CoroConfig.CoroAssert>, states:Int, hoisted:Int, p:Pos):Void {
		if (config == null) return;
		if (config.numStates != null && states != config.numStates)
			Error.raiseTypingError('Expected ${config.numStates} coroutine state(s), got $states', p);
		if (config.numHoisted != null && hoisted != config.numHoisted)
			Error.raiseTypingError('Expected ${config.numHoisted} hoisted field(s), got $hoisted', p);
	}

	public static function coroToStateMachine(ctx:CoroCtx, cc:CoroClass, root:CoroBlock, exprs:CoroToTexprExprs,
			args:Array<{variable:TVar, defaultValue:Null<TExpr>}>, vtmpResult:AtomicLazy<TVar>, vtmpError:TVar,
			vtmpErrorUnwrapped:AtomicLazy<TVar>, vcompletion:TVar, vcontinuation:TVar, mode:CoroGenMode, stack:Pos->TExpr,
			startException:TExpr->TExpr):TExpr {
		var b = ctx.builder;
		var cont = cc.continuationApi;
		var result = CoroToTexpr.blockToTexprCoroutine(ctx, root, cont, cc.cls, cc.outside.paramTypes, args, exprs, cc.namePos, stack,
			startException);
		if (!ctx.typer.com.debug) checkAssertions(ctx.config.assertConfig, result.numStates, result.fields.length, cc.namePos);
		for (cf in result.fields) {
			cf.cfType = substituteTypeParams(cc.typeParamSubst, cf.cfType);
			core.TOther.TClassTools.addField(cc.cls, cf);
		}
		var ret = cont.suspensionResult(cc.outside.resultType);
		var eloop = b.voidBlock([stack(cc.namePos), result.expr]);
		var invoke = switch mode {
			case GenInline(_): ContinuationClassBuilder.mkInvokeResumeWithBody(ctx, cc, vcontinuation, vtmpResult, vtmpError,
					vtmpErrorUnwrapped, exprs.eresult, eloop);
			case GenThunk(cf): ContinuationClassBuilder.mkInvokeResumeThunkCall(ctx, cc, cf);
		};
		var hoisted = [];
		for (a in args) {
			var v:TVar = a.variable;
			var field = cc.cls.clFields.get('_hx_hoisted${v.vId}');
			if (field != null) hoisted.push({name: v.vName, e: b.local(v, v.vPos), field: field});
		}
		createContinuationClass(ctx, cont, cc, result.initialState, invoke, mode, hoisted);
		return switch mode {
			case GenInline(captured):
				var ctorArgs = [exprs.ecompletion].concat(hoisted.map(function(h) return h.e)).concat(captured == null ? [] : [captured.e]);
				var tnew = mk(TNew(cc.cls, cc.outside.paramTypes, ctorArgs), cc.outside.clsT, cc.namePos);
				var einvoke = b.instanceField(tnew, cc.cls, cc.outside.paramTypes, invoke, TFun({args: [], ret: ret}));
				b.makeReturn(b.call(einvoke, [], ret));
			case GenThunk(_):
				var econt = b.local(vcontinuation, cc.namePos);
				var invokeType = applyParams(cc.inside.params, cc.outside.paramTypes, invoke.cfType);
				var call = b.call(b.instanceField(econt, cc.cls, cc.outside.paramTypes, invoke, invokeType), [], ret);
				var el = [];
				if ((vtmpResult).isVal()) el.push(b.varInit((vtmpResult).force(), exprs.eresult));
				el.push(b.varInitNull(vtmpError));
				if ((vtmpErrorUnwrapped).isVal()) el.push(b.varInitNull((vtmpErrorUnwrapped).force()));
				el.push(eloop);
				var thunkType = TFun({args: [], ret: ret});
				var ethunk = mk(TFunction({tfType: ret, tfArgs: [], tfExpr: b.voidBlock(el)}), thunkType, cc.namePos);
				var vthunk = allocVar(VGenerated, "_hx_thunk", thunkType, cc.namePos);
				var ctorArgs = [exprs.ecompletion].concat(hoisted.map(function(h) return h.e)).concat([b.local(vthunk, cc.namePos)]);
				var tnew = mk(TNew(cc.cls, cc.outside.paramTypes, ctorArgs), cc.outside.clsT, cc.namePos);
				b.meta1(core.MetaList.StrictMeta.NullSafety, {expr: core.Ast.ExprDef.EConst(Ident("Off")), pos: vcontinuation.vPos},
					b.voidBlock([
						b.varInitNull(vcontinuation),
						b.varInit(vthunk, ethunk),
						b.assign(b.local(vcontinuation, cc.namePos), tnew),
						b.makeReturn(call)
					]));
		};
	}

	public static function rewriteSuperField(ctx:CoroCtx, egthis:TExpr, e:TExpr):TExpr {
		var basic:BasicTypes = ctx.typer.t;
		var b = ctx.builder;
		var curclass:TClass = ctx.typer.c.curclass;
		var params = extractParamTypes(ctx.typer.typeParams);
		function helper(superExpr:TExpr, superCl:TClass, superCf:TClassField, p:Pos):TClassField {
			var name = "_hx_super_" + superCf.cfName;
			var cf = curclass.clFields.get(name);
			if (cf != null) return cf;
			cf = mkField(name, superCf.cfType, p, p);
			cf.cfKind = Method(MethNormal);
			var expanded = switch followWithCoro(superCf.cfType) {
				case Coro({args: args, ret: ret}): Common.expandCoroType(basic, args, ret);
				case NotCoro(_): throw "super helper: expected Coro type";
			};
			var vars = [for (a in expanded.args) allocVar(VGenerated, a.name, a.type, p)];
			var ecall = mk(TCall({
				var recordCopy3 = core.ds.Record.copy(superExpr);
				recordCopy3.etype = TFun({
					args: expanded.args,
					ret: expanded.ret
				});
				recordCopy3;
			}, vars.map(function(v) return b.local(v, p))), expanded.ret, p);
			cf.cfExpr = mk(TFunction({
				tfArgs: vars.map(function(v) return {variable: v, defaultValue: null}),
				tfType: expanded.ret,
				tfExpr: mk(TReturn(ecall), tDynamic, p)
			}), superCf.cfType, p);
			core.TOther.TClassTools.addField(curclass, cf);
			return cf;
		}
		return switch e.eexpr {
			case TField(esuper = {eexpr: TConst(TSuper)}, fa = FInstance(sc, _, cf)):
				var sf:TExpr = {eexpr: TField(esuper, fa), etype: cf.cfType, epos: e.epos};
				var h = helper(sf, sc, cf, e.epos);
				{
					var recordCopy2 = core.ds.Record.copy(e);
					recordCopy2.eexpr = TField(egthis, FInstance(curclass, params, h));
					recordCopy2;
				};
			case _: e;
		};
	}

	public static function makeDeferredApi(ctx:CoroCtx, b:TexprBuilder):{deferred:CoroDeferredApi, install:CoroDeferredApi->Void} {
		inline function makeDeferred(build:Void->TExpr, t:T):TExpr {
			var v = allocVar(VGenerated, "_hx_coro_deferred", tDynamic, nullPos);
			ctx.deferredExprs.set(v.vId, build);
			return b.call(b.local(v, v.vPos), [], t);
		}
		var api:Null<CoroDeferredApi> = null;
		var deferred:CoroDeferredApi = {
			makeInlineReturn: function(e, p) return makeDeferred(function() return api.makeInlineReturn(e, p), tDynamic),
			makeInlineTailCall: function(c) return makeDeferred(function() return api.makeInlineTailCall(c), tDynamic),
			makeSyncCall: function(c, e) return makeDeferred(function() return api.makeSyncCall(c, e), tDynamic),
			makeThis: function(e) return makeDeferred(function() return api.makeThis(e), e.etype),
			makeSuperField: function(e) return makeDeferred(function() return api.makeSuperField(e), e.etype)
		};
		return {deferred: deferred, install: function(a) api = a};
	}

	public static function funToCoro(ctx:CoroCtx):TExpr {
		var basic:BasicTypes = ctx.typer.t;
		var b = ctx.builder;
		var cc = ContinuationClassBuilder.create(ctx);
		var p = cc.namePos;
		var vtmpResult = AtomicLazy.fromFun(function() return allocVar(VGenerated, "_hx_result", basic.tnull(basic.tany), p));
		var etmpResult = AtomicLazy.fromFun(function() return b.local((vtmpResult).force(), p));
		var vtmpError = allocVar(VGenerated, "_hx_error", basic.tnull(basic.texception), p);
		var vtmpErrorUnwrapped = AtomicLazy.fromFun(function() return allocVar(VGenerated, "_hx_error_unwrapped", basic.tnull(basic.tany),
			p));
		var etmpErrorUnwrapped = AtomicLazy.fromFun(function() return b.local((vtmpErrorUnwrapped).force(), p));
		var expr:TExpr;
		var args:Array<{variable:TVar, defaultValue:Null<TExpr>}>;
		var name:String;
		switch ctx.coroType {
			case ClassField(_, cf, f, _):
				expr = f.tfExpr;
				args = f.tfArgs;
				name = cf.cfName;
			case LocalFunc(f, v):
				expr = f.tfExpr;
				args = f.tfArgs;
				name = v.vName;
		}
		var root = makeBlock(ctx, {t: expr.etype, p: p});
		var scope:Null<CoroScope> = null;
		if (args.length > 0 && hasVarFlag(args[0].variable, VCoroScope)) scope = {
			scopeVar: args[0].variable,
			restrictedSuspension: hasVarFlag(args[0].variable, VCoroRestrictedSuspension)
		};
		var deferred = makeDeferredApi(ctx, b);
		CoroFromTexpr.checkCaptures(ctx, args, expr);
		CoroFromTexpr.exprToCoro(ctx, etmpResult, etmpErrorUnwrapped, root, scope, deferred.deferred, expr);
		var count = 0;
		coroWalk(function(_) count++, root);
		ctx.numStates = count;
		var cont = cc.continuationApi;
		var retInside = cont.suspensionResult(cc.inside.resultType);
		var mode = switch cc.coroType {
			case ClassField(_, cf, _, _) if (hasClassFieldFlag(cf, CfStatic)): GenInline(null);
			case ClassField(_, cf, _, _): if (!ctx.capturesThis) GenInline(null); else {
					var captured = mkField("_hx_captured", ctx.typer.c.tthis, cf.cfNamePos, cf.cfNamePos);
					GenInline({e: b.makeThis(ctx.typer.c.tthis, p), cf: captured});
				}
			case LocalFunc(_, _) if (!ctx.capturesThis && !ctx.hasCaptureVars): GenInline(null);
			case LocalFunc(_, v): GenThunk(mkField("_hx_captured", TFun({args: [], ret: retInside}), v.vPos, v.vPos));
		};
		var vcompletion = allocVar(VGenerated, "_hx_completion", cont.continuation, p);
		var ecompletion = b.local(vcompletion, p);
		var contType = switch mode {
			case GenInline(_): cc.inside.clsT;
			case GenThunk(_): cc.outside.clsT;
		};
		var vcontinuation = allocVar(VGenerated, "_hx_continuation", contType, p);
		var econtinuation = b.local(vcontinuation, p);
		inline function resultField(cf:TClassField,
				t:T):TExpr return b.instanceField(econtinuation, cont.suspensionResultClass, [basic.tany], cf, t);
		var estate = resultField(cont.state, cont.suspensionState);
		var eresult = resultField(cont.result, basic.tnull(basic.tany));
		var eerror = resultField(cont.error, basic.tnull(basic.texception));
		inline function continuationField(cf:TClassField,
				t:T):TExpr return b.instanceField(econtinuation, cont.baseContinuationClass, [basic.tany], cf, t);
		var egoto = continuationField(cont.gotoLabel, basic.tint);
		var etmpError = b.local(vtmpError, p);
		var exprs:CoroToTexprExprs = {
			econtinuation: econtinuation,
			ecompletion: ecompletion,
			estate: estate,
			eresult: eresult,
			egoto: egoto,
			eerror: eerror,
			etmpResult: etmpResult,
			etmpError: etmpError,
			etmpErrorUnwrapped: etmpErrorUnwrapped
		};
		function stack(pos:Pos):TExpr {
			if (!ctx.typer.com.debug) return b.voidBlock([]);
			var field = PMap.find("setStackItem", cont.baseContinuationClass.clFields);
			var args = switch ctx.coroType {
				case ClassField(cls, cf, _, _): [
						b.int(0, p),
						b.string(core.TOther.sClassPath(cls), p),
						b.string(cf.cfName, p),
						b.int(0, p)
					];
				case LocalFunc(_, v): [b.int(1, p), b.string("", p), b.string("", p), b.int(v.vId, p)];
			};
			var coords = Lexer.getPosCoords(pos);
			args = args.concat([
				b.string(pos.pfile, p),
				b.int(coords.lineStart, p),
				b.int(coords.columnStart, p),
				b.int(pos.pmin, p),
				b.int(pos.pmax, p)
			]);
			return mk(TCall(continuationField(field, field.cfType), args), basic.tvoid, p);
		}
		var vgthis = AtomicLazy.fromFun(function() return allocVar(VGenerated, "_hx_this", ctx.typer.c.tthis, p));
		var egthis = AtomicLazy.fromFun(function() return switch mode {
			case GenThunk(_): b.local((vgthis).force(), p);
			case GenInline(c) if (c != null): b.instanceField(econtinuation, cc.cls, cc.inside.paramTypes, c.cf, c.cf.cfType);
			case GenInline(_): throw "assert";
		});
		deferred.install({
			makeInlineReturn: function(e, pos) {
				var stmts = ctx.numStates == 1 ? [] : [b.assign(egoto, b.int(-1, pos))];
				stmts.push(b.assign(estate, b.int(CoroReturned, pos)));
				if (e != null) stmts.push(b.assign(eresult, e));
				stmts.push(b.makeReturn(econtinuation));
				return mk(TBlock(stmts), tDynamic, pos);
			},
			makeInlineTailCall: function(call) {
				var r = SuspensionCalls.makeSuspendingTailCall(ctx, cont, exprs, call);
				return b.voidBlock([stack(call.csPos), r.call, r.check]);
			},
			makeSyncCall: function(call, e) {
				var r = SuspensionCalls.makeSyncCallAndCheck(ctx, cont, exprs, call, e);
				return b.voidBlock([stack(call.csPos), r.call, r.check]);
			},
			makeThis: function(e) {
				var th = (egthis).force();
				return {
					var recordCopy1 = core.ds.Record.copy(e);
					recordCopy1.eexpr = th.eexpr;
					recordCopy1.etype = th.etype;
					recordCopy1;
				};
			},
			makeSuperField: function(e) return rewriteSuperField(ctx, (egthis).force(), e)
		});
		var startException:TExpr->TExpr;
		if (!ctx.typer.com.debug) startException = function(e) return e;
		else {
			var cf = PMap.find("startException", cont.baseContinuationClass.clFields);
			var ef = continuationField(cf, cf.cfType);
			startException = function(e) return mk(TCall(ef, [e]), basic.texception, p);
		}
		var tfExpr = coroToStateMachine(ctx, cc, root, exprs, args, vtmpResult, vtmpError, vtmpErrorUnwrapped, vcompletion, vcontinuation,
			mode, stack, startException);
		if ((vgthis).isVal()) tfExpr = b.voidBlock([b.varInit((vgthis).force(), b.makeThis(ctx.typer.c.tthis, p)), tfExpr]);
		var tfArgs = [{variable: vcompletion, defaultValue: null}].concat(args);
		var tfType = cont.suspensionResult(cc.outside.resultType);
		if (ctx.config.debug) {
			Sys.println("BEFORE:\n" + core.TPrinting.sExprDebug(expr));
			CoroDebug.createDotgraph(DotGraph.getDumpPath(SafeCom.ofCom(ctx.typer.com), ctx.typer.c.curclass.clPath, name), root);
		}
		var e = mk(TFunction({tfArgs: tfArgs, tfExpr: tfExpr, tfType: tfType}),
			TFun({args: tfArgs.map(function(a) return {name: a.variable.vName, optional: false, type: a.variable.vType}), ret: tfType}),
			tfExpr.epos);
		if (ctx.config.debug) Sys.println("AFTER:\n" + core.TPrinting.sExprDebug(e));
		return e;
	}

	public static function createCoroContext(typer:context.Typecore.Typer, config:coro.CoroConfig.CoroConfigData, type:CoroFor):CoroCtx {
		var p = switch type {
			case ClassField(_, cf, _, _): cf.cfNamePos;
			case LocalFunc(_, v): v.vPos;
		};
		return {
			builder: new TexprBuilder(typer.t, p),
			typer: typer,
			config: config,
			coroType: type,
			classNamePos: p,
			deferredExprs: [],
			hasCaptureVars: false,
			capturesThis: false,
			nextBlockId: 0,
			currentCatch: null,
			hasCatch: false,
			numStates: 0
		};
	}
}
