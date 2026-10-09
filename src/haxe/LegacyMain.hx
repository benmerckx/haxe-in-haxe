package haxe;

import compiler.Args;
import compiler.ParsedArg;
import compiler.hxb.HxbWriter;
import compiler.hxb.HxbWriterConfig;
import core.ClassPath.ClassPathScope;
import core.ClassPath.DirectoryClassPath;
import core.ClassPaths;
import core.Define;
import core.Globals.GlobalTypePath;
import core.TType.TClass;
import core.TType.TClassField;
import core.TType.ModuleType;
import core.ZipOutput;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import typing.TypeloadModule;

/**
 * Legacy bootstrap entry point (pre-translation loader). The translated
 * compiler entry is haxe.Main.
 *
 * Compiler subsystems will be ported from haxe/src in small, traceable steps.
 */
class LegacyMain {
	static function main():Void {
		run(Sys.args());
	}

	/**
		The deliberately narrow batch entry point currently supported by the
		port: source class paths, raw defines, HXML expansion, source roots and an HXB output.
		Keeping this separate from Args lets the latter remain a faithful CLI
		parser while unsupported compiler phases fail before any compilation work.
	**/
	public static function run(arguments:Array<String>):Void {
		if (arguments.length > 0 && arguments[0] == "--") arguments = arguments.slice(1);
		var classPaths = new ClassPaths();
		var configuredStdPath = Sys.getEnv("HAXE_IN_HAXE_STD_PATH");
		if (configuredStdPath == null || configuredStdPath == "") configuredStdPath = Sys.getEnv("HAXE_STD_PATH");
		var stdPath = configuredStdPath == null
			|| configuredStdPath == "" ? FileSystem.fullPath("haxe/std") + "/" : classPathPath(configuredStdPath);
		if (!FileSystem.exists(stdPath)) throw "Pinned standard library not found at " + stdPath;
		classPaths.push(new DirectoryClassPath(stdPath, Std));
		classPaths.add(new DirectoryClassPath(classPathPath("."), User));
		var defines = Define.emptyDefines();
		// The HXB target is a cross-target compiler artifact. Std.hx uses this
		// target define to permit loading the shared standard library.
		Define.rawDefineValue(defines, "cross", "1");
		var main:Null<GlobalTypePath> = null;
		var roots:Array<GlobalTypePath> = [];
		var hxbArgument:Null<String> = null;
		var parsedArguments = Args.expandHxml(Args.parseArgs(arguments));
		var hasHxbOutput = core.ds.ArrayTools.exists(parsedArguments, function(argument) return switch argument {
			case SetHxbOut(_): true;
			case _: false;
		});
		for (argument in parsedArguments) {
			switch argument {
				case AddClassPath(path):
					classPaths.add(new DirectoryClassPath(classPathPath(path), User));
				case Define(key, value):
					Define.rawDefineValue(defines, key, value == null ? "1" : value);
				case Undefine(key):
					Define.rawUndefine(defines, key);
				case SetDebug:
					Define.rawDefineValue(defines, "debug", "1");
				case SetMain(path):
					if (main != null) unsupported("multiple --main options");
					main = typePath(path, "--main");
					roots.push(main);
				case AddClass(path):
					roots.push(typePath(path, "class root"));
				case IncludeModule(path) if (path.indexOf("*") == -1):
					roots.push(typePath(path.split("."), "module root"));
				case Run(path, runtimeArguments) if (runtimeArguments.length == 0):
					if (main != null) unsupported("multiple --main options");
					main = typePath(path.split("."), "--run");
					roots.push(main);
				case RunX(path) if (hasHxbOutput):
					if (main != null) unsupported("multiple --main options");
					main = typePath(path.split("."), "-x");
					roots.push(main);
				case SetHxbOut(file):
					if (hxbArgument != null) unsupported("multiple --hxb options");
					hxbArgument = file;
				case Interp | SetNoOutput | SetDce(_) | AddWarning(_) | Cwd(_) if (hasHxbOutput):
				case _:
					unsupported(Type.enumConstructor(argument));
			}
		}
		if (roots.length == 0) throw "Batch HXB compilation requires --main or a module root";
		if (hxbArgument == null) throw "Batch HXB compilation requires --hxb";
		var config = HxbWriterConfig.processArgument(hxbArgument);
		if (config.targetConfig.hxbVersion != compiler.hxb.HxbData.VERSION)
			throw 'Unsupported HXB version: ${config.targetConfig.hxbVersion}';
		ensureOutputDirectory(config.archivePath);
		var loader = new TypeloadModule(classPaths, defines);
		loader.loadStdBootstrap();
		var loadedRoots = [for (root in roots) loader.loadModule(root)];
		if (main != null) for (module in loadedRoots) if (module.mPath.pack.join(".") == main.pack.join(".")
			&& module.mPath.name == main.name) markMainKept(module);
		for (module in loader.loadedModules()) markFieldsPostProcessed(module);
		var zip = new ZipOutput(config.archivePath, 0);
		try {
			if (config.targetConfig.generate) for (module in loader.loadedModules()) {
				var path = module.mPath.pack.concat([module.mPath.name]);
				if (shouldExport(path, config.targetConfig)) {
					var writer = new HxbWriter();
					try writer.writeModule(module)
					catch (error:Dynamic) throw 'Could not serialize ${path.join(".")}: $error';
					zip.addBytesEntry(writer.exportModule(), "cross/" + path.join("/") + ".hxb");
				}
			}
		} catch (error:haxe.Exception) {
			zip.close();
			throw error;
		}
		zip.close();
	}

