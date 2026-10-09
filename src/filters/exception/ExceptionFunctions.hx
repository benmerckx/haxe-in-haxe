package filters.exception;

import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Texpr;
import core.Abstract;
import context.SafeCom;
import optimization.Inline;

// haxe/src/filters/exception/exceptionFunctions.ml — mechanical draft; not compiled or validated.
class ExceptionFunctions {
	public static final haxeExceptionTypePath:GlobalTypePath = {pack: ["haxe"], name: "Exception"};
	public static final valueExceptionTypePath:GlobalTypePath = {pack: ["haxe"], name: "ValueException"};

	public static function isHaxeExceptionClass(cls:TClass, checkParent:Bool = true):Bool {
		return cls.clPath.name == "Exception"
			&& cls.clPath.pack.length == 1
			&& cls.clPath.pack[0] == "haxe"
			|| checkParent
			&& cls.clSuper != null
			&& isHaxeExceptionClass(cls.clSuper.cls, checkParent);
	}

	public static function isHaxeException(t:T, checkParent:Bool = true):Bool {
		return switch Abstract.followWithAbstracts(t) {
			case TInst(cls, _): isHaxeExceptionClass(cls, checkParent);
			case _: false;
		};
	}

	public static function isDynamic(t:T):Bool {
		return switch Abstract.followWithAbstracts(t) {
			case TAbstract({aPath: {pack: [], name: "Dynamic"}}, _): true;
			case t: t == TypeOps.tDynamic;
		};
	}

	public static function makeCall(scom:context.SafeCom.SafeContext, eon:TExpr, el:Array<TExpr>, tret:T, p:Pos):TExpr {
		return switch eon.eexpr {
			case TField(ef, FStatic(cl, cf) | FInstance(cl, _, cf)) if (SafeCom.needsInline(scom, cl, cf)):
				switch cf.cfExpr {
					case {eexpr: TFunction(tf)}:
						var config = Inline.inlineConfig(cl, cf, el, tret);
						Inline.typeInline(Inline.contextOfScom(scom), cf, tf, ef, el, tret, config, p, false);
					case _: TypeOps.mk(TCall(eon, el), tret, p);
				}
			case _: TypeOps.mk(TCall(eon, el), tret, p);
		};
	}

	public static function makeStaticCall(scom:context.SafeCom.SafeContext, c:TClass, cf:TClassField, el:Array<TExpr>, tret:T,
			p:Pos):TExpr {
		return makeCall(scom, Texpr.Builder.makeStaticField(c, cf, p), el, tret, p);
	}
}
