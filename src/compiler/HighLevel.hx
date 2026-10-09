package compiler;

import context.Common;
import compiler.ParsedArg;
import compiler.Args.PartArgs;
import compiler.Args.RequestArgs;
import compiler.CompilationCache.Cache;
import compiler.server.ServerCompilationContext;
import core.ds.ArgumentError;
import core.ds.NotFound;

// Port of haxe/src/compiler/highLevel.ml.
class HighLevel {
	public static function addLibs(timerCtx:core.Timer.TimerContext, libsCwd:{libs:Array<String>, cwd:String}, args:Array<String>,
			cs:Cache, hasDisplay:Bool):Array<String> {
		var libs = libsCwd.libs, cwd = libsCwd.cwd;
		var globalRepo = args.indexOf("--haxelib-global") >= 0;
		function fail(msg:String):Dynamic {
			throw new ArgumentError(msg);
		}
		function callHaxelib():Array<String> {
			var args = (if (globalRepo) ["--global"] else ["--cwd", cwd]).concat(["path"]).concat(libs);
			var proc = try new sys.io.Process("haxelib", args) catch (e:Dynamic) throw new UnixError(Std.string(e), "haxelib");
			// Unix.open_process_args_full: stdout and stderr are read to the end
			var errBytes:haxe.io.Bytes = null;
			var errDone = new sys.thread.Lock();
			sys.thread.Thread.create(function() {
				errBytes = try proc.stderr.readAll() catch (_:Dynamic) haxe.io.Bytes.alloc(0);
				errDone.release();
			});
			var outBytes = try proc.stdout.readAll() catch (_:Dynamic) haxe.io.Bytes.alloc(0);
			errDone.wait();
			var ret = proc.exitCode();
			proc.close();
			var lines = inputList(outBytes.toString());
			var err = inputList(errBytes.toString());
			if (ret != 0) fail(switch [lines, err] {
				case [[], []]: "Failed to call haxelib (command not found ?)";
				case [[], [s]] if (StringTools.endsWith(StringTools.trim(s),
					"Module not found: path")): "The haxelib command has been strip'ed, please install it again";
				case _: lines.concat(err).join("\n");
			});
			return lines;
		}
		function callHaxelibTimed():Array<String> {
			return core.Timer.time(timerCtx, ["haxelib"], function(_) return callHaxelib(), null);
		}
		switch libs {
			case []:
				return [];
			case _:
				var key:CompilationCache.HaxelibKey = {libs: libs, cwd: if (globalRepo) null else cwd};
				var lines = try {
					/* if we are compiling, really call haxelib since library path might have changed */
					if (!hasDisplay) throw NotFound.raise();
					cs.findHaxelib(key);
				} catch (_:NotFound) {
					try {
						var lines = callHaxelibTimed();
						cs.cacheHaxelib(key, lines);
						lines;
					} catch (e:UnixError) {
						fail(e.message + " (" + e.arg + ")");
					}
				}
				var acc:Array<String> = [];
				// List.fold_left over the reversed lines, consing onto acc
				var rev = lines.copy();
				rev.reverse();
				for (l in rev) {
					var l = StringTools.trim(l);
					if (l == "") continue;
					else if (l.charAt(0) != "-") {
						acc.unshift(l);
						acc.unshift("-libcp");
					} else {
						var space = l.indexOf(" ");
						var param = space < 0 ? l : l.substr(0, space),
							value = space < 0 ? "" : l.substr(space + 1);
						if (space >= 0 && param == "-L") {
							acc.unshift(l.substr(3));
							acc.unshift("--neko-lib-path");
						} else {
							if (value != "") acc.unshift(value);
							acc.unshift(param);
						}
					}
				}
				return acc;
		}
	}

	// Std.input_list: the lines of a channel, without their terminators
	static function inputList(s:String):Array<String> {
		if (s == "") return [];
		var lines = s.split("\n");
		if (lines[lines.length - 1] == "") lines.pop();
		return lines.map(l -> StringTools.endsWith(l, "\r") ? l.substr(0, l.length - 1) : l);
	}

	public static function createContextFromPart(sctx:ServerCompilationContext, requestScope:RequestScope, hasDisplay:Bool, hasNext:Bool,
			part:PartArgs):CommonContext {
		sctx.compilationStep = sctx.compilationStep + 1;
		var com = Compiler.createContext(sctx, requestScope, part.runtimeArgs, hasNext);
		/* Expand Expand markers by calling haxelib, caching the result in the marker state */
		function expandPartLibs(hasGlobal:Bool, partArgs:Array<ParsedArg>):Array<ParsedArg> {
			function expandOne(arg:ParsedArg):Array<ParsedArg> {
				return switch arg {
					case Expand(ex):
						switch ex.state {
							case AlreadyExpanded(expanded):
								expanded;
							case NotYetExpanded(AddLibs(libs, cwd)):
								var rawLines = addLibs(requestScope.timerCtx, {libs: libs, cwd: cwd},
									if (hasGlobal) ["--haxelib-global"] else [], sctx.cs, hasDisplay);
								var expanded = Args.parseArgs(rawLines);
								ex.state = AlreadyExpanded(expanded);
								expanded;
						}
					case arg: [arg];
				}
			}
			var out = [];
			for (arg in partArgs) out = out.concat(expandOne(arg));
			return out;
		}
		var hasGlobal = part.args.indexOf(HaxelibGlobal) >= 0;
		var expandedArgs = expandPartLibs(hasGlobal, part.args);
		com.parsedArgs = expandedArgs;
		return com;
	}

	public static function entry(sctx:ServerCompilationContext, requestScope:RequestScope, requestArgs:RequestArgs):Int {
		var curdir = Sys.getCwd();
		var hasDisplay = requestArgs.displayArg != null;
		function loop(parts:Array<PartArgs>, i:Int):Int {
			if (i >= parts.length) return 0;
			var part = parts[i];
			var hasRest = i + 1 < parts.length;
			var com = createContextFromPart(sctx, requestScope, hasDisplay, hasRest, part);
			var code = Compiler.compileCtx(sctx, com);
			core.Path.restoreCwd(curdir);
			return if (code == 0 && hasRest && !hasDisplay) loop(parts, i + 1) else code;
		}
		var code = loop(requestArgs.parts, 0);
		core.Path.restoreCwd(curdir);
		return code;
	}
}

/** `Unix.Unix_error` raised while starting haxelib. **/
private class UnixError extends haxe.Exception {
	public final arg:String;

	public function new(message:String, arg:String) {
		super(message);
		this.arg = arg;
	}
}
