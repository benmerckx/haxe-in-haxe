package compiler.io;

import core.TType;
import core.Message;
import core.Error;
import core.Warning;
import core.WarningList;
import context.Common;
import core.Globals.Pos;

// haxe/src/compiler/io/compilerMessage.ml — mechanical draft; not compile-validated.
class Abort extends haxe.Exception {
	public function new() super("Abort");
}

class CompilerMessage {
	public static function addMessage(com:CommonContext, msg:String, p:Pos, depth:Int, kind:core.Message.CompilerMessageKind):Void {
		var cm = Message.makeMessage(com.isMacroContext, msg, p, depth, kind);
		if (com.partScope.messageCapture != null) com.partScope.messageCapture.value.unshift(cm);
		else {
			if (Message.messageKindSeverity(kind) == Error) com.partScope.hasError = true;
			com.partScope.messages.unshift(cm);
		}
	}

	public static function addModuleMessage(com:CommonContext, m:ModuleDef, msg:String, p:Pos, depth:Int,
			kind:core.Message.CompilerMessageKind):Void {
		if (Message.messageKindSeverity(kind) == Error) com.partScope.hasError = true;
		var cm = Message.makeMessage(com.isMacroContext, msg, p, depth, kind);
		if (com.display.dmsFullTyping) m.mExtra.mCacheBoundObjects.push(Message(cm));
		com.partScope.messages.unshift(cm);
	}

	public static function addModuleDiagnostic(com:CommonContext, m:ModuleDef, cm:core.Message.CompilerMessage):Void {
		if (com.display.dmsFullTyping) m.mExtra.mCacheBoundObjects.push(Message(cm));
		if (Common.isDiagnostics(com)) com.partScope.messages.unshift(cm);
	}

	public static function replayMessage(com:CommonContext, cm:core.Message.CompilerMessage):Void {
		switch cm.cmMessageKind {
			case MKWarning(w, options):
				com.warning(w, options, cm.cmMessage, cm.cmPos, cm.cmDepth);
			case _:
				var diagnosticsOnly = switch cm.cmDiagnosticsKind {
					case DKMissingFields | DKUnresolvedIdentifier: true;
					case _: false;
				};
				if (!diagnosticsOnly || Common.isDiagnostics(com)) com.partScope.messages.unshift(cm);
		}
	}

	public static function defaultErrorHandler(com:CommonContext):core.Error.CompilerError->Void return function(err) {
		Error.recurseError(function(depth, err) addMessage(com, Error.errorMsg(err.errMessage), err.errPos, depth, MKError), err);
		if (com.partScope.messageCapture == null) {
			com.partScope.hasError = true;
			if (Common.failFast(com)) throw new Abort();
		}
	};

	public static function defaultWarningHandler(com:CommonContext):(w:core.Message.WarningCode,
		options:Array<Array<core.Message.WarningOption>>, msg:String, p:Pos,
		?depth:Int) -> Void return function(w:core.Message.WarningCode, options:Array<Array<core.Message.WarningOption>>, msg:String,
				p:Pos, ?depth:Int) {
			if (depth == null) depth = 0;
			switch Warning.getMode(w, options.concat(com.warningOptions)) {
				case WMEnable:
					var obj = WarningList.warningObj(w);
					if (!obj.wGeneric) msg = "(" + obj.wName + ") " + msg;
					addMessage(com, msg, p, depth, MKWarning(w, options));
				case WMDisable:
			}
		};

	public static function defaultInfoHandler(com:CommonContext):(msg:String, p:Pos,
		?depth:Int) -> Void return function(msg:String, p:Pos, ?depth:Int) addMessage(com, msg, p, depth == null ? 0 : depth, MKInfo);
}
