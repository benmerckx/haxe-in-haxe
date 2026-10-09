package compiler;

import core.Globals;
import core.Globals.*;
import core.TType;
import core.Ast;
import core.Path;
import core.Timer;
import core.Define;
import core.ds.Failure;
import core.ds.NotFound;
import context.Common;
import context.Parallel;
import compiler.hxb.HxbWriter;
import compiler.hxb.HxbData;
import compiler.hxb.HxbWriterConfig;

// haxe/src/compiler/generate.ml; deferred backend dispatch retained in deferred/compiler/GenerateTargets.hx.
class MissingHxbModule extends haxe.Exception {
	public function new() super("Missing_hxb_module");
}

class Generate {
	public static function checkAuxiliaryOutput(com:CommonContext, actx:compiler.Args.ArgContext):Void {
		if (actx.xmlOut != null || actx.jsonOut != null) throw new Failure("XML and JSON auxiliary output are outside the HXB milestone");
	}

	public static function createWriter(com:CommonContext, config:WriterTargetConfig):{writer:HxbWriter, close:Void->haxe.io.Bytes} {
		if (config.hxbVersion != HxbData.VERSION) throw new Failure("Unsupported HXB version: " + config.hxbVersion);
		var anonIdentification = new typing.TanonIdentification<Dynamic>();
		function warn(w:core.Message.WarningCode, s:String, p:Pos):Void com.warning(w, com.warningOptions, s, p);
		var writer = new HxbWriter(config.generateDocumentation, warn, anonIdentification);
		return {writer: writer, close: writer.exportModule};
	}

	public static function exportHxb(fromCache:Bool, com:CommonContext, config:WriterTargetConfig,
			cc:compiler.CompilationCache.ContextCache, platform:String, m:ModuleDef):Null<{
			path:String,
			bytes:haxe.io.Bytes
		}> {
		return switch m.mExtra.mKind {
			case MCode | MMacro | MFake | MExtern:
				var path = [platform].concat(m.mPath.pack).concat([m.mPath.name]).join("/") + ".hxb";
				if (fromCache) {
					var cache = try cc.getHxbModule(m.mPath) catch (e:Dynamic) {
						if (!Std.isOfType(e, NotFound)) throw e;
						throw new MissingHxbModule();
					};
					var out = new haxe.io.BytesOutput();
					HxbData.writeHeader(out);
					for (chunk in cache.mcChunks) {
						HxbData.writeChunkPrefix(chunk.kind, chunk.data.length, out);
						out.write(chunk.data);
					}
					{path: path, bytes: out.getBytes()};
				} else {
					var writer = createWriter(com, config);
					writer.writer.writeModule(m);
					{path: path, bytes: writer.close()};
				}
			case _: null;
		};
		}

	public static function checkHxbOutput(com:CommonContext, config:HxbWriterConfig):Void {
		inline function matchPathList(list:Array<Array<String>>,
				path:Array<String>):Bool return core.ds.ArrayTools.exists(list, function(part) return Ast.matchPath(true, path, part));
		function tryWrite(fromCache:Bool):Void {
			var path = StringTools.replace(config.archivePath, "$target", Globals.platformName(com.platform));
			var stop = Timer.startTimer(com.timerCtx, ["generate", "hxb"]);
			Path.mkdirFromPath(path);
			var zip;
			try zip = new core.ZipOutput(path, 0)
			catch (e:Dynamic) {
				throw new HxbOutputError(Std.string(e));
			}
			inline function export(com:CommonContext, config:WriterTargetConfig):Void {
				var cc = context.CommonCache.getCache(com);
				var target = Common.platformNameMacro(com);
				function emit(m:ModuleDef):Null<{path:String, bytes:haxe.io.Bytes}> {
					var path = m.mPath.pack.concat([m.mPath.name]);
					return !matchPathList(config.exclude, path)
						|| matchPathList(config.include,
							path) ? Timer.time(com.timerCtx, ["generate", "hxb", sTypePath(m.mPath)],
							function(_) return exportHxb(fromCache, com, config, cc, target, m), null) : null;
				}
				var input = com.modules.copy();
				var output = Parallel.runWithPool(com.sctx.pool, function(pool) return ParallelArray.map(pool, emit, input, null));
				for (entry in output) if (entry != null) zip.addBytesEntry(entry.bytes, entry.path);
			}
			var failed:Dynamic = null;
			var didFail = false;
			try {
				if (config.targetConfig.generate) export(com, config.targetConfig);
				if (config.macroConfig.generate) {
					var macroCom = com.getMacros();
					if (macroCom != null) export(macroCom, config.macroConfig);
				}
			} catch (e:Dynamic) {
				failed = e;
				didFail = true;
			}
			zip.close();
			stop();
			if (didFail) throw failed;
		}
		try {
			// This case shouldn't happen, unless some modules are not stored in hxb cache (which should not be the case currently)
			if (com.sctx.isServer) try tryWrite(true)
			catch (_:MissingHxbModule) tryWrite(false);
			else tryWrite(false);
		} catch (e:HxbOutputError) com.error("Could not write to " + config.archivePath + ": " + e.message, nullPos);
	}

	public static function deleteFile(file:String):Void {
		try sys.FileSystem.deleteFile(file)
		catch (_:Dynamic) {}
	}

	public static function maybeGenerateDumpDependencies(ctx:CommonContext, tctx:context.Typecore.Typer):Void {
		var com:CommonContext = tctx.com;
		if (com.partScope.dumpConfig.dumpDependencies) {
			codegen.Dump.dumpDependencies(com);
			if (!com.isMacroContext && tctx.g.macros != null) codegen.Dump.dumpDependencies(tctx.g.macros.typer.com, "macro");
		}
	}

	// HXB output is emitted by the after-save callback before backend destruction.
	// Interpretation (--interp, --run, the Eval target) runs on the port's Eval; the other
	// code generators are not ported and fail explicitly.
	public static function generate(com:CommonContext, tctx:context.Typecore.Typer, ext:String, actx:compiler.Args.ArgContext):Void {
		if (Path.fileExtension(com.file) == ext) deleteFile(com.file);
		if (com.platform == Flash || com.platform == Cpp || com.platform == Hl) for (t in com.types) codegen.FixOverrides.fixOverrides(com,
			t);
		switch com.platform {
			case Neko | Hl | Eval if (actx.interp):
			case Cpp if (Common.defined(com, Define.Cppia)):
			case Cpp | Php:
				Path.mkdirFromPath(com.file + "/.");
			case _:
				Path.mkdirFromPath(com.file);
		}
		if (actx.interp) {
			var timer = Timer.startTimer(com.timerCtx, ["interp"]);
			try typing.MacroContext.interpret(tctx, com.partScope.runtimeArgs)
			catch (e:Dynamic) {
				timer();
				throw e;
			}
			timer();
		} else {
			var name = switch com.platform {
				case Eval: "eval";
				case Cross | CustomTarget(_): "";
				case p: throw new Failure("Code generation for "
						+ Globals.platformName(p)
						+ " is not supported by haxe-in-haxe (HXB and --interp only)");
			};
			if (name != "") {
				Common.log(com, "Generating " + name + ": " + com.file);
				Timer.time(com.timerCtx, ["generate", name], function(_:Null<Bool>) {
					typing.MacroContext.interpret(tctx, []);
					return null;
				}, null);
			}
		}
	}
}

private class HxbOutputError extends haxe.Exception {}
