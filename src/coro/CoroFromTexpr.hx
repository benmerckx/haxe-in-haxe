package coro;

import context.SafeCom;
import context.PlatformConfig;
import filters.safe.CapturedVars;
import optimization.OptimizerTexpr;
import core.ds.Exit;
import core.Error;
import core.Texpr.*;
import core.Texpr;
import core.Texpr.Builder;
import core.TOther;
import core.ds.AtomicLazy;
import context.Common;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.Ast;
import core.Globals;
import core.Globals.*;
import coro.CoroTypes;
import coro.CoroFunctions.*;

// haxe/src/coro/coroFromTexpr.ml — mechanical draft; not compile-validated.
enum CoroRet {
	RLocal(v:TVar);
	RTerminate(f:CoroBlock->TExpr->Void);
	RValue;
	RBlock;
	RMapExpr(ret:CoroRet, f:TExpr->TExpr);
	RTailBlock;
	RTailReturn;
}

enum MapSuspensionResult {
	HasSuspension;
	HasNoSuspension(e:TExpr);
}

private class FoundSuspension extends haxe.Exception {
	public function new() super("Found");
}

private typedef BlockValue = {var cb:CoroBlock; var e:TExpr;}

class CoroFromTexpr {
	public static var eNoValue:TExpr = Builder.makeNull(tDynamic, nullPos);

	public static function getOutcomeFromCallee(e1:TExpr):coro.CoroConfig.CoroOutcome {
		var meta = switch Texpr.skip(e1).eexpr {
			case TField(_, FStatic(_, cf)) | TField(_, FInstance(_, _, cf)) | TField(_, FClosure(_, cf)) | TField(_, FAnon(cf)): cf.cfMeta;
			case TLocal(v): v.vMeta;
			case _: [];
		};
		return CoroConfig.ofMetaList(meta).outcome;
	}

	public static function checkCaptures(ctx:CoroCtx, args:Array<{variable:TVar, defaultValue:Null<TExpr>}>, expr:TExpr):Void {
		var vars:Map<Int, Bool> = [];
		inline function declare(v:TVar):Void vars.set(v.vId, true);
		for (a in args) declare(a.variable);
		function browse(e:TExpr):Void switch e.eexpr {
			case TConst(TThis | TSuper):
				ctx.capturesThis = true;
			case TLocal(v):
				if (!vars.exists(v.vId)) ctx.hasCaptureVars = true;
			case TVar(v, eo):
				declare(v);
				if (eo != null) browse(eo);
			case TTry(e1, catches):
				browse(e1);
				for (c in catches) {
					declare(c.variable);
					browse(c.expr);
				}
			case TFunction(tf):
				for (a in tf.tfArgs) declare(a.variable);
				browse(tf.tfExpr);
			case _:
				core.Texpr.iter(browse, e);
		};
		browse(expr);
	}

