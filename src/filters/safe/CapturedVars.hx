package filters.safe;

import context.PlatformConfig;
import core.TType;
import core.TFunctions as TypeOps;
import core.Texpr;
import filters.LocalUsage;
import haxe.ds.IntMap;

// haxe/src/filters/safe/capturedVars.ml — mechanical draft; not compiled or validated.
// Persistent-map snapshots use copies. Sorted integer keys retain OCaml PMap fold order.
class CapturedVars {
	static function ids<T>(m:IntMap<T>):Array<Int> {
		var a = [for (i in m.keys()) i];
		a.sort((a, b) -> a - b);
		return a;
	}

	public static function capturedVars(scom:context.SafeCom.SafeContext, impl:context.Common.LocalWrapperApi, forCoro:Bool,
			e:TExpr):TExpr {
		inline function mkVar(v:TVar, used:IntMap<T>):TVar {
			if (!used.exists(v.vId)) throw "Not_found";
			var v2 = TypeOps.allocVar(v.vKind, v.vName, used.get(v.vId), v.vPos);
			v2.vMeta = v.vMeta;
			return v2;
		}
		function wrap(used:IntMap<T>, e:TExpr):TExpr {
			var def:TExprDef = switch e.eexpr {
				case TVar(v, ve):
					var ve = ve == null ? null : wrap(used, ve);
					TVar(v, used.exists(v.vId) ? impl.mkRef(v, ve, e.epos) : ve);
				case TLocal(v) if (used.exists(v.vId)): return impl.mkRefAccess(e, v);
				case TTry(expr, catches):
					var catches = catches.map(function(c) {
						var body = wrap(used, c.expr);
						if (!used.exists(c.variable.vId)) return {variable: c.variable, expr: body};
						var vtmp = mkVar(c.variable, used);
						return {variable: vtmp, expr: TypeOps.concat(impl.mkInit(c.variable, vtmp, body.epos), body)};
					});
					TTry(wrap(used, expr), catches);
				case TFunction(f):
					var fused = new IntMap<TVar>();
					var tmpUsed = used.copy();
					function browse(u:Usage):Void switch u {
						case Block(f) | Loop(f) | Function(f):
							f(browse);
						case Use(v) | Assign(v):
							if (tmpUsed.exists(v.vId)) fused.set(v.vId, v);
						case Declare(v):
							tmpUsed.remove(v.vId);
					}
					LocalUsage.localUsage(browse, e);
					var vars:Array<TVar> = [];
					for (id in ids(fused)) vars.unshift(fused.get(id));
					var fexpr = wrap(used, f.tfExpr);
					var fargs = f.tfArgs.map(function(a) {
						if (!used.exists(a.variable.vId)) return a;
						var vtmp = mkVar(a.variable, used);
						fexpr = TypeOps.concat(impl.mkInit(a.variable, vtmp, e.epos), fexpr);
						return {variable: vtmp, defaultValue: a.defaultValue};
					});
					var e = TypeOps.mk(TFunction(({tfArgs: fargs, tfType: f.tfType, tfExpr: fexpr} : core.TType.TFunc)), e.etype, e.epos);
					if (scom.platformConfig.pfCapturePolicy != CPLoopVars) return e;
					var newVars = vars.map(v -> {id: v.vId, variable: TypeOps.allocVar(v.vKind, v.vName, v.vType, v.vPos)});
					function loop(e:TExpr):TExpr return switch e.eexpr {
						case TLocal(v):
							var vnew:Null<TVar> = null;
							for (entry in newVars) if (entry.id == v.vId) {
								vnew = entry.variable;
								break;
							}
							if (vnew == null) e; else {
								TypeOps.addVarFlag(vnew, VCaptured);
								TypeOps.mk(TLocal(vnew), e.etype, e.epos);
							}
						case _: core.Texpr.mapExpr(loop, e);
					};
					e = loop(e);
					var fn:TFunc = {
						tfArgs: newVars.map(a -> {variable: a.variable, defaultValue: null}),
						tfType: e.etype,
						tfExpr: TypeOps.mkBlock(TypeOps.mk(TReturn(e), e.etype, e.epos))
					};
					var ft = TFun({
						args: newVars.map(a -> {name: a.variable.vName, optional: false, type: a.variable.vType}),
						ret: e.etype
					});
					return TypeOps.mk(TCall(Texpr.Builder.mkParent(TypeOps.mk(TFunction(fn), ft, e.epos)),
						vars.map(v -> TypeOps.mk(TLocal(v), v.vType, e.epos))),
						e.etype, e.epos);
				case _: return core.Texpr.mapExprWith(wrap, used, e);
			};
			return TypeOps.mk(def, e.etype, e.epos);
		}
		inline function doWrap(used:IntMap<TVar>, e:TExpr):TExpr {
			var keys = ids(used);
			if (keys.length == 0) return e;
			var types = new IntMap<T>();
			for (id in keys) {
				var v = used.get(id);
				var vt = v.vType;
				v.vType = impl.capturedType(vt);
				TypeOps.addVarFlag(v, VCaptured);
				if (forCoro) TypeOps.addVarFlag(v, VCoroCaptured);
				types.set(id, vt);
			}
			return wrap(types, e);
		}
		function outLoop(e:TExpr):TExpr {
			switch e.eexpr {
				case TWhile(_, _, _):
					var vars = new core.ds.ScopedIntMap();
					var used = new IntMap<TVar>();
					var depth = 0;
					function collectVars(inLoop:Bool, u:Usage):Void switch u {
						case Block(f):
							var old = vars.mark();
							f(u -> collectVars(inLoop, u));
							vars.rollback(old);
						case Loop(f):
							var old = vars.mark();
							f(u -> collectVars(true, u));
							vars.rollback(old);
						case Function(f):
							++depth;
							f(u -> collectVars(false, u));
							--depth;
						case Declare(v):
							if (inLoop) vars.set(v.vId, depth);
						case Use(v) | Assign(v):
							if (vars.exists(v.vId) && vars.get(v.vId) != depth) used.set(v.vId, v);
					}
					LocalUsage.localUsage(u -> collectVars(false, u), e);
					return doWrap(used, e);
				case _:
					return core.Texpr.mapExpr(outLoop, e);
			}
		}
		inline function allVars(e:TExpr):IntMap<TVar> {
			// Scoped maps: restoring a saved PMap is a rollback rather than a copy per scope.
			var vars = new core.ds.ScopedIntMap();
			var used = new IntMap<TVar>();
			var inLoop = false;
			var loopVars = new core.ds.ScopedIntMap(); /* 1 when assigned */ var assigned = new IntMap<TVar>();
			var depth = 0;
			inline function markAssigned(v:TVar):Void {
				assigned.set(v.vId, v);
				vars.remove(v.vId);
			}
			inline function checkLoopVar(v:TVar, isAssign:Bool):Void {
				if (!inLoop) return;
				if (loopVars.exists(v.vId)) {
					if (isAssign != (loopVars.get(v.vId) == 1)) markAssigned(v);
				} else loopVars.set(v.vId, isAssign ? 1 : 0);
			}
			function collectVars(u:Usage):Void switch u {
				case Block(f):
					var old = vars.mark();
					f(collectVars);
					vars.rollback(old);
				case Loop(f):
					var old = vars.mark();
					var oldLoopVars = loopVars.mark();
					var oldLoop = inLoop;
					inLoop = true;
					f(collectVars);
					inLoop = oldLoop;
					loopVars.rollback(oldLoopVars);
					vars.rollback(old);
				case Function(f):
					++depth;
					f(collectVars);
					--depth;
				case Declare(v) if (!forCoro && TypeOps.hasVarFlag(v, VCoroCaptured)):
				case Declare(v):
					vars.set(v.vId, depth);
				case Use(v):
					if (vars.exists(v.vId) && vars.get(v.vId) != depth) {
						checkLoopVar(v, false);
						used.set(v.vId, v);
					}
				case Assign(v):
					if (vars.exists(v.vId)) {
						if (vars.get(v.vId) != depth) {
							used.set(v.vId, v);
							markAssigned(v);
						} else if (used.exists(v.vId)) markAssigned(v);
						else checkLoopVar(v, true);
					}
			}
			LocalUsage.localUsage(collectVars, e);
			for (id in ids(used)) {
				var v = used.get(id);
				TypeOps.addVarFlag(v, VCaptured);
				if (forCoro) TypeOps.addVarFlag(v, VCoroCaptured);
			}
			return assigned;
		}
		var captured = allVars(e);
		return switch scom.platformConfig.pfCapturePolicy {
			case CPNone: e;
			case CPWrapRef: doWrap(captured, e);
			case CPLoopVars: outLoop(e);
		};
	}
}
