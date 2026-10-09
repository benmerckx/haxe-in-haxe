package optimization;

import core.Ast;
import core.TType;
import core.Meta;
import core.Define;
import core.Timer;
import core.StringError;
import context.SafeCom;
import core.Globals;
import core.Message;

enum DebugKind {
	DebugNone;
	DebugDot;
	DebugFull;
}

@:structInit class AnalyzerConfigData {
	public var optimize:Bool;
	public var constPropagation:Bool;
	public var copyPropagation:Bool;
	public var localDce:Bool;
	public var fusion:Bool;
	public var purityInference:Bool;
	public var debugKind:DebugKind;
	public var detailTimes:Int;
	public var userVarFusion:Bool;
	public var fusionDebug:Bool;

	public inline function new(optimize:Bool, constPropagation:Bool, copyPropagation:Bool, localDce:Bool, fusion:Bool,
			purityInference:Bool, debugKind:DebugKind, detailTimes:Int, userVarFusion:Bool, fusionDebug:Bool) {
		this.optimize = optimize;
		this.constPropagation = constPropagation;
		this.copyPropagation = copyPropagation;
		this.localDce = localDce;
		this.fusion = fusion;
		this.purityInference = purityInference;
		this.debugKind = debugKind;
		this.detailTimes = detailTimes;
		this.userVarFusion = userVarFusion;
		this.fusionDebug = fusionDebug;
	}

	public inline function clone():AnalyzerConfigData return new AnalyzerConfigData(optimize, constPropagation, copyPropagation, localDce,
		fusion, purityInference, debugKind, detailTimes, userVarFusion, fusionDebug);
}

// haxe/src/optimization/analyzerConfig.ml — mechanical draft; not compiled or validated.
class AnalyzerConfig {
	public static final flagOptimize = "optimize";
	public static final flagConstPropagation = "const_propagation";
	public static final flagCopyPropagation = "copy_propagation";
	public static final flagLocalDce = "local_dce";
	public static final flagFusion = "fusion";
	public static final flagIgnore = "ignore";
	public static final flagDotDebug = "dot_debug";
	public static final flagFullDebug = "full_debug";
	public static final flagUserVarFusion = "user_var_fusion";
	public static final flagFusionDebug = "fusion_debug";
	public static final allFlags = makeAllFlags();

	static function makeAllFlags():Array<String> {
		var result = [];
		for (flag in [
			flagOptimize,
			flagConstPropagation,
			flagCopyPropagation,
			flagLocalDce,
			flagFusion,
			flagIgnore,
			flagDotDebug,
			flagUserVarFusion
		])
			result = [flag, "no_" + flag].concat(result);
		return result;
	}

	public static function hasAnalyzerOption(meta:Metadata,
			s:String):Bool return Ast.hasMetaOption(meta, core.MetaList.StrictMeta.Analyzer, s);

	public static function isIgnored(meta:Metadata):Bool return hasAnalyzerOption(meta, flagIgnore);

	public static function getBaseConfig(com:SafeContext):AnalyzerConfigData {
		var fusionAllowed = switch com.platform {
			case Flash | Jvm: false;
			case _: true;
		};
		return {
			optimize: Define.defined(com.defines, Define.AnalyzerOptimize),
			constPropagation: !Define.rawDefined(com.defines, "analyzer_no_const_propagation"),
			copyPropagation: !Define.rawDefined(com.defines, "analyzer_no_copy_propagation"),
			localDce: !Define.rawDefined(com.defines, "analyzer_no_local_dce"),
			fusion: !Define.rawDefined(com.defines, "analyzer_no_fusion"),
			purityInference: !Define.rawDefined(com.defines, "analyzer_no_purity_inference"),
			debugKind: DebugNone,
			detailTimes: Timer.levelFromDefine(com.defines, Define.AnalyzerTimes),
			userVarFusion: fusionAllowed
			&& (Define.rawDefined(com.defines, "analyzer_user_var_fusion")
				|| !com.debug
				&& !Define.rawDefined(com.defines, "analyzer_no_user_var_fusion")),
			fusionDebug: false
		};
	}

	public static function updateConfigFromMeta(com:SafeContext, config:AnalyzerConfigData, ml:Metadata):AnalyzerConfigData {
		config = core.ds.Record.copy(config);
		for (meta in ml) switch meta {
			case {meta: core.MetaList.StrictMeta.Analyzer, exprs: el}:
				for (e in el) switch e.expr {
					case EConst(Ident(s)):
						switch s {
							case "optimize": config.optimize = true;
							case "no_optimize": config.optimize = false;
							case "const_propagation": config.constPropagation = true;
							case "no_const_propagation": config.constPropagation = false;
							case "copy_propagation": config.copyPropagation = true;
							case "no_copy_propagation": config.copyPropagation = false;
							case "local_dce": config.localDce = true;
							case "no_local_dce": config.localDce = false;
							case "fusion": config.fusion = true;
							case "no_fusion": config.fusion = false;
							case "user_var_fusion": config.userVarFusion = true;
							case "no_user_var_fusion": config.userVarFusion = false;
							case "dot_debug": config.debugKind = DebugDot;
							case "full_debug": config.debugKind = DebugFull;
							case "fusion_debug": config.fusionDebug = true;
							case "as_var":
							case _: SafeCom.addWarning(com, WOptimizer,
									StringError.stringError(s, allFlags, "Unrecognized analyzer option: " + s), e.pos);
						}
					case _:
						var s = core.AstPrinter.sExpr(e);
						SafeCom.addWarning(com, WOptimizer, StringError.stringError(s, allFlags, "Unrecognized analyzer option: " + s),
							e.pos);
				}
			case {meta: core.MetaList.StrictMeta.HasUntyped}:
				config.optimize = false;
			case _:
		}
		return config;
	}

	public static function getClassConfig(com:SafeContext,
			c:TClass):AnalyzerConfigData return updateConfigFromMeta(com, getBaseConfig(com), c.clMeta);

	public static function getFieldConfig(com:SafeContext, c:TClass,
			cf:TClassField):AnalyzerConfigData return updateConfigFromMeta(com, getClassConfig(com, c), cf.cfMeta);
}