	public static function exprToCoro(ctx:CoroCtx, etmpResult:AtomicLazy<TExpr>, etmpErrorUnwrapped:AtomicLazy<TExpr>, cbRoot:CoroBlock,
			scope:Null<CoroScope>, deferred:CoroDeferredApi, e:TExpr):Null<BlockValue> {
		var wrapper = ctx.typer.com.localWrapper;
		var scom = SafeCom.ofCom(ctx.typer.com);
		scom = {
			var recordCopy36 = core.ds.Record.copy(scom);
			recordCopy36.platformConfig = {
				var recordCopy35 = core.ds.Record.copy(scom.platformConfig);
				recordCopy35.pfCapturePolicy = CPWrapRef;
				recordCopy35;
			};
			recordCopy36;
		};
		e = CapturedVars.capturedVars(scom, wrapper, true, e);
		inline function makeBlock(tp:Null<{t:T, p:core.Globals.Pos}>):CoroBlock return CoroFunctions.makeBlock(ctx, tp);
		inline function blockFromE(e:TExpr):CoroBlock return makeBlock({t: e.etype, p: e.epos});
		inline function hasSideEffect(e:TExpr):Bool return switch e.eexpr {
			case TVar(_, _): true;
			case _: OptimizerTexpr.hasSideEffect(e);
		};
		inline function addExpr(cb:CoroBlock,
				e:TExpr):Void if (cb.cbNext == NextUnknown && e != eNoValue && hasSideEffect(e)) cb.cbEl.push(e);
		inline function terminate(cb:CoroBlock, kind:CoroNext, t:T, p:Pos):Void if (cb.cbNext == NextUnknown) cb.cbNext = kind;
		inline function fallThrough(a:CoroBlock, b:CoroBlock):Void terminate(a, NextFallThrough(b), tDynamic, nullPos);
		inline function gotoBlock(a:CoroBlock, b:CoroBlock):Void terminate(a, NextGoto(b), tDynamic, nullPos);
		inline function tmpLocal(cb:CoroBlock, t:T, eo:Null<TExpr>, p:Pos):TVar {
			var v = allocVar(VGenerated, "tmp", t, p);
			addExpr(cb, mk(TVar(v, eo), ctx.typer.t.tvoid, p));
			return v;
		}
		function checkComplex(cb:CoroBlock, ret:CoroRet, t:T, p:Pos):{e:TExpr, ret:CoroRet}
			return switch ret {
				case RValue:
					var v = tmpLocal(cb, t, null, p);
					{e: Builder.makeLocal(v, v.vPos), ret: RLocal(v)};
				case RLocal(v): {e: Builder.makeLocal(v, v.vPos), ret: ret};
				case RMapExpr(inner, f):
					var r = checkComplex(cb, inner, t, p);
					r.e == eNoValue ? {e: eNoValue, ret: RMapExpr(r.ret, f)} : {e: f(r.e), ret: r.ret};
				case _: {e: eNoValue, ret: ret};
			};
		inline function scopeAllowsSuspensionCallOn(e1:TExpr, args:Array<{name:String, optional:Bool, type:T}>, el:Array<TExpr>):Bool {
			if (scope == null || !scope.restrictedSuspension) return true;
			function isScopeLocalExpr(e:TExpr):Bool return switch Texpr.skip(e).eexpr {
				case TLocal(v) if (v == scope.scopeVar): true;
				case TField(e1, _): isScopeLocalExpr(e1);
				case _: false;
			};
			inline function isRestricted(meta:core.Ast.Metadata):Bool {
				var c = CoroScopeConfig.ofMetaList(meta);
				return c != null && c.restrictedSuspension;
			}
			inline function hasScopeLocalFirstArgument():Bool {
				if (args.length == 0 || el.length == 0 || !isScopeLocalExpr(el[0])) return false;
				return switch e1.eexpr {
					case TField(_, FStatic({clKind: KAbstractImpl(a)}, cf)) if (hasClassFieldFlag(cf, CfImpl)): isRestricted(a.aMeta);
					case _: try {
							isRestricted(tInfos(moduleTypeOfType(args[0].type)).mtMeta);
						} catch (e:Exit) {
							false;
						}
				};
			}
			return isScopeLocalExpr(e1) || hasScopeLocalFirstArgument();
		}
		inline function scopeAllowsAccessTo(v:TVar):Bool return scope == null || scope.scopeVar == v;
		inline function isCoro(e:TExpr):Bool return switch followWithCoro(e.etype) {
			case Coro({args: _, ret: _}): true;
			case _: false;
		};
		inline function mapSuspension(cb:CoroBlock, ret:CoroRet, e:TExpr):MapSuspensionResult {
			var allowTco = (switch ret {
				case RTailBlock | RTailReturn: true;
				case _: false;
			}) && cb.cbCatch == null && !ctx.typer.com.debug;
			function remap(canTco:Bool, loopDepth:Int, e:TExpr):TExpr return switch e.eexpr {
				case TConst(TThis): deferred.makeThis(e);
				case TField({eexpr: TConst(TSuper)}, _): deferred.makeSuperField(e);
				case TCall(e1, el) if (isCoro(e1)):
					if (!canTco) throw new FoundSuspension();
					deferred.makeInlineTailCall({
						csFun: e1,
						csArgs: el,
						csPos: e.epos,
						csResult: SusBlock,
						csKind: getOutcomeFromCallee(e1)
					});
				case TReturn(null): deferred.makeInlineReturn(null, e.epos);
				case TReturn(e1): switch e1.eexpr {
						case TCall(efun, _) if (isCoro(efun)): remap(canTco, loopDepth, e1);
						case _: deferred.makeInlineReturn(remap(false, loopDepth, e1), e.epos);
					}
				case TThrow(_): throw new FoundSuspension();
				case TBreak | TContinue if (loopDepth == 0): throw new FoundSuspension();
				case TBlock([]): e;
				case TBlock(el):
					// remap_block conses `remap hd :: remap_block tl`: OCaml remaps the tail first (the deferred
					// expressions allocate variables, and a later suspension aborts the mapping)
					var out = [for (_ in el) null];
					var i = el.length;
					while (i-- > 0) out[i] = remap(i == el.length - 1 ? canTco : false, loopDepth, el[i]);
					{var recordCopy34 = core.ds.Record.copy(e); recordCopy34.eexpr = TBlock(out); recordCopy34;};
				case TIf(e1, e2, e3):
					var a = remap(false, loopDepth, e1);
					var b = remap(canTco, loopDepth, e2);
					var c = e3 == null ? null : remap(canTco, loopDepth, e3);
					{var recordCopy33 = core.ds.Record.copy(e); recordCopy33.eexpr = TIf(a, b, c); recordCopy33;};
				case TSwitch(s):
					var subject = remap(false, loopDepth, s.switchSubject);
					var cases = s.switchCases.map(function(c) return {
						var recordCopy32 = core.ds.Record.copy(c);
						recordCopy32.caseExpr = remap(canTco, loopDepth, c.caseExpr);
						recordCopy32;
					});
					var def = s.switchDefault == null ? null : remap(canTco, loopDepth, s.switchDefault);
					{
						var recordCopy31 = core.ds.Record.copy(e);
						recordCopy31.eexpr = TSwitch({
							var recordCopy30 = core.ds.Record.copy(s);
							recordCopy30.switchSubject = subject;
							recordCopy30.switchCases = cases;
							recordCopy30.switchDefault = def;
							recordCopy30;
						});
						recordCopy31;
					};
				case TTry(e1, catches):
					var e1 = remap(false, loopDepth, e1);
					var catches = catches.map(function(c) return {variable: c.variable, expr: remap(canTco, loopDepth, c.expr)});
					{var recordCopy29 = core.ds.Record.copy(e); recordCopy29.eexpr = TTry(e1, catches); recordCopy29;};
				case TWhile(e1, e2, flag):
					var e1 = remap(false, loopDepth, e1);
					var e2 = remap(false, loopDepth + 1, e2);
					{var recordCopy28 = core.ds.Record.copy(e); recordCopy28.eexpr = TWhile(e1, e2, flag); recordCopy28;};
				case TFunction(_): e;
				case _: core.Texpr.mapExpr(function(e) return remap(false, loopDepth, e), e);
			};
			return try HasNoSuspension(remap(allowTco, 0, e)) catch (e:FoundSuspension) HasSuspension;
		}
		var loopStack:Array<{body:CoroBlock, next:AtomicLazy<CoroBlock>}> = [];
		var loop:CoroBlock->CoroRet->TExpr->Null<BlockValue> = null;
		var loopAssign:CoroBlock->CoroRet->TExpr->Null<BlockValue> = null;
		var loopBlock:CoroBlock->CoroRet->TExpr->Null<BlockValue> = null;
		function orderedLoop(cb:CoroBlock, el:Array<TExpr>):Null<{cb:CoroBlock, el:Array<TExpr>}> {
			var acc = [];
			for (e in el) {
				var r = loop(cb, RValue, e);
				if (r == null) {
					for (a in acc) addExpr(cb, a);
					return null;
				}
				cb = r.cb;
				acc.push(r.e);
			}
			return {cb: cb, el: acc};
		}
		inline function splitIfThen(cb:CoroBlock, e1:TExpr, etype:T, epos:Pos, e2:TExpr):BlockValue {
			var a = blockFromE(e2);
			var an = loopBlock(a, RBlock, e2);
			var n = makeBlock(null);
			if (an != null) fallThrough(an.cb, n);
			terminate(cb, NextIfThen(e1, a, n), etype, epos);
			return {cb: n, e: eNoValue};
		}
		inline function splitIfThenElse(cb:CoroBlock, ret:CoroRet, etype:T, epos:Pos, e1:TExpr, e2:TExpr, e3:TExpr):Null<BlockValue> {
			var complex = checkComplex(cb, ret, etype, epos);
			ret = complex.ret;
			var r = loop(cb, RValue, e1);
			if (r == null) return null;
			cb = r.cb;
			e1 = r.e;
			var a = blockFromE(e2);
			var an = loopBlock(a, ret, e2);
			var b = blockFromE(e3);
			var bn = loopBlock(b, ret, e3);
			var n = null;
			if (an != null || bn != null) {
				n = makeBlock(null);
				if (an != null) fallThrough(an.cb, n);
				if (bn != null) fallThrough(bn.cb, n);
			}
			terminate(cb, NextIfThenElse(e1, a, b, n), etype, epos);
			return n == null ? null : {cb: n, e: complex.e};
		}
		inline function splitSwitch(cb:CoroBlock, ret:CoroRet, s:TSwitch, e:TExpr):Null<BlockValue> {
			var complex = checkComplex(cb, ret, e.etype, e.epos);
			ret = complex.ret;
			var r = loop(cb, RValue, s.switchSubject);
			if (r == null) return null;
			cb = r.cb;
			var next = AtomicLazy.fromFun(function() return makeBlock(null));
			var cases = [
				for (c in s.switchCases) {
					var b = blockFromE(c.caseExpr);
					var n = loopBlock(b, ret, c.caseExpr);
					if (n != null) fallThrough(n.cb, (next).force());
					{el: c.casePatterns, cb: b};
				}
			];
			var def = null;
			if (s.switchDefault != null) {
				def = blockFromE(s.switchDefault);
				var n = loopBlock(def, ret, s.switchDefault);
				if (n != null) fallThrough(n.cb, (next).force());
			}
			var sw = ({
				csSubject: r.e,
				csCases: cases,
				csDefault: def,
				csExhaustive: s.switchExhaustive
			} : coro.CoroTypes.CoroSwitch);
			var n = (next).isVal() || !sw.csExhaustive ? (next).force() : null;
			terminate(cb, NextSwitch(sw, n), e.etype, e.epos);
			return n == null ? null : {cb: n, e: complex.e};
		}
		inline function splitWhile(cb:CoroBlock, e1:TExpr, e2:TExpr, etype:T, epos:Pos):Null<BlockValue> {
			var next = AtomicLazy.fromFun(function() return makeBlock(null));
			var body = blockFromE(e2);
			loopStack.unshift({body: body, next: next});
			var bn = loopBlock(body, RBlock, e2);
			if (bn != null) gotoBlock(bn.cb, body);
			loopStack.shift();
			var n = (next).isVal() ? (next).force() : null;
			terminate(cb, NextWhile(e1, body, n), etype, epos);
			return n == null ? null : {cb: n, e: eNoValue};
		}
		inline function splitTry(cb:CoroBlock, ret:CoroRet, e1:TExpr, catches:Array<{variable:TVar, expr:TExpr}>, etype:T,
				epos:Pos):Null<BlockValue> {
			var complex = checkComplex(cb, ret, etype, epos);
			ret = complex.ret;
			ctx.hasCatch = true;
			var next = AtomicLazy.fromFun(function() return makeBlock(null));
			var catches = catches.map(function(c) {
				var b = blockFromE(c.expr);
				addExpr(b, mk(TVar(c.variable, (etmpErrorUnwrapped).force()), ctx.typer.t.tvoid, c.variable.vPos));
				var n = loopBlock(b, ret, c.expr);
				if (n != null) fallThrough(n.cb, (next).force());
				return {v: c.variable, cb: b};
			});
			var catchBlock = makeBlock(null);
			addBlockFlag(catchBlock, CbGenerated);
			var old = ctx.currentCatch;
			ctx.currentCatch = catchBlock;
			var ca = ({ccCb: catchBlock, ccCatches: catches} : coro.CoroTypes.CoroCatch);
			var body = blockFromE(e1);
			var bn = loopBlock(body, ret, e1);
			ctx.currentCatch = old;
			if (bn != null) fallThrough(bn.cb, (next).force());
			var n = (next).isVal() ? (next).force() : null;
			terminate(cb, NextTry(body, ca, n), etype, epos);
			return n == null ? null : {cb: n, e: complex.e};
		}
		loop = function(cb, ret, e) {
			inline function mapped(r:Null<BlockValue>, f:TExpr->TExpr):Null<BlockValue> return r == null ? null : {cb: r.cb, e: f(r.e)};
			return switch e.eexpr {
				case TConst(TThis): {cb: cb, e: deferred.makeThis(e)};
				case TField({eexpr: TConst(TSuper)}, _): {cb: cb, e: deferred.makeSuperField(e)};
				case TBlock([]): {cb: cb, e: e};
				case TLocal(v) if (hasVarFlag(v,
					VCoroScope) && !scopeAllowsAccessTo(v)): Error.raiseTypingError("Invalid usage of a coroutine scope in a different coroutine scope",
						e.epos);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_): {cb: cb, e: e};
				case TBlock([e1]): loop(cb, ret, e1);
				case TBlock(_): switch mapSuspension(cb, ret, e) {
						case HasNoSuspension(e): {cb: cb, e: e};
						case HasSuspension: loopBlock(cb, ret, e);
					}
				case TArray(e1, e2):
					var r = orderedLoop(cb, [e1, e2]);
					r == null ? null : {
						cb: r.cb,
						e: {
							var recordCopy27 = core.ds.Record.copy(e);
							recordCopy27.eexpr = TArray(r.el[0], r.el[1]);
							recordCopy27;
						}
					};
				case TArrayDecl(el):
					var r = orderedLoop(cb, el);
					r == null ? null : {
						cb: r.cb,
						e: {var recordCopy26 = core.ds.Record.copy(e); recordCopy26.eexpr = TArrayDecl(r.el); recordCopy26;}
					};
				case TObjectDecl(fl):
					var r = orderedLoop(cb, fl.map(function(f) return f.expr));
					r == null ? null : {
						cb: r.cb,
						e: {
							var recordCopy25 = core.ds.Record.copy(e);
							recordCopy25.eexpr = TObjectDecl([
								for (i in 0...fl.length) {
									key: fl[i].key,
									expr: r.el[i]
								}
							]);
							recordCopy25;
						}
					};
				case TField(e1, fa): mapped(loop(cb, RValue, e1), function(e1) return {
						var recordCopy24 = core.ds.Record.copy(e);
						recordCopy24.eexpr = TField(e1, fa);
						recordCopy24;
					});
				case TEnumParameter(e1, ef, i): mapped(loop(cb, RValue, e1), function(e1) return {
						var recordCopy23 = core.ds.Record.copy(e);
						recordCopy23.eexpr = TEnumParameter(e1, ef, i);
						recordCopy23;
					});
				case TEnumIndex(e1): mapped(loop(cb, RValue, e1), function(e1) return {
						var recordCopy22 = core.ds.Record.copy(e);
						recordCopy22.eexpr = TEnumIndex(e1);
						recordCopy22;
					});
				case TNew(c, tl, el):
					var r = orderedLoop(cb, el);
					r == null ? null : {
						cb: r.cb,
						e: {
							var recordCopy21 = core.ds.Record.copy(e);
							recordCopy21.eexpr = TNew(c, tl, r.el);
							recordCopy21;
						}
					};
				case TCast(e1, o):
					function f(e1:TExpr):TExpr return {
						var recordCopy20 = core.ds.Record.copy(e);
						recordCopy20.eexpr = TCast(e1, o);
						recordCopy20;
					};
					mapped(loop(cb, RMapExpr(ret, f), e1), function(e1) return e1 == eNoValue ? e1 : f(e1));
				case TParenthesis(e1):
					function f(e1:TExpr):TExpr return {
						var recordCopy19 = core.ds.Record.copy(e);
						recordCopy19.eexpr = TParenthesis(e1);
						recordCopy19;
					};
					mapped(loop(cb, RMapExpr(ret, f), e1), function(e1) return e1 == eNoValue ? e1 : f(e1));
				case TMeta(meta, e1): mapped(loop(cb, ret, e1), function(e1) return {
						var recordCopy18 = core.ds.Record.copy(e);
						recordCopy18.eexpr = TMeta(meta, e1);
						recordCopy18;
					});
				case TUnop(op, flag, e1): mapped(loop(cb, ret, e1), function(e1) return {
						var recordCopy17 = core.ds.Record.copy(e);
						recordCopy17.eexpr = TUnop(op, flag, e1);
						recordCopy17;
					});
				case TBinop(OpAssign, e1 = {eexpr: TLocal(v)}, e2): mapped(loopAssign(cb, RLocal(v), e2), function(e2) return {
						var recordCopy16 = core.ds.Record.copy(e);
						recordCopy16.eexpr = TBinop(OpAssign, e1, e2);
						recordCopy16;
					});
				case TBinop(op = (OpBoolOr | OpBoolAnd), e1, e2): switch mapSuspension(cb, ret, e) {
						case HasNoSuspension(e): {cb: cb, e: e};
						case HasSuspension:
							var thenE = op == OpBoolOr ? mk(TConst(TBool(true)), e.etype, e.epos) : e2;
							var elseE = op == OpBoolOr ? e2 : mk(TConst(TBool(false)), e.etype, e.epos);
							splitIfThenElse(cb, ret, e.etype, e.epos, e1, thenE, elseE);
					}
				case TBinop(op, e1, e2):
					var r = loop(cb, RValue, e1);
					if (r == null) null; else {
						var r2 = loop(r.cb, RValue, e2);
						if (r2 == null) {
							addExpr(r.cb, r.e);
							null;
						} else {
							cb: r2.cb,
							e: {
								var recordCopy15 = core.ds.Record.copy(e);
								recordCopy15.eexpr = TBinop(op, r.e, r2.e);
								recordCopy15;
							}
						};
					}
				case TVar(v, null):
					addExpr(cb, e);
					{cb: cb, e: eNoValue};
				case TVar(v, e1):
					addExpr(cb, {var recordCopy14 = core.ds.Record.copy(e); recordCopy14.eexpr = TVar(v, null); recordCopy14;});
					loopAssign(cb, RLocal(v), e1);
				case TCall(e1, el):
					var r = orderedLoop(cb, [e1].concat(el));
					if (r == null) null; else {
						cb = r.cb;
						var argsExprs = r.el;
						var e1 = argsExprs.shift();
						if (e1 == null) throw "assert";
						switch followWithCoro(e1.etype) {
							case Coro({args: args, ret: _}):
								if (!scopeAllowsSuspensionCallOn(e1, args,
									argsExprs)) Common.displayError(ctx.typer.com,
										"Invalid suspension call in restricted suspension scope", e.epos);
								var affection = OptimizerTexpr.createAffectionChecker();
								argsExprs = argsExprs.map(function(e) {
									var effect = hasSideEffect(e);
									var affected = affection.mightBeAffected(e);
									if (effect) affection.collectModifiedLocals(e);
									if (effect || affected) {
										var v = tmpLocal(cb, e.etype, e, e.epos);
										return Builder.makeLocal(v, v.vPos);
									}
									return e;
								});
								var kind = getOutcomeFromCallee(e1);
								inline function makeNextBlock():CoroBlock {
									var n = blockFromE(e1);
									addBlockFlag(n, CbResumeState);
									addBlockFlag(cb, CbSuspendState);
									return n;
								}
								var isTco = (switch ret {
									case RTailBlock | RTailReturn: true;
									case _: false;
								}) && cb.cbCatch == null && !ctx.typer.com.debug;
								if (kind.noSuspend) {
									if (isTco) {
										var s = ({
											csFun: e1,
											csArgs: argsExprs,
											csPos: e.epos,
											csResult: ret == RTailBlock ? SusBlock : SusResult,
											csKind: kind
										} : coro.CoroTypes.CoroSuspend);
										terminate(cb, NextSuspend(s, null), tDynamic, nullPos);
										null;
									} else {
										var needsResult = switch ret {
											case RBlock | RTailBlock: false;
											case _: true;
										};
										var ev = needsResult ? (etmpResult).force() : eNoValue;
										var s = ({
											csFun: e1,
											csArgs: argsExprs,
											csPos: e.epos,
											csResult: needsResult ? SusResult : SusBlock,
											csKind: kind
										} : coro.CoroTypes.CoroSuspend);
										addExpr(cb, deferred.makeSyncCall(s, needsResult ? ev : null));
										{cb: cb, e: ev};
									}
								} else {
									var result:SuspendExpr;
									var next:Null<BlockValue>;
									switch ret {
										case RValue:
											var v = tmpLocal(cb, e.etype, null, e.epos);
											var ev = Builder.makeLocal(v, v.vPos);
											var n = makeNextBlock();
											n.cbStackValue = ev;
											result = SusResult;
											next = {cb: n, e: ev};
										case RTailBlock if (cb.cbCatch == null && !ctx.typer.com.debug):
											result = SusBlock;
											next = null;
										case RBlock | RTailBlock:
											result = SusBlock;
											next = {cb: makeNextBlock(), e: eNoValue};
										case RTailReturn if (cb.cbCatch == null && !ctx.typer.com.debug):
											result = SusResult;
											next = null;
										case RTerminate(_) | RMapExpr(_, _) | RLocal(_) | RTailReturn:
											result = SusResult;
											next = {cb: makeNextBlock(), e: (etmpResult).force()};
									}
									terminate(cb, NextSuspend({
										csFun: e1,
										csArgs: argsExprs,
										csPos: e.epos,
										csResult: result,
										csKind: kind
									}, next == null ? null : next.cb), tDynamic, nullPos);
									next;
								}
							case _: {
									cb: cb,
									e: {
										var recordCopy13 = core.ds.Record.copy(e);
										recordCopy13.eexpr = TCall(e1, argsExprs);
										recordCopy13;
									}
								};
						}
					}
				case TBreak:
					if (loopStack.length > 0) terminate(cb, NextBreak((loopStack[0].next).force()), e.etype, e.epos);
					null;
				case TContinue:
					if (loopStack.length > 0) terminate(cb, NextContinue(loopStack[0].body), e.etype, e.epos);
					null;
				case TReturn(null):
					terminate(cb, NextReturnVoid, e.etype, e.epos);
					null;
				case TReturn(e1):
					var r = loopAssign(cb, RTailReturn, e1);
					if (r != null) terminate(r.cb, NextReturn(r.e), e.etype, e.epos);
					null;
				case TThrow(e1):
					var ret = RTerminate(function(cb, e1) terminate(cb, NextThrow(e1), e.etype, e.epos));
					var r = loopAssign(cb, ret, e1);
					if (r != null) terminate(r.cb, NextThrow(r.e), e.etype, e.epos);
					null;
				case TIf(e1, e2, null):
					var r = loop(cb, RValue, e1);
					r == null ? null : switch mapSuspension(r.cb, ret, e2) {
						case HasNoSuspension(e2):
							addExpr(r.cb,
								{var recordCopy12 = core.ds.Record.copy(e); recordCopy12.eexpr = TIf(r.e, e2, null); recordCopy12;});
							{cb: r.cb, e: eNoValue};
						case HasSuspension: splitIfThen(r.cb, r.e, e.etype, e.epos, e2);
					};
				case TIf(e1, e2, e3): switch [mapSuspension(cb, ret, e2), mapSuspension(cb, ret, e3)] {
						case [HasNoSuspension(a), HasNoSuspension(b)]: mapped(loop(cb, RValue, e1), function(e1) return {
								var recordCopy11 = core.ds.Record.copy(e);
								recordCopy11.eexpr = TIf(e1, a, b);
								recordCopy11;
							});
						case _: splitIfThenElse(cb, ret, e.etype, e.epos, e1, e2, e3);
					}
				case TSwitch(s):
					var cases = [];
					var success = true;
					for (c in s.switchCases) {
						switch mapSuspension(cb, ret, c.caseExpr) {
							case HasNoSuspension(ce): cases.push({var recordCopy10 = core.ds.Record.copy(c); recordCopy10.caseExpr = ce; recordCopy10;});
							case HasSuspension: success = false;
						}
						if (!success) break;
					}
					var def = null;
					if (success && s.switchDefault != null) switch mapSuspension(cb, ret, s.switchDefault) {
						case HasNoSuspension(e): def = e;
						case HasSuspension: success = false;
					}
					success ? mapped(loop(cb, RValue, s.switchSubject), function(e1) return {
						var recordCopy9 = core.ds.Record.copy(e);
						recordCopy9.eexpr = TSwitch({
							var recordCopy8 = core.ds.Record.copy(s);
							recordCopy8.switchSubject = e1;
							recordCopy8.switchCases = cases;
							recordCopy8.switchDefault = def;
							recordCopy8;
						});
						recordCopy9;
					}) : splitSwitch(cb, ret, s, e);
				case TWhile(e1, e2,
					flag) if (!isTrueExpr(e1)): loop(cb, ret,
						Texpr.notWhileTrueToWhileTrue(ctx.typer.com.basic, e1, e2, flag, e.etype, e.epos));
				case TWhile(e1, e2, flag): switch mapSuspension(cb, RBlock, e2) {
						case HasNoSuspension(e2):
							addExpr(cb, {var recordCopy7 = core.ds.Record.copy(e); recordCopy7.eexpr = TWhile(e1, e2, flag); recordCopy7;});
							{cb: cb, e: eNoValue};
						case HasSuspension: splitWhile(cb, e1, e2, e.etype, e.epos);
					}
				case TTry(e1, catches):
					var mappedBody = mapSuspension(cb, RBlock, e1);
					var cs = [];
					var success = true;
					for (c in catches) {
						switch mapSuspension(cb, RBlock, c.expr) {
							case HasNoSuspension(e): cs.push({variable: c.variable, expr: e});
							case HasSuspension: success = false;
						}
						if (!success) break;
					}
					switch mappedBody {
						case HasNoSuspension(e1) if (success): {
								cb: cb,
								e: {var recordCopy6 = core.ds.Record.copy(e); recordCopy6.eexpr = TTry(e1, cs); recordCopy6;}
							};
						case _: splitTry(cb, ret, e1, catches, e.etype, e.epos);
					}
				case TFunction(_): {cb: cb, e: e};
			};
		};
		loopAssign = function(cb, ret, e) {
			var r = loop(cb, ret, e);
			function aux(ret:CoroRet, r:Null<BlockValue>):Null<BlockValue> {
				if (r == null || r.e == eNoValue) return r;
				return switch ret {
					case RBlock | RTailBlock:
						addExpr(r.cb, r.e);
						{cb: r.cb, e: eNoValue};
					case RValue: r;
					case RLocal(v):
						var ev = Builder.makeLocal(v, v.vPos);
						addExpr(r.cb, Builder.binop(OpAssign, ev, r.e, ev.etype, ev.epos));
						{cb: r.cb, e: ev};
					case RTerminate(f):
						f(r.cb, r.e);
						null;
					case RMapExpr(ret, f): aux(ret, {cb: r.cb, e: f(r.e)});
					case RTailReturn:
						terminate(r.cb, NextReturn(r.e), tDynamic, nullPos);
						null;
				};
			}
			return aux(ret, r);
		};
		loopBlock = function(cb, ret, e) {
			var el = switch e.eexpr {
				case TBlock(el): el;
				case _: [e];
			};
			if (el.length == 0) return {cb: cb, e: eNoValue};
			for (i in 0...el.length - 1) {
				var r = loop(cb, RBlock, el[i]);
				if (r == null) return null;
				cb = r.cb;
				addExpr(cb, r.e);
			}
			return loopAssign(cb, ret, el[el.length - 1]);
		};
		return loopBlock(cbRoot, RTailBlock, e);
	}
}
