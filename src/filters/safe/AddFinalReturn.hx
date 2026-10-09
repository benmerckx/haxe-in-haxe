package filters.safe;

import core.TType;
import core.TFunctions as TypeOps;

// haxe/src/filters/safe/addFinalReturn.ml — mechanical draft; not compiled or validated.
class AddFinalReturn {
	public static function addFinalReturn(e:TExpr):TExpr {
		function loop(e:TExpr, t:T):TExpr {
			inline function defReturn(p:core.Globals.Pos):TExpr {
				var c:TConstant = switch TypeOps.follow(t) {
					case TAbstract({aPath: {pack: [], name: "Int"}}, _): TInt(0);
					case TAbstract({aPath: {pack: [], name: "Float"}}, _): TFloat("0.");
					case TAbstract({aPath: {pack: [], name: "Bool"}}, _): TBool(false);
					case _: TNull;
				};
				return {eexpr: TReturn({eexpr: TConst(c), epos: p, etype: t}), etype: TypeOps.tDynamic, epos: p};
			}
			return switch e.eexpr {
				case TBlock(el) if (el.length == 0): e;
				case TBlock(el):
					var rest = el.slice(0, el.length - 1);
					var last = loop(el[el.length - 1], t);
					switch last.eexpr {
						case TBlock(el2): rest = rest.concat(el2);
						case _: rest.push(last);
					}
					{eexpr: TBlock(rest), etype: e.etype, epos: e.epos};
				case TReturn(_): e;
				case _: {eexpr: TBlock([e, defReturn(e.epos)]), etype: e.etype, epos: e.epos};
			};
		}
		e = core.Texpr.mapExpr(addFinalReturn, e);
		return switch e.eexpr {
			case TFunction(f):
				var body = switch TypeOps.follow(f.tfType) {
					case TAbstract({aPath: {pack: [], name: "Void"}}, []): f.tfExpr;
					case _: loop(f.tfExpr, f.tfType);
				};
				{eexpr: TFunction({tfArgs: f.tfArgs, tfType: f.tfType, tfExpr: body}), etype: e.etype, epos: e.epos};
			case _: e;
		};
	}
}
