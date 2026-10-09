package compiler.io;

import core.Json;
import core.Message;
import core.Timer;
import context.Common;
import compiler.Helper;
import compiler.io.CompilerIo.CompilerIoData;
import compiler.MessageReporting;

// haxe/src/compiler/io/compilerOutput.ml — mechanical draft; not compile-validated.
// Server result handlers remain protocol callbacks; no server transport is implemented.
class CompilerOutput {
	public static function extractErrorMessage(je:JsonValue):String return switch je {
		case JObject(fields):
			var value:Null<JsonValue> = null;
			for (field in fields) if (field.name == "message") {
				value = field.value;
				break;
			}
			if (value == null) Json.stringOfJson(je); else switch value {
				case JString(s): s;
				case _: Json.stringOfJson(value);
			}
		case _: Json.stringOfJson(je);
	};

	public static function sendTimerReport(io:CompilerIoData, timerCtx:core.Timer.TimerContext):Void {
		var buf = new StringBuf();
		Timer.reportTimes(timerCtx, function(s) buf.add(s + "\n"));
		try CompilerIo.writeErr(io, buf.toString())
		catch (_:Dynamic) {}
	}

	public static function createServerResultHandler(io:CompilerIoData):ResultHandler {
		function sendMessage(sev:core.Message.MessageSeverity, output:String):Void switch sev {
			// Non-errors go through write_out (the \x01-prefixed prints channel); see compilerOutput.ml.
			case Error:
				CompilerIo.writeErr(io, output + "\n");
				compiler.server.ServerMessage.message(output);
			case Warning | Information | Hint:
				CompilerIo.writeOut(io, output + "\n");
		};
		return {
			sendResult: function(_) {},
			sendResultRaise: function(_):Dynamic throw new core.ds.Failure("send_result_raise called in non-JSON-RPC mode"),
			sendError: function(errors) {
				for (je in errors) CompilerIo.writeErr(io, extractErrorMessage(je) + "\n");
			},
			sendErrorRaise: function(_):Dynamic throw new core.ds.Failure("send_error_raise called in non-JSON-RPC mode"),
			flushMessages: function(hasError, com) {
				var messages = com.partScope.messages.copy();
				messages.reverse();
				MessageReporting.displayMessagesFrom(com.defines, messages, function() {
					hasError = true;
					com.partScope.hasError = true;
				}, sendMessage);
				com.sctx.wasCompilation = com.display.dmsFullTyping;
				if (hasError) {
					com.timerCtx.measureTimes = No;
					CompilerIo.signalError(io);
				} else if (com.timerCtx.measureTimes == Yes) sendTimerReport(io, com.timerCtx);
			},
			setCom: function(_) return NoCompletionPointFound
		};
	}

	public static function createCliResultHandler(io:CompilerIoData):ResultHandler {
		function sendMessage(sev:core.Message.MessageSeverity, output:String):Void switch sev {
			case Information:
				CompilerIo.writeOut(io, output + "\n");
			case Warning | Error | Hint:
				CompilerIo.writeErr(io, output + "\n");
		};
		return {
			sendResult: function(_) {},
			sendResultRaise: function(_):Dynamic throw "send_result_raise called in non-JSON-RPC mode",
			sendError: function(errors) {
				for (je in errors) CompilerIo.writeErr(io, extractErrorMessage(je) + "\n");
			},
			sendErrorRaise: function(_):Dynamic throw "send_error_raise called in non-JSON-RPC mode",
			flushMessages: function(hasError, com) {
				var messages = com.partScope.messages.copy();
				messages.reverse();
				MessageReporting.displayMessagesFrom(com.defines, messages, function() {
					hasError = true;
					com.partScope.hasError = true;
				}, sendMessage);
				if (hasError && Helper.prompt) {
					CompilerIo.writeOut(io, "Press enter to exit...\n");
					Sys.stdin().readLine();
				}
				CompilerIo.flush(io);
			},
			setCom: function(_) return NoCompletionPointFound
		};
	}

	public static function sendResult(rh:ResultHandler, json:JsonValue):Void rh.sendResult(json);

	public static function sendResultRaise(rh:ResultHandler, json:JsonValue):Dynamic return rh.sendResultRaise(json);

	public static function sendError(rh:ResultHandler, errors:Array<JsonValue>):Void rh.sendError(errors);

	public static function sendErrorRaise(rh:ResultHandler, errors:Array<JsonValue>):Dynamic return rh.sendErrorRaise(errors);

	public static function flushMessages(rh:ResultHandler, hasError:Bool, com:CommonContext):Void rh.flushMessages(hasError, com);
}
