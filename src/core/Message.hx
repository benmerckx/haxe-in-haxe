package core;

import core.Globals.Pos;
import core.Json.JsonValue;

// Port of haxe/src/core/message.ml.

enum MessageSeverity {
	Error;
	Warning;
	Information;
	Hint;
}

enum MessageKind {
	DKUnusedImport;
	DKUnresolvedIdentifier;
	DKCompilerMessage;
	DKReplacableCode;
	DKParserError;
	DKDeprecationWarning;
	DKInactiveBlock;
	DKMissingFields;
}

enum WarningMode {
	WMEnable;
	WMDisable;
}

enum abstract WarningCode(String) from String to String {
	var WAll = "WAll";
	var WInternal = "WInternal";
	var WTemp = "WTemp";
	var WInfo = "WInfo";
	var WUser = "WUser";
	var WCompiler = "WCompiler";
	var WParser = "WParser";
	var WTyper = "WTyper";
	var WMacro = "WMacro";
	var WOptimizer = "WOptimizer";
	var WGenerator = "WGenerator";
	var WNullSafety = "WNullSafety";
	var WDeprecated = "WDeprecated";
	var WDeprecatedDefine = "WDeprecatedDefine";
	var WDeprecatedEnumAbstract = "WDeprecatedEnumAbstract";
	var WVarInit = "WVarInit";
	var WVarShadow = "WVarShadow";
	var WExternWithExpr = "WExternWithExpr";
	var WStaticInitOrder = "WStaticInitOrder";
	var WClosureCompare = "WClosureCompare";
	var WReservedTypePath = "WReservedTypePath";
	var WInlineOptimizedField = "WInlineOptimizedField";
	var WPatternMatcher = "WPatternMatcher";
	var WUnusedPattern = "WUnusedPattern";
	var WConstructorInliningCancelled = "WConstructorInliningCancelled";
	var WUnsafeEnumEquality = "WUnsafeEnumEquality";
	var WIfDisplay = "WIfDisplay";
	var WRedundantNullCheck = "WRedundantNullCheck";
	var WHxb = "WHxb";
	var WIgnoredBadModule = "WIgnoredBadModule";
	var WUnboundTypeParameter = "WUnboundTypeParameter";
	var WUnclosedMonomorph = "WUnclosedMonomorph";
	var WPointlessCode = "WPointlessCode";
}

@:structInit class WarningOption {
	public var woWarning:WarningCode;
	public var woMode:WarningMode;

	public inline function new(woWarning:WarningCode, woMode:WarningMode) {
		this.woWarning = woWarning;
		this.woMode = woMode;
	}

	public inline function clone():WarningOption return new WarningOption(woWarning, woMode);
}

enum CompilerMessageKind {
	MKError;
	MKWarning(warning:WarningCode, options:Array<Array<WarningOption>>);
	MKInfo;
}

@:structInit class CompilerMessage {
	public var cmMessage:String;
	public var cmPos:Pos;
	public var cmDepth:Int;
	public var cmFromMacro:Bool;
	public var cmMessageKind:CompilerMessageKind;
	public var cmDiagnosticsKind:MessageKind;
	public var cmJson:JsonValue;

	public inline function new(cmMessage:String, cmPos:Pos, cmDepth:Int, cmFromMacro:Bool, cmMessageKind:CompilerMessageKind,
			cmDiagnosticsKind:MessageKind, cmJson:JsonValue) {
		this.cmMessage = cmMessage;
		this.cmPos = cmPos;
		this.cmDepth = cmDepth;
		this.cmFromMacro = cmFromMacro;
		this.cmMessageKind = cmMessageKind;
		this.cmDiagnosticsKind = cmDiagnosticsKind;
		this.cmJson = cmJson;
	}

	public inline function clone():CompilerMessage return new CompilerMessage(cmMessage, cmPos, cmDepth, cmFromMacro, cmMessageKind,
		cmDiagnosticsKind, cmJson);
}

class Message {
	public static function severityToInt(severity:MessageSeverity):Int {
		return switch (severity) {
			case Error: 1;
			case Warning: 2;
			case Information: 3;
			case Hint: 4;
		};
	}

	public static function diagnosticsKindToInt(kind:MessageKind):Int {
		return switch (kind) {
			case DKUnusedImport: 0;
			case DKUnresolvedIdentifier: 1;
			case DKCompilerMessage: 2;
			case DKReplacableCode: 3;
			case DKParserError: 4;
			case DKDeprecationWarning: 5;
			case DKInactiveBlock: 6;
			case DKMissingFields: 7;
		};
	}

	public static function messageKindSeverity(kind:CompilerMessageKind):MessageSeverity {
		return switch (kind) {
			case MKError: Error;
			case MKWarning(_, _): Warning;
			case MKInfo: Information;
		};
	}

	public static inline function severity(message:CompilerMessage):MessageSeverity {
		return messageKindSeverity(message.cmMessageKind);
	}

	public static function code(message:CompilerMessage):Null<String> {
		return switch (message.cmMessageKind) {
			case MKWarning(warning, _): WarningList.warningObj(warning).wName;
			case _: null;
		};
	}

	public static function make(fromMacro:Bool, diagnosticsKind:MessageKind, json:JsonValue, message:String, pos:Pos, depth:Int,
			messageKind:CompilerMessageKind):CompilerMessage {
		return {
			cmMessage: message,
			cmPos: pos,
			cmDepth: depth,
			cmFromMacro: fromMacro,
			cmMessageKind: messageKind,
			cmDiagnosticsKind: diagnosticsKind,
			cmJson: json
		};
	}

	public static function makeMessage(fromMacro:Bool, message:String, pos:Pos, depth:Int,
			messageKind:CompilerMessageKind):CompilerMessage {
		return make(fromMacro, DKCompilerMessage, JString(message), message, pos, depth, messageKind);
	}

	public static function makeDiagnostic(fromMacro:Bool, diagnosticsKind:MessageKind, json:JsonValue, pos:Pos, depth:Int,
			messageKind:CompilerMessageKind):CompilerMessage {
		return make(fromMacro, diagnosticsKind, json, "", pos, depth, messageKind);
	}
}
