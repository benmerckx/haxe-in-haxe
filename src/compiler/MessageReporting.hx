package compiler;

import core.Globals;
import core.Globals.Pos;
import core.Message;
import core.Define;
import core.Error;
import core.ds.Failure;
import core.ds.NotFound;
import core.Message.CompilerMessage as MessageData;
import core.TPrinting;
import syntax.Lexer;
import context.Common;

// haxe/src/compiler/messageReporting.ml — mechanical draft; not compile-validated.
typedef ErrorContext = {
	var absolutePositions:Bool;
	var sourceLines:Map<String, Array<String>>;
	var lastPositions:Map<Int, Pos>;
	var maxLines:Map<Int, Int>;
	var gutter:Map<Int, Int>;
	var previous:Null<{pos:Pos, severity:MessageSeverity, depth:Int}>;
}

class ConfigError extends haxe.Exception {
	public function new(message:String) super(message);
}

class MessageReporting {
	static function samePos(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	static function repeat(s:String, n:Int):String {
		if (n < 0) throw "Invalid_argument: String.make";
		return [for (_ in 0...n) s].join("");
	}

	public static function readSourceLines(file:String):Array<String> {
		var ch;
		try ch = sys.io.File.read(file, true)
		catch (e:Dynamic) {
			throw new SourceIoError(Std.string(e));
		}
		var lines = [], buf = new StringBuf();
		inline function flushLine():Void {
			lines.push(buf.toString());
			buf = new StringBuf();
		}
		inline function read():Int {
			try return ch.readByte()
			catch (e:haxe.io.Eof) {
				flushLine();
				throw e;
			}
		}
		try {
			while (true) switch read() {
				case 10:
					flushLine();
				case 13:
					read();
					flushLine();
				case c:
					buf.addChar(c);
			}
		} catch (_:haxe.io.Eof) {}
		ch.close();
		return lines;
	}

	public static function errorPrinter(file:String, line:Int):String return file + ":" + line + ":";

	public static function createErrorContext(absolute:Bool):ErrorContext return {
		absolutePositions: absolute,
		sourceLines: new Map(),
		lastPositions: new Map(),
		maxLines: new Map(),
		gutter: new Map(),
		previous: null
	};

	public static function resolveSource(ctx:ErrorContext, file:String, l1:Int, p1:Int, l2:Int, p2:Int):Array<{line:Int, text:String}> {
		if (l1 == l2 && p1 == p2 && l1 == 1 && p1 == 1) return [];
		var lines = ctx.sourceLines.get(file);
		if (lines == null) {
			lines = readSourceLines(file);
			ctx.sourceLines.set(file, lines);
		}
		var result = [];
		var i = Std.int(Math.min(l2, lines.length));
		while (i >= l1) {
			if (i - 1 < 0 || i - 1 >= lines.length) throw "Invalid_argument: index out of bounds";
			result.unshift({line: i, text: lines[i - 1]});
			i--;
		}
		return result;
	}

	public static function compilerPrettyMessageString(defines:DefineContext, ctx:ErrorContext, cm:MessageData):Null<String> {
		if (cm.cmMessage == "End of overload failure reasons") return null;
		ctx.lastPositions.set(cm.cmDepth, cm.cmPos);
		var isNull = samePos(cm.cmPos, Globals.nullPos) || cm.cmPos.pmin == -1;
		function unknown(file:String):Bool return file == "" || file == "?";
		var l1:Int, p1:Int, l2:Int, p2:Int, epos:String, lines:Array<{line:Int, text:String}>;
		if (isNull) {
			l1 = -1;
			p1 = -1;
			l2 = -1;
			p2 = -1;
			epos = unknown(cm.cmPos.pfile) ? "(unknown position)" : cm.cmPos.pfile;
			lines = [];
		} else try {
			var coords = Lexer.getPosCoords(cm.cmPos);
			l1 = coords.lineStart;
			p1 = coords.columnStart;
			l2 = coords.lineEnd;
			p2 = coords.columnEnd;
			lines = resolveSource(ctx, cm.cmPos.pfile, l1, p1, l2, p2);
			epos = lines.length == 0 ? cm.cmPos.pfile : ctx.absolutePositions ? TPrinting.Printer.sPos(cm.cmPos) : Lexer.getErrorPos(errorPrinter,
				cm.cmPos);
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, NotFound) && !Std.isOfType(e, SourceIoError)) throw e;
			l1 = 1;
			p1 = 1;
			l2 = 1;
			p2 = 1;
			epos = cm.cmPos.pfile;
			lines = [];
		}
		if (lines.length > 4) {
			var head = lines[0], indent = 0, found = false;
			while (!found && indent < head.text.length - 1) {
				found = !Lexer.isWhitespace(head.text.charAt(indent));
				indent++;
			}
			lines = [
				head,
				{line: 0, text: repeat(" ", indent + 1) + "[...]"},
				lines[lines.length - 1]
			];
		}
		var parent = cm.cmDepth == 0 ? Globals.nullPos : ctx.lastPositions.get(cm.cmDepth - 1);
		if (parent == null) parent = Globals.nullPos;
		var prev = ctx.previous,
			sev = Message.severity(cm),
			sevChanged = prev == null || sev != prev.severity;
		var posChanged = (prev == null || !samePos(cm.cmPos, prev.pos) || (cm.cmDepth != prev.depth && cm.cmDepth != prev.depth + 1))
			&& (samePos(parent, Globals.nullPos) || !samePos(cm.cmPos, parent));
		var fileChanged = prev == null
			|| (posChanged && !(unknown(cm.cmPos.pfile) && unknown(prev.pos.pfile)) && cm.cmPos.pfile != prev.pos.pfile);
		var heading = cm.cmDepth == 0 || sevChanged || fileChanged,
			source = lines.length > 0 && (cm.cmDepth == 0 || sevChanged || posChanged),
			marker = !isNull && source;
		var gutterLen = (ctx.maxLines.exists(cm.cmDepth) ? Std.string(ctx.maxLines.get(cm.cmDepth)).length : 0) + 2;
		var noColor = !Define.defined(defines, Define.MessageColor), reset = noColor ? "" : "\x1b[0m", bold = noColor ? "" : "\x1b[1m",
			dim = noColor ? "" : "\x1b[2m", color = "", background = "";
		if (!noColor) switch sev {
			case Warning:
				color = "\x1b[33m";
				background = "\x1b[30;43m";
			case Information | Hint:
				color = "\x1b[34m";
				background = "\x1b[30;44m";
			case Error:
				color = "\x1b[31m";
				background = "\x1b[30;41m";
		}
		var label = switch sev {
			case Warning: "WARNING";
			case Information: "INFO";
			case Hint: "HINT";
			case Error: "ERROR";
		};
		label = cm.cmDepth > 0 ? " -> " : noColor ? "[" + label + "]" : " " + label + " ";
		var out = heading ? background + label + reset + " " + (cm.cmFromMacro ? color + "(macro) " + reset : "") + epos + "\n\n" : "";
		inline function safeSub(s:String, pos:Int, len:Int):String {
			if (len < 0) return "";
			if (pos < 0) pos = 0;
			if (pos >= s.length) return "";
			if (pos + len > s.length) len = s.length - pos;
			try return s.substr(pos, len)
			catch (_:haxe.exceptions.ArgumentException) return "[" + s + ";" + pos + ";" + len + "]";
		}
		if (source) for (entry in lines) {
			var l = entry.line,
				gutter = gutterLen - Std.string(l).length - 1,
				line = entry.text.split("\t").join(" "),
				len = line.length;
			var text = if (l == 0) dim + line + reset; else if (l1 == l2) (p1 > 1 ? dim + safeSub(line, 0, p1 - 1) : "") + reset + bold
				+ safeSub(line, p1 - 1,
					p2 - p1) + reset + dim + safeSub(line, p2 - 1,
					len - p2 + 1) + reset; else if (l == l1) dim + safeSub(line, 0, p1 - 1) + reset + bold
				+ safeSub(line, p1 - 1,
					len - p1 + 1) + reset; else if (l == l2) bold + safeSub(line, 0, p2 - 1) + reset + dim
				+ safeSub(line, p2 - 1, len - p2 + 1) + reset; else bold + line + reset;
			out += (gutter < 1 ? "" : repeat(" ", gutter)) + (l == 0 ? "-" : Std.string(l)) + " | " + text + "\n";
		}
		if (marker) out += repeat(" ", gutterLen)
			+ "|"
			+ (l1 == l2 ? repeat(" ", p1) + color + repeat("^", p1 == p2 ? 1 : p2 - p1) + reset : "")
			+ "\n";
		for (str in (cast cm.cmMessage : String).split("\n")) out += repeat(" ", gutterLen)
			+ "| "
			+ (StringTools.startsWith(str, "... ") ? str.substr(4) : str)
			+ "\n";
		ctx.previous = {pos: isNull ? Globals.nullPos : cm.cmPos, severity: sev, depth: cm.cmDepth};
		ctx.gutter.set(cm.cmDepth, gutterLen);
		if (cm.cmDepth > 0) {
			var indent = 0;
			for (d in 0...cm.cmDepth) indent += ctx.gutter.exists(d) ? ctx.gutter.get(d) : 3;
			out = out.split("\n").map(function(s) return s == "" ? "" : repeat(" ", indent) + s).join("\n");
		}
		return out;
	}

	public static function messageString(ctx:ErrorContext, cm:MessageData):Null<String> {
		var str = Message.severity(cm) == Warning ? "Warning : " + cm.cmMessage : cm.cmMessage;
		if (samePos(cm.cmPos, Globals.nullPos)) return str;
		var epos = ctx.absolutePositions ? TPrinting.Printer.sPos(cm.cmPos) : Lexer.getErrorPos(errorPrinter, cm.cmPos),
			lines:Array<String> = str.split("\n");
		for (i in 1...lines.length) lines[i] = Error.complMsg(lines[i]);
		return epos + " : " + lines.join("\n" + epos + " : ");
	}

	public static function compilerIndentedMessageString(ctx:ErrorContext, cm:MessageData):Null<String> {
		if (cm.cmMessage == "End of overload failure reasons") return null;
		var str = switch Message.severity(cm) {
			case Warning: "Warning : " + cm.cmMessage;
			case Information: "Info : " + cm.cmMessage;
			case Error | Hint: cm.cmMessage;
		};
		if (samePos(cm.cmPos, Globals.nullPos)) return str;
		var epos = ctx.absolutePositions ? TPrinting.Printer.sPos(cm.cmPos) : Lexer.getErrorPos(errorPrinter, cm.cmPos),
			lines:Array<String> = str.split("\n"), out = [];
		if (lines.length == 0) throw "Failure: hd";
		for (i in 0...lines.length) {
			var msg = lines[i], depth = cm.cmDepth + (i == 0 ? 0 : 1);
			out.push(repeat(" ", depth * 2) + epos + " : " + (StringTools.startsWith(msg, "... ") ? msg.substr(4) : msg));
		}
		return out.join("\n");
	}

	public static function getMaxLine(maxLines:Map<Int, Int>, messages:Array<MessageData>):Map<Int, Int> {
		var result = new Map();
		for (k in maxLines.keys()) result.set(k, maxLines.get(k));
		for (cm in messages) {
			var l2 = Lexer.getPosCoords(cm.cmPos).lineEnd,
				old = result.exists(cm.cmDepth) ? result.get(cm.cmDepth) : 0;
			if (l2 > old) result.set(cm.cmDepth, l2);
		}
		return result;
	}

	public static function displaySourceAt(defines:DefineContext, p:Pos):Void {
		var ctx = createErrorContext(Define.defined(defines, Define.MessageAbsolutePositions)),
			msg = Message.makeMessage(false, "", p, 0, MKInfo);
		ctx.maxLines = getMaxLine(ctx.maxLines, [msg]);
		var s = compilerPrettyMessageString(defines, ctx, msg);
		if (s != null) Sys.stderr().writeString(s + "\n");
	}

	public static function getFormatter(defines:DefineContext, def:String, defaultMode:String):ErrorContext->MessageData->Null<String> {
		return switch Define.definedValueSafe(defines, def, defaultMode) {
			case "pretty": function(ctx, cm) return compilerPrettyMessageString(defines, ctx, cm);
			case "indent": compilerIndentedMessageString;
			case "classic": messageString;
			case m: throw new ConfigError('Invalid message reporting mode: "' + m + '", expected classic | pretty | indent (for -D '
					+ Define.getDefineKey(def) + ').');
		};
	}

	public static function printError(err:CompilerError):String {
		var out = "";
		Error.recurseError(function(_, err) {
			out += Lexer.getErrorPos(function(file, line) return file + ":" + line + ": ", err.errPos)
				+ Error.errorMsg(err.errMessage)
				+ "\n";
		}, err);
		return out;
	}

	public static function formatMessages(defines:DefineContext, messages:Array<MessageData>):String {
		var ctx = createErrorContext(Define.defined(defines, Define.MessageAbsolutePositions));
		ctx.maxLines = getMaxLine(ctx.maxLines, messages);
		var formatter = getFormatter(defines, Define.MessageReporting, "pretty"), lines = [];
		for (cm in messages) {
			var s = formatter(ctx, cm);
			if (s != null) lines.push(s);
		}
		return lines.join("\n");
	}

	public static function displayMessagesFrom(defines:DefineContext, messages:Array<MessageData>, setError:Void->Void,
			onMessage:core.Message.MessageSeverity->String->Void):Void {
		var ctx = createErrorContext(Define.defined(defines, Define.MessageAbsolutePositions));
		ctx.maxLines = getMaxLine(ctx.maxLines, messages);
		inline function error(msg:String):Void {
			setError();
			onMessage(Error, msg);
		}
		inline function formatter(def:String, defaultMode:String):ErrorContext->MessageData->Null<String> {
			try return getFormatter(defines, def, defaultMode)
			catch (e:ConfigError) {
				error(e.message);
				return messageString;
			}
		}
		var messageFormatter = formatter(Define.MessageReporting, "pretty"),
			logFormatter = formatter(Define.MessageLogFormat, "indent"),
			logMessages = Define.defined(defines, Define.MessageLogFile);
		var logMessage:Null<MessageData->Void> = null,
			closeLogs:Null<Void->Void> = null;
		if (logMessages) try {
			var buf = new StringBuf(),
				file = Define.definedValue(defines, Define.MessageLogFile);
			core.Path.mkdirFromPath(file);
			var channel;
			try channel = sys.io.File.write(file, true)
			catch (e:Dynamic) {
				throw new SourceIoError(Std.string(e));
			}
			logMessage = function(msg) {
				var s = logFormatter(ctx, msg);
				if (s != null) buf.add(s + "\n");
			};
			closeLogs = function() {
				channel.writeString(buf.toString());
				buf = new StringBuf();
				channel.close();
			};
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, Failure) && !Std.isOfType(e, SourceIoError)) throw e;
			error("Error opening log file: "
				+ e.message
				+ ". Logging to file disabled (-D "
				+ Define.getDefineKey(Define.MessageLogFile)
				+ ")");
			logMessages = false;
		}
		for (cm in messages) {
			if (logMessages) logMessage(cm);
			var s = messageFormatter(ctx, cm);
			if (s != null) onMessage(Message.severity(cm), s);
		}
		if (logMessages) closeLogs();
	}

	public static function displayMessages(com:CommonContext, onMessage:core.Message.MessageSeverity->String->Void):Void {
		var messages = com.partScope.messages.copy();
		messages.reverse();
		displayMessagesFrom(com.defines, messages, function() com.partScope.hasError = true, onMessage);
	}
}

private class SourceIoError extends haxe.Exception {}
