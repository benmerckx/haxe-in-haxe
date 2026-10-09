package filters.exception;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.ds.AtomicLazy;
import core.Error;
import typing.Typeload;
import context.SafeCom;
import context.Typecore;
import filters.exception.Exceptions;
import filters.exception.ExceptionFunctions;

// haxe/src/filters/exception/exceptionInit.ml — mechanical draft; not compiled or validated.
class ExceptionInit {
	public static function createExceptionContext(tctx:Typer):Null<ExceptionContext> {
		switch tctx.com.platform {
			case Cross | CustomTarget(_):
				return null;
			case Php | Js | Jvm | Python | Lua | Eval | Neko | Flash | Hl | Cpp:
		}
		var config = tctx.com.config.pfExceptions;
		function tp(path:GlobalTypePath):PlacedTypePath {
			var pack = path.pack;
			var name = path.name;
			var tp = if (pack.length > 0
				&& !Ast.isLowerIdent(pack[pack.length - 1])) Ast.mkTypePath(pack.slice(0, pack.length - 1), pack[pack.length - 1], null,
					name); else Ast.mkTypePath(path.pack, path.name);
			return Ast.makePtp(tp, Globals.nullPos);
		}
		inline function load(path:GlobalTypePath):T return Typeload.loadInstance(tctx, tp(path), ParamSpawnMonos, LoadNormal);
		var wildcardCatchType = load(config.ecWildcardCatch);
		if (ExceptionFunctions.isDynamic(wildcardCatchType)) wildcardCatchType = TypeOps.tDynamic;
		var baseThrowType = load(config.ecBaseThrow);
		if (ExceptionFunctions.isDynamic(baseThrowType)) baseThrowType = TypeOps.tDynamic;
		inline function lazyClass(path:GlobalTypePath, error:String):AtomicLazy<{type:T, cls:TClass}> {
			return AtomicLazy.fromFun(function() {
				var t = load(path);
				return switch t {
					case TInst(cls, _): {type: t, cls: cls};
					case _: Error.raiseTypingError(error, Globals.nullPos);
				};
			});
		}
		var haxeException = lazyClass(ExceptionFunctions.haxeExceptionTypePath, "haxe.Exception is expected to be a class");
		var valueException = lazyClass(ExceptionFunctions.valueExceptionTypePath, "haxe.ValueException is expected to be a class");
		var nativeStack = AtomicLazy.fromFun(function() {
			return switch load({pack: ["haxe"], name: "NativeStackTrace"}) {
				case TInst(cls, _): cls;
				case TAbstract({aImpl: cls}, _) if (cls != null): cls;
				case _: Error.raiseTypingError("haxe.NativeStackTrace is expected to be a class or an abstract", Globals.nullPos);
			};
		});
		inline function isPathOfDynamic(path:GlobalTypePath):Bool return path.name == "Dynamic"
			&& (path.pack.length == 0 || path.pack.length == 1 && path.pack[0] == "StdTypes");
		var stdCls:TClass = tctx.com.std;
		if (!stdCls.clStatics.exists("isOfType")) Error.raiseTypingError("Std has no field isOfType", Globals.nullPos);
		var isOfTypeField = stdCls.clStatics.get("isOfType");
		var returnType = switch TypeOps.follow(isOfTypeField.cfType) {
			case TFun(sig): sig.ret;
			case _: Error.raiseTypingError("Std.isOfType is not a function and cannot be called", Globals.nullPos);
		};
		return {
			scom: SafeCom.ofTyper(tctx),
			basic: tctx.t,
			config: config,
			wildcardCatchType: wildcardCatchType,
			baseThrowType: baseThrowType,
			throwsAnything: isPathOfDynamic(config.ecBaseThrow) && config.ecAvoidWrapping,
			catchesAnything: isPathOfDynamic(config.ecWildcardCatch) && config.ecAvoidWrapping,
			haxeException: haxeException,
			haxeNativeStackTrace: nativeStack,
			valueException: valueException,
			isOfType: {
				cls: stdCls,
				field: isOfTypeField,
				returnType: returnType
			}
		};
	}
}
