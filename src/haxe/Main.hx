package haxe;

import compiler.Args;
import compiler.HighLevel;
import compiler.ParsedArg;
import compiler.io.CompilerIo;
import compiler.io.CompilerOutput;
import compiler.server.Server;
import compiler.server.ServerCompilationContext;
import context.Common;
import context.Parallel.ManagedPool;

// Port of haxe/src/compiler/haxe.ml.
class Main {
	static function main():Void {
		#if js
		// Like OCaml, only record backtraces with OCAMLRUNPARAM=b: the compiler
		// throws exceptions for ordinary control flow (see runtime/hl for HashLink).
		var ocamlrunparam = Sys.getEnv("OCAMLRUNPARAM");
		if (ocamlrunparam == null || ocamlrunparam.indexOf("b") < 0) js.Syntax.code("Error.stackTraceLimit = 0");
		#end
		core.ds.GcPolicy.init();
		Sys.exit(run(Sys.args()));
	}

	// Upstream assigns these forward references during OCaml module
	// initialization. Static initialization order differs between Haxe
	// targets, so they are (re)assigned once all statics are initialized.
	public static function initHooks():Void {
		core.Type.initialize();
		core.TUnification.initHooks();
		context.AbstractCast.install(); // the JVM initializes classes lazily
		typing.Typer.initialize();
		typing.TyperEntry.initHooks();
		typing.TypeloadFunction.initHooks();
		typing.Generic.initHooks();
		optimization.Analyzer.initHooks();
	}

	static function badArg(msg:String):Int {
		Sys.stderr().writeString(msg + "\n");
		return 1;
	}

	static function isDigits(s:String):Bool {
		return ~/^[0-9]+$/.match(s);
	}

	static function parseV4(s:String):Null<String> {
		var parts = s.split(".");
		if (parts.length != 4) return null;
		for (part in parts) if (!isDigits(part) || part.length > 3 || Std.parseInt(part) > 255) return null;
		return parts.map(p -> Std.string(Std.parseInt(p))).join(".");
	}

	// Ipaddr.V6.of_string: eight groups of up to four hex digits, at most one `::`
	// standing for one or more zero groups; the last two groups may be an IPv4 address.
	static function isV6(s:String):Bool {
		if (s.indexOf(":") < 0 || !~/^[0-9a-fA-F:.]+$/.match(s)) return false;
		var halves = s.split("::");
		if (halves.length > 2) return false;
		function groups(part:String, last:Bool):Null<Int> {
			if (part == "") return 0;
			var gs = part.split(":"), n = 0;
			for (i in 0...gs.length) {
				var g = gs[i];
				if (last && i == gs.length - 1 && g.indexOf(".") >= 0) {
					if (parseV4(g) == null) return null;
					n += 2;
				} else if (~/^[0-9a-fA-F]{1,4}$/.match(g)) n++;
				else return null;
			}
			return n;
		}
		if (halves.length == 1) return groups(s, true) == 8;
		var a = groups(halves[0], false), b = groups(halves[1], true);
		return a != null && b != null && a + b <= 7;
	}

	/**
		`Ipaddr.with_port_of_string ~default:(-1)`: an IPv4 or IPv6 address with an
		optional port (`a.b.c.d:port`, `[v6]:port`). Returns null for `Error _`.
		IPv6 addresses are kept as written (`V6.to_string` normalization is not
		reproduced; the host socket API cannot use them).
	**/
	static function ipWithPortOfString(hp:String):Null<{ip:IpAddr, port:Int}> {
		function port(s:String):Null<Int> return isDigits(s) ? Std.parseInt(s) : null;
		var v4 = parseV4(hp);
		if (v4 != null) return {ip: V4(v4), port: -1};
		var colon = hp.lastIndexOf(":");
		if (colon >= 0) {
			var v4 = parseV4(hp.substr(0, colon)),
				p = port(hp.substr(colon + 1));
			if (v4 != null && p != null) return {ip: V4(v4), port: p};
		}
		if (StringTools.startsWith(hp, "[")) {
			var close = hp.indexOf("]");
			if (close > 0 && isV6(hp.substring(1, close))) {
				if (close == hp.length - 1) return {ip: V6(hp.substring(1, close)), port: -1};
				if (hp.charAt(close + 1) == ":") {
					var p = port(hp.substr(close + 2));
					if (p != null) return {ip: V6(hp.substring(1, close)), port: p};
				}
			}
			return null;
		}
		if (isV6(hp)) return {ip: V6(hp), port: -1};
		return null;
	}

