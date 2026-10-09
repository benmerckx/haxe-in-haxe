package filters;

import core.TType;
import core.TFunctions as TypeOps;
import core.Meta;
import core.Timer;

// haxe/src/filters/filterContext.ml — mechanical draft; not compiled or validated.
class FilterContext {
	public static function withTimer<T>(timerCtx:core.Timer.TimerContext, level:Int, label:String, identifier:Null<String>, f:Void->T):T {
		// Timer.time only calls f when times are not measured; skip building the id and wrapper.
		if (timerCtx.measureTimes == core.Timer.MeasureTimes.No) return f();
		var id = Timer.determineId(level, ["filters"], [label], identifier);
		return Timer.time(timerCtx, id, function(_:Null<Bool>) return f(), null);
	}

	public static function isRemovableClass(c:TClass):Bool {
		return switch c.clKind {
			case KGeneric: Meta.has(core.MetaList.StrictMeta.Remove,
					c.clMeta) || (c.clSuper != null && isRemovableClass(c.clSuper.cls)) || core.ds.ArrayTools.exists(c.clParams,
					tp -> TypeOps.hasCtorConstraint(tp.ttpClass) || Meta.has(core.MetaList.StrictMeta.Const, tp.ttpClass.clMeta));
			case KTypeParameter(_): true; // Upstream: investigate why this happens (#4092).
			case _: false;
		};
	}

	public static function isRemovableField(isMacroContext:Bool, f:TClassField):Bool {
		return !TypeOps.hasClassFieldFlag(f, CfOverride)
			&& (TypeOps.hasClassFieldFlag(f, CfExtern) || TypeOps.hasClassFieldFlag(f, CfGeneric) || switch f.cfKind {
				case Var({vRead: AccRequire(_, _)}): true;
				case Method(MethMacro): !isMacroContext;
				case _: false;
			});
	}
}
