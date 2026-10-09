package filters.safe;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Texpr;
import core.Error;
import context.SafeCom;
import haxe.ds.IntMap;

// haxe/src/filters/safe/checkVarInit.ml — mechanical draft; not compiled or validated.
// OCaml persistent maps become copied IntMaps at branch snapshots.
class CheckVarInit {
	public static function checkLocalVarsInit(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		inline function intersect(vl1:IntMap<Bool>, vl2:IntMap<Bool>):IntMap<Bool> {
			var result = new IntMap<Bool>();
			for (v => t in vl1) {
				if (!vl2.exists(v)) throw "Not_found";
				result.set(v, t && vl2.get(v));
			}
			return result;
		}
		var declared:Array<Int> = [];
		var outsideVars = new IntMap<Bool>();
		var vars = new IntMap<Bool>();
		inline function setAllVars():Void {
			for (id => isSet in vars) if (!outsideVars.exists(id)) vars.set(id, true);
		}
		inline function join(cvars:Array<IntMap<Bool>>):Void {
			for (v in cvars) vars = intersect(vars, v);
		}
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TLocal(v):
					var init = vars.exists(v.vId) ? vars.get(v.vId) : true;
					if (!init) {
						if (outsideVars.exists(v.vId)) {
							SafeCom.addWarning(scom, WVarInit,
								v.vName == "this" ? "this might be used before assigning a value to it" : "Local variable " + v.vName +
									" might be used before being initialized",
								e.epos);
						} else Error.raiseTypingError(v.vName == "this" ? "Missing this = value" : "Local variable "
							+ v.vName
							+ " used without being initialized",
							e.epos);
					}
				case TVar(v, eo):
					if (eo != null) loop(eo);
					else switch v.vKind {
						case VInlinedConstructorVariable(_):
						case _:
							declared.unshift(v.vId);
							vars.set(v.vId, false);
					}
				case TBlock(el):
					var old = declared;
					var oldVars = vars.copy();
					declared = [];
					for (e in el) loop(e);
					declared.reverse();
					for (v in declared) if (oldVars.exists(v)) vars.set(v, oldVars.get(v));
					else vars.remove(v);
					declared = old;
				case TBinop(OpAssign, {eexpr: TLocal(v)}, rhs) if (vars.exists(v.vId)):
					switch Texpr.skip(rhs).eexpr {
						case TFunction(_):
							vars.set(v.vId, true);
							loop(rhs);
						case _:
							loop(rhs);
							vars.set(v.vId, true);
					}
				case TIf(e1, e2, eo):
					loop(e1);
					var vbase = vars.copy();
					loop(e2);
					if (eo == null) vars = vbase;
					else switch eo.eexpr {
						case TConst(TBool(false)):
						case _:
							var v1 = vars;
							vars = vbase;
							loop(eo);
							vars = intersect(vars, v1);
					}
				case TWhile(cond, body, flag):
					var ordinary = switch cond.eexpr {
						case TParenthesis({eexpr: TConst(TBool(true))}): false;
						case _: true;
					};
					if (flag == NormalWhile && ordinary) {
						loop(cond);
						var old = vars.copy();
						loop(body);
						vars = old;
					} else {
						loop(body);
						loop(cond);
					}
				case TTry(body, catches):
					var cvars = [];
					for (c in catches) {
						var old = vars.copy();
						loop(c.expr);
						cvars.push(vars);
						vars = old;
					}
					loop(body);
					join(cvars);
				case TSwitch(sw):
					loop(sw.switchSubject);
					var cvars = [];
					for (c in sw.switchCases) {
						var old = vars.copy();
						for (ec in c.casePatterns) loop(ec);
						vars = old.copy();
						loop(c.caseExpr);
						cvars.push(vars);
						vars = old;
					}
					if (sw.switchDefault == null) {
						if (sw.switchExhaustive && cvars.length > 0) {
							var cv = cvars.shift();
							for (i => b in cv) if (b) vars.set(i, b);
							join(cvars);
						}
					} else {
						loop(sw.switchDefault);
						join(cvars);
					}
				case TBreak | TContinue | TReturn(null):
					setAllVars();
				case TThrow(value) | TReturn(value):
					loop(value);
					setAllVars();
				case TFunction(tf):
					var old = outsideVars.copy();
					for (i in vars.keys()) outsideVars.set(i, true);
					loop(tf.tfExpr);
					outsideVars = old;
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(e);
		return e;
	}
}
