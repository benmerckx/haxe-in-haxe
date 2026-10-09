package context;

import core.Define;
import core.Define.DefineContext;

// Draft mechanical translation of haxe/src/context/dumpConfig.ml; unvalidated.
enum DumpMode {
	NoDump;
	Ast;
	Pretty;
	Record;
	Position;
}

enum DumpStage {
	AfterTyping;
	AfterCasting;
	AfterInlining;
	AfterAnalyzing;
	AfterSanitizing;
	AfterDce;
}

@:structInit class DumpConfiguration {
	public var dumpMode:DumpMode;
	public var dumpPath:String;
	public var dumpStage:DumpStage;
	public var dumpPrintIds:Bool;
	public var dumpDependencies:Bool;

	public inline function new(dumpMode:DumpMode, dumpPath:String, dumpStage:DumpStage, dumpPrintIds:Bool, dumpDependencies:Bool) {
		this.dumpMode = dumpMode;
		this.dumpPath = dumpPath;
		this.dumpStage = dumpStage;
		this.dumpPrintIds = dumpPrintIds;
		this.dumpDependencies = dumpDependencies;
	}

	public inline function clone():DumpConfiguration return new DumpConfiguration(dumpMode, dumpPath, dumpStage, dumpPrintIds,
		dumpDependencies);
}

class DumpConfig {
	public static function createDefault():DumpConfiguration return {
		dumpMode: NoDump,
		dumpPath: "dump",
		dumpStage: AfterDce,
		dumpPrintIds: false,
		dumpDependencies: false
	};

	public static function updateFromDefines(conf:DumpConfiguration, def:DefineContext):Void {
		conf.dumpMode = switch Define.definedValueSafe(def, Define.Dump) {
			case "1": Ast;
			case "pretty": Pretty;
			case "record": Record;
			case "position": Position;
			case _: NoDump;
		};
		conf.dumpPath = Define.definedValueSafe(def, Define.DumpPath, "dump");
		conf.dumpStage = switch Define.definedValueSafe(def, Define.DumpStage) {
			case "typing": AfterTyping;
			case "casting": AfterCasting;
			case "inlining": AfterInlining;
			case "analyzing": AfterAnalyzing;
			case "sanitizing": AfterSanitizing;
			case "dce": AfterDce;
			case _: AfterDce;
		};
		conf.dumpPrintIds = !Define.defined(def, Define.DumpIgnoreVarIds);
		conf.dumpDependencies = Define.defined(def, Define.DumpDependencies);
	}

	public static function stringOfDumpStage(stage:DumpStage):String return switch stage {
		case AfterTyping: "AfterTyping";
		case AfterCasting: "AfterCasting";
		case AfterInlining: "AfterInlining";
		case AfterAnalyzing: "AfterAnalyzing";
		case AfterSanitizing: "AfterSanitizing";
		case AfterDce: "AfterDce";
	};
}