	static function markMainKept(module:core.TType.ModuleDef):Void {
		for (type in module.mTypes) switch type {
			case TClassDecl(cls):
				var field = cls.clStatics.get("main");
				if (field != null && field.cfMeta.length == 0) {
					field.cfMeta.unshift({
						meta: ":keep",
						exprs: [],
						pos: {
							pfile: field.cfPos.pfile,
							pmin: field.cfPos.pmin,
							pmax: field.cfPos.pmin
						}
					});
					field.cfFlags |= 1 << core.TType.TType.flagTClassFieldNames.indexOf("CfPostProcessed");
				}
			case _:
		}
		if (module.mStatics != null) {
			var field = module.mStatics.clStatics.get("main");
			if (field != null && field.cfMeta.length == 0) {
				field.cfMeta.unshift({
					meta: ":keep",
					exprs: [],
					pos: {
						pfile: field.cfPos.pfile,
						pmin: field.cfPos.pmin,
						pmax: field.cfPos.pmin
					}
				});
				field.cfFlags |= 1 << core.TType.TType.flagTClassFieldNames.indexOf("CfPostProcessed");
			}
		}
	}

	static function markFieldsPostProcessed(module:core.TType.ModuleDef):Void {
		var bit = 1 << core.TType.TType.flagTClassFieldNames.indexOf("CfPostProcessed");
		for (type in module.mTypes) switch type {
			case TClassDecl(cls):
				if (cls.clConstructor != null) {
					cls.clConstructor.cfFlags |= bit;
					preserveUnoptimizedExpression(cls, cls.clConstructor);
				}
				if (cls.clInit != null) cls.clInit.cfFlags |= bit;
				for (field in cls.clOrderedFields) {
					field.cfFlags |= bit;
					preserveUnoptimizedExpression(cls, field);
				}
				for (field in cls.clOrderedStatics) {
					field.cfFlags |= bit;
					preserveUnoptimizedExpression(cls, field);
				}
			case _:
		}
		if (module.mStatics != null) for (field in module.mStatics.clOrderedStatics) field.cfFlags |= bit;
	}

	static function preserveUnoptimizedExpression(cls:TClass, field:TClassField):Void {
		var generic = (field.cfFlags & (1 << core.TType.TType.flagTClassFieldNames.indexOf("CfGeneric"))) != 0;
		var needed = switch [field.cfKind, cls.clKind] {
			case [Method(MethInline), _] | [_, KGeneric]: true;
			case _: generic;
		};
		if (needed && field.cfExpr != null && field.cfExprUnoptimized == null) field.cfExprUnoptimized = field.cfExpr;
	}

	static function shouldExport(path:Array<String>, config:compiler.hxb.HxbWriterConfig.WriterTargetConfig):Bool {
		for (pattern in config.include) if (matchesPath(path, pattern)) return true;
		for (pattern in config.exclude) if (matchesPath(path, pattern)) return false;
		return true;
	}

	// Direct port of Ast.match_path true for HXB include/exclude patterns.
	static function matchesPath(path:Array<String>, pattern:Array<String>):Bool {
		function lowerIdentifier(value:String):Bool return value.length > 0 && value.charCodeAt(0) >= "a".code
			&& value.charCodeAt(0) <= "z".code;
		function loop(top:Bool, pathIndex:Int, patternIndex:Int):Bool {
			if (patternIndex == pattern.length) return pathIndex == path.length || !top;
			var part = pattern[patternIndex];
			if (part == "**") return patternIndex + 1 == pattern.length
				|| loop(false, pathIndex, patternIndex + 1)
				|| (pathIndex < path.length && loop(false, pathIndex + 1, patternIndex));
			if (pathIndex == path.length) return false;
			if (patternIndex + 1 == pattern.length && pathIndex + 1 < path.length && lowerIdentifier(part)
				&& !lowerIdentifier(path[pathIndex + 1])) return path[pathIndex] == part;
			return (part == "*" || path[pathIndex] == part) && loop(false, pathIndex + 1, patternIndex + 1);
		}
		return loop(true, 0, 0);
	}

	static function typePath(parts:Array<String>, option:String):GlobalTypePath {
		if (parts.length == 0 || parts[parts.length - 1] == "") throw 'Invalid type path for $option';
		return {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
	}

	static function classPathPath(path:String):String {
		return path.length == 0 || StringTools.endsWith(path, "/") || StringTools.endsWith(path, "\\") ? path : path + "/";
	}

	static function ensureOutputDirectory(file:String):Void {
		var directory = Path.directory(file);
		if (directory != "." && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
	}

	static function unsupported(option:String):Void {
		throw 'Unsupported batch HXB compiler option: $option';
	}
}
