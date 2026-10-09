package filters;

import core.TType;
import core.TFunctions as TypeOps;
import context.Common;
import context.SafeCom;
import core.Define;

// haxe/src/filters/filtersCommon.ml — mechanical draft; not compiled or validated.
class FiltersCommon {
	public static function removeGenericBase(t:ModuleType):Void {
		switch t {
			case TClassDecl(c) if (FilterContext.isRemovableClass(c)):
				TypeOps.addClassFlag(c, CExtern);
			case _:
		}
	}

	public static function isOverridden(cls:TClass, field:TClassField):Bool {
		function loopInheritance(c:TClass):Bool {
			return c.clFields.exists(field.cfName) || core.ds.ArrayTools.exists(c.clDescendants, loopInheritance);
		}
		return core.ds.ArrayTools.exists(cls.clDescendants, loopInheritance);
	}

	public static function isCached(com:CommonContext, t:ModuleType):Bool {
		var m = TypeOps.tModule(t).mExtra;
		return m.mProcessed != 0 && m.mProcessed < com.partScope.compilationStep;
	}

	public static function applyFiltersOnce(ctx:context.Typecore.Typer, scom:SafeContext,
			filters:Array<{name:String, run:SafeContext->TExpr->TExpr}>, t:ModuleType):Void {
		var detailTimes = try core.ds.OcamlInt.ofString(Common.definedValueSafe(ctx.com, Define.FilterTimes, "0")) catch (_:Dynamic) 0;
		if (!isCached(ctx.com, t)) SafeCom.runExpressionFiltersSafe(scom, detailTimes, filters, t);
	}
}