	static function parseHostPort(hp:String):{ip:IpAddr, port:Int} {
		return switch ipWithPortOfString(hp) {
			/* Short ipv6 notation will be mixed up with port; extract port and rebuild ipv6 */
			case {ip: V6(ip), port: -1}:
				var octets = ip.split(":");
				octets.reverse();
				switch octets {
					case [] | [_]: throw new BadArg("Invalid host/port");
					case _:
						var port = octets.shift();
						octets.reverse();
						var rest = octets.join(":");
						if (!isV6(rest) || !isDigits(port)) throw new BadArg("Invalid host/port");
						{ip: V6(rest), port: Std.parseInt(port)};
				}
			case {ip: _, port: -1}:
				throw new BadArg("Invalid host/port: missing port");
			case r if (r != null):
				r;
			/* Default to 127.0.0.1 with given port if no host is provided */
			case _ if (isDigits(hp)):
				{ip: V4("127.0.0.1"), port: Std.parseInt(hp)};
			case _:
				throw new BadArg("Invalid host/port");
		}
	}

	public static function run(args:Array<String>):Int {
		initHooks();
		// The port is executed by a host compiler, so the std location of the
		// executable is not meaningful; HAXE_IN_HAXE_STD_PATH overrides the
		// HAXE_STD_PATH the host may have rewritten for --run.
		var std = Sys.getEnv("HAXE_IN_HAXE_STD_PATH");
		if (std != null && std != "" && Sys.getEnv("HAXE_STD_PATH") != std) Sys.putEnv("HAXE_STD_PATH", std);
		else if (Sys.getEnv("HAXE_STD_PATH") == null && sys.FileSystem.exists("haxe/std")) Sys.putEnv("HAXE_STD_PATH",
			sys.FileSystem.fullPath("haxe/std"));
		try {
			return runMain(args);
		} catch (e:BadArg) {
			return badArg(e.message);
		} catch (e:core.ds.Failure) {
			// An uncaught OCaml exception
			Sys.stderr().writeString("Fatal error: exception Failure(\"" + e.message + "\")\n");
			return 2;
		}
	}

	static function runMain(args:Array<String>):Int {
		var parsedArgs = Args.parseArgs(args);
		var requestArgs = try Args.expandArgs(parsedArgs) catch (e:core.ds.ArgumentError) return badArg(e.message);

		/* Are we a client? */

		switch requestArgs.connectArg {
			case null:
			case hp:
				var hp = parseHostPort(hp);
				/* Pass the entire args again, the server can take that apart. */
				var code = Server.doConnect(hp.ip, hp.port, parsedArgs);
				return code;
		}

		function isVerbose() {
			return switch requestArgs.parts {
				case []: false;
				case parts: parts[0].args.indexOf(SetVerbose) >= 0;
			}
		}

		/* Are we a server? */

		switch requestArgs.serverMode {
			case SMListen(hp):
				var accept = {
					var hp = parseHostPort(hp);
					Server.initWaitSocket(hp.ip, hp.port);
				}
				var code = Server.waitLoop(isVerbose(), accept);
				return code;
			case SMConnect(hp):
				var hp = parseHostPort(hp);
				var accept = Server.initWaitConnect(hp.ip, hp.port);
				var code = Server.waitLoop(isVerbose(), accept);
				return code;
			case SMNone:
		}

		/* We are a normal non-server compilation. */

		var sctx = Server.setupServerContext(false, false);
		var io = CompilerIo.createStdioIo();
		var requestScope = try Server.createRequestScope(false, io, requestArgs.displayArg) catch (e:core.ds.ArgumentError) {
			ServerCompilationContext.dispose(sctx);
			return badArg(e.message);
		} catch (e:core.ds.Exit) {
			// handle_jsonrpc_error raised Exit after sending the error: an uncaught OCaml exception
			ServerCompilationContext.dispose(sctx);
			io.flush();
			Sys.stderr().writeString("Fatal error: exception Stdlib.Exit\n");
			return 2;
		}
		var code = try HighLevel.entry(sctx, requestScope, requestArgs) catch (e:core.ds.ArgumentError) {
			ServerCompilationContext.dispose(sctx);
			return badArg(e.message);
		} catch (e:Dynamic) {
			ServerCompilationContext.dispose(sctx);
			reportInternalError(e);
			return 1;
		}
		if (code == 0) {
			var timerCtx = requestScope.timerCtx;
			if (timerCtx.measureTimes == core.Timer.MeasureTimes.Yes)
				CompilerOutput.sendTimerReport(io, timerCtx);
		}
		ServerCompilationContext.dispose(sctx);
		return code;
	}

	// Upstream reports an uncaught OCaml exception with its backtrace.
	static function reportInternalError(e:Dynamic):Void {
		var stack = Std.isOfType(e, haxe.Exception) ? (cast(e, haxe.Exception)).stack : haxe.CallStack.exceptionStack();
		Sys.stderr().writeString(haxe.CallStack.toString(stack) + "\n" + Std.string(e) + "\n");
		switch core.ds.ExceptionTools.unification(e) {
			case Some(errors):
				for (error in errors) Sys.stderr().writeString(core.Error.unifyErrorMsg(core.TPrinting.printContext(), error) + "\n");
			case None:
		}
	}
}

/** `bad_arg`: prints the message and exits with code 1. **/
private class BadArg extends haxe.Exception {}
