package codegen;

import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.TUnification;
import core.TOther.*;
import context.Common;

// haxe/src/codegen/fixOverrides.ml — mechanical shared-filter draft; not compile-validated.
class FixOverrides {
	public static function findField(com:CommonContext, c:TClass, f:TClassField):TClassField {
		try {
			var s = c.clSuper;
			if (s == null || (s.cls.clPath.pack.join(".") == "cpp" && s.cls.clPath.name == "FastIterator")) throw "Not_found";
			return findField(com, s.cls, f);
		} catch (e:Dynamic) {
			if (e != "Not_found") throw e;
		}
		try {
			if (com.platform == Cpp || com.platform == Hl) throw "Not_found";
			// HashLink 2.0 JIT: an early exit through two nested try blocks restores only the innermost trap, leaving a dangling handler.
			for (parent in c.clImplements) {
				var r = try findField(com, parent.cls, f) catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					null;
				}
				if (r != null) return r;
			}
			throw "Not_found";
		} catch (e:Dynamic) {
			if (e != "Not_found") throw e;
		}
		var field = c.clFields.get(f.cfName);
		if (field == null) throw "Not_found";
		switch field.cfKind {
			case Var({vRead: AccRequire(_, _)}):
				throw "Not_found";
			case _:
		}
		return field;
	}

	public static function fixOverride(com:CommonContext, c:TClass, f:TClassField, fd:Null<TFunc>):Void {
		var f2 = try findField(com, c, f) catch (e:Dynamic) {
			if (e != "Not_found") throw e;
			null;
		};
		if (f2 != null && fd != null) {
			var signature = switch followWithCoro(f2.cfType) {
				case Coro(s): Common.expandCoroType(com.basic, s.args, s.ret);
				case NotCoro(TFun(s)): s;
				case _: throw "Invalid override type";
			};
			var changed:Array<{original:TVar, replacement:TVar}> = [];
			if (fd.tfArgs.length != signature.args.length) throw "Invalid_argument: List.map2";
			var nargs = [];
			for (i in 0...fd.tfArgs.length) {
				var cur = fd.tfArgs[i],
					v = cur.variable,
					t2 = signature.args[i].type;
				var next = cur;
				try {
					typeEq(EqStrict, monomorphs(c.clParams, monomorphs(f.cfParams, v.vType)), t2);
					switch follow(v.vType) {
						case TInst(cp = {clKind: KTypeParameter(ttp)}, _) if (com.platform == Flash):
							if (getConstraints(ttp).length == 1
								&& core.ds.ArrayTools.exists(c.clParams,
									function(tp) return tp.ttpName == cp.clPath.name)) throw new Unify_error([]);
						case _:
					}
				} catch (_:Unify_error) {
					var v2 = allocVar(VGenerated, "_tmp_" + v.vName, t2, v.vPos);
					changed.unshift({original: v, replacement: v2});
					next = {variable: v2, defaultValue: cur.defaultValue};
				}
				nargs.push(next);
			}
			changed.reverse();
			var expr = fd.tfExpr;
			if (changed.length > 0) {
				var el = switch expr.eexpr {
					case TBlock(el): el;
					case _: [expr];
				};
				var p = el.length == 0 ? expr.epos : el[0].epos;
				var decls = changed.map(function(pair) return mk(TVar(pair.original,
					mk(TCast(mk(TLocal(pair.replacement), pair.replacement.vType, p), null), pair.original.vType, p)),
					com.basic.tvoid, p));
				expr = {eexpr: TBlock(decls.concat(el)), etype: expr.etype, epos: expr.epos};
			}
			var fd2 = ({tfArgs: nargs, tfType: signature.ret, tfExpr: expr} : core.TType.TFunc);
			var args = nargs.map(function(arg) return {
				name: arg.variable.vName,
				optional: arg.defaultValue != null,
				type: arg.variable.vType
			});
			var fde = f.cfExpr;
			if (fde == null) throw "Missing override expression";
			f.cfExpr = {eexpr: TFunction(fd2), etype: fde.etype, epos: fde.epos};
			f.cfType = TFun({args: args, ret: signature.ret});
		} else if (f2 != null && fd == null && hasClassFlag(c, CInterface)) {
			var s = switch followWithCoro(f2.cfType) {
				case Coro(s): Common.expandCoroType(com.basic, s.args, s.ret);
				case NotCoro(TFun(s)): s;
				case _: throw "Invalid override type";
			};
			f.cfType = TFun(s);
		}
	}

	public static function fixOverrides(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c):
			if (hasClassFlag(c, CInterface)) c.clOrderedFields = c.clOrderedFields.filter(function(f) {
				try {
					if (findField(com, c, f) == f) throw "Not_found";
					c.clFields.remove(f.cfName);
					return false;
				} catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					return true;
				}
			});
			for (f in c.clOrderedFields) switch [f.cfExpr, f.cfKind] {
				case [{eexpr: TFunction(fd)}, Method(MethNormal | MethInline)]: fixOverride(com, c, f, fd);
				case [null, Method(MethNormal | MethInline)] if (hasClassFlag(c, CInterface)): fixOverride(com, c, f, null);
				case _:
			}
		case _:
	};

	public static function fixAbstractInheritance(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c) if (hasClassFlag(c, CInterface)):
			c.clOrderedFields = c.clOrderedFields.filter(function(f) {
				var b = try findField(com, c, f) == f catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					false;
				};
				if (!b) c.clFields.remove(f.cfName);
				return b;
			});
		case _:
	};
}
