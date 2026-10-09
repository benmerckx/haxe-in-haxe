package compiler;

import compiler.ParsedArg;
import core.Globals.GlobalTypePath;
import core.Globals as Globals;
import core.Define as Defines;
import core.Meta;
import core.Warning;
import context.Common;
import context.Common.CommonContext;
import core.ds.ArgumentError;
import core.ds.Failure;
import core.ds.NotFound;
import compiler.Helper.HelpMessage;

@:structInit class ArgContext {
	public var classes:Array<GlobalTypePath>;
	public var xmlOut:Null<String>;
	public var hxbOut:Null<String>;
	public var jsonOut:Null<String>;
	public var cmds:Array<String>;
	public var configMacros:Array<String>;
	public var noOutput:Bool;
	public var didSomething:Bool;
	public var forceTyping:Bool;
	public var preCompilation:Array<Void->Void>;
	public var interp:Bool;
	public var jvmFlag:Bool;
	public var swfVersion:Bool;
	public var hxbLibs:Array<NativeLibArg>;
	public var nativeLibs:Array<NativeLibArg>;
	public var raiseUsage:Void->Void;
	public var displayArg:Null<String>;
	public var measureTimes:Bool;

	public inline function new(classes:Array<GlobalTypePath>, xmlOut:Null<String>, hxbOut:Null<String>, jsonOut:Null<String>,
			cmds:Array<String>, configMacros:Array<String>, noOutput:Bool, didSomething:Bool, forceTyping:Bool,
			preCompilation:Array<Void->Void>, interp:Bool, jvmFlag:Bool, swfVersion:Bool, hxbLibs:Array<NativeLibArg>,
			nativeLibs:Array<NativeLibArg>, raiseUsage:Void->Void, displayArg:Null<String>, measureTimes:Bool) {
		this.classes = classes;
		this.xmlOut = xmlOut;
		this.hxbOut = hxbOut;
		this.jsonOut = jsonOut;
		this.cmds = cmds;
		this.configMacros = configMacros;
		this.noOutput = noOutput;
		this.didSomething = didSomething;
		this.forceTyping = forceTyping;
		this.preCompilation = preCompilation;
		this.interp = interp;
		this.jvmFlag = jvmFlag;
		this.swfVersion = swfVersion;
		this.hxbLibs = hxbLibs;
		this.nativeLibs = nativeLibs;
		this.raiseUsage = raiseUsage;
		this.displayArg = displayArg;
		this.measureTimes = measureTimes;
	}

	public inline function clone():ArgContext return new ArgContext(classes, xmlOut, hxbOut, jsonOut, cmds, configMacros, noOutput,
		didSomething, forceTyping, preCompilation, interp, jvmFlag, swfVersion, hxbLibs, nativeLibs, raiseUsage, displayArg, measureTimes);
}

// Port of the parse_args portion of haxe/src/compiler/args.ml.
class Args {
	// haxe/src/compiler/args.ml: to_raw_args (the --connect wire format) and expand_args.
	public static function toRawArgs(args:Array<ParsedArg>):Array<String> {
		function raw(arg:ParsedArg):Array<String> return switch arg {
			case SetPlatform(platform, file): [
					"--" + switch platform {
						case Flash: "swf";
						case Js: "js";
						case Lua: "lua";
						case Neko: "neko";
						case Php: "php";
						case Cpp: "cpp";
						case Jvm: "jvm";
						case Python: "python";
						case Hl: "hl";
					},
					file
				];
			case SetCppiaTarget(file): ["--cppia", file];
			case SetCustomTarget(name, path): ["--custom-target", path == "" ? name : name + "=" + path];
			case AddClassPath(path): ["-cp", path];
			case AddLibClassPath(path): ["-libcp", path];
			case AddHxbLib(file): ["--hxb-lib", file];
			case SetMain(path): ["--main", path.join(".")];
			case AddLib(name): ["-lib", name];
			case HaxelibGlobal: ["--haxelib-global"];
			case Define(flag, value): ["-D", value == null ? flag : flag + "=" + value];
			case Undefine(flag): ["--undefine", flag];
			case SetVerbose: ["-v"];
			case SetDebug: ["--debug"];
			case Interp: ["--interp"];
			case Run(cl, _): ["--run", cl];
			case RunX(cl): ["-x", cl];
			case AddResource(file, name): ["-r", file == name ? file : file + "@" + name];
			case RunCmd(cmd): ["--cmd", cmd];
			case SetSwfVersion(v): ["--swf-version", Std.string(v)];
			case SetDce(mode): ["--dce", mode];
			case AddNativeLib(lib): switch lib.libKind {
					case HxbLib: [];
					case JavaLib | SwfLib: [
							(lib.libKind == JavaLib ? "--java-lib" : "--swf-lib") + (lib.libExtern ? "-extern" : ""),
							lib.libFile
						];
				};
			case AddNekoLibPath(dir): ["--neko-lib-path", dir];
			case Remap(pack, target): ["--remap", pack + ":" + target];
			case SetCustomExtension(ext): ["--custom-extension", ext];
			case AddMacro(e): ["--macro", e];
			case SetDisplayArg(input): ["--display", input];
			case SetXmlOut(file): ["--xml", file];
			case SetJsonOut(file): ["--json", file];
			case SetHxbOut(file): ["--hxb", file];
			case SetNoOutput: ["--no-output"];
			case SetMeasureTimes: ["--times"];
			case AddWarning(s): ["-w", s];
			case AddClass(path): [path.join(".")];
			case IncludeModule(cl): [cl];
			case SetPrompt: ["--prompt"];
			case Next: ["--next"];
			case Each: ["--each"];
			case Expand(ex):
				var out = [];
				for (a in ex.original) out = out.concat(raw(a));
				out;
			case ServerListen(hp): ["--wait", hp];
			case ServerConnect(hp): ["--server-connect", hp];
			case Connect(hp): ["--connect", hp];
			case Cwd(dir): ["--cwd", dir];
			case HxmlFile(path): [path];
			case ShowVersion: ["--version"];
			case ShowHelp: ["--help"];
			case ShowHelpDefines: ["--help-defines"];
			case ShowHelpMetas: ["--help-metas"];
			case ShowHelpUserDefines: ["--help-user-defines"];
			case ShowHelpUserMetas: ["--help-user-metas"];
		};
		var output = [];
		for (arg in args) output = output.concat(raw(arg));
		return output;
	}

	public static function expandArgs(args:Array<ParsedArg>):RequestArgs {
		var each:Array<ParsedArg> = [],
			parts:Array<PartArgs> = [],
			serverMode:RequestServerMode = SMNone;
		var connectArg:Null<String> = null,
			displayArg:Null<String> = null,
			hxmlStack:Array<String> = [];
		function addPart(current:Array<ParsedArg>,
				runtime:Array<String>):Void parts.push({args: each.concat(current), runtimeArgs: runtime});
		function loop(current:Array<ParsedArg>, args:Array<ParsedArg>):Void {
			var i = 0;
			while (i < args.length) switch args[i++] {
				case Next:
					if (current.length > 0) addPart(current, []);
					current = [];
					hxmlStack = [];
				case Each:
					each = current;
					current = [];
				case Cwd(dir):
					try Sys.setCwd(dir)
					catch (_:Dynamic) {}
					current.push(Cwd(dir));
				case Connect(hp):
					connectArg = hp;
				case ServerConnect(hp):
					serverMode = SMConnect(hp);
				case ServerListen(hp):
					serverMode = SMListen(hp);
				case Run(cl, runtime):
					current.push(SetMain(parseTypePath(cl)));
					current.push(Interp);
					addPart(current, runtime.concat(toRawArgs(args.slice(i))));
					return;
				case RunX(cl):
					current.push(SetMain(parseTypePath(cl)));
					current.push(Interp);
				case AddLib(name):
					var libs = [name];
					while (i < args.length) switch args[i] {
						case AddLib(name):
							libs.push(name);
							i++;
						case _: break;
					}
					current.push(Expand(new ExpandingArg(libs.map(name -> AddLib(name)),
						NotYetExpanded(AddLibs(libs, core.Path.removeTrailingSlash(Sys.getCwd()))))));
				case HxmlFile(path):
					var fullPath:String;
					try fullPath = sys.FileSystem.fullPath(path)
					catch (_:Dynamic) {
						throw new ArgumentError("File not found: " + path);
					}
					if (hxmlStack.indexOf(fullPath) >= 0) throw new ArgumentError("Duplicate hxml inclusion: " + fullPath);
					hxmlStack.unshift(fullPath);
					var expanded:Array<ParsedArg>;
					try expanded = parseArgs(Helper.parseHxml(path))
					catch (_:NotFound) {
						expanded = [IncludeModule(path + " (file not found)")];
					}
					loop(current, expanded.concat(args.slice(i)));
					return;
				case SetDisplayArg(s):
					displayArg = s;
					current.push(SetDisplayArg(s));
				case arg:
					current.push(arg);
			}
			addPart(current, []);
		}
		var cwd = Sys.getCwd();
		try loop([], args)
		catch (e:haxe.Exception) {
			core.Path.restoreCwd(cwd);
			throw e;
		}
		core.Path.restoreCwd(cwd);
		return {
			parts: parts,
			serverMode: serverMode,
			connectArg: connectArg,
			displayArg: displayArg
		};
	}

	public static function stringOfRequestArgs(req:RequestArgs):String {
		function quote(s:String):String return s.indexOf(" ") >= 0 || s.indexOf("\t") >= 0 ? haxe.Json.stringify(s) : s;
		var mode = switch req.serverMode {
			case SMNone: "None";
			case SMListen(hp): "Listen " + hp;
			case SMConnect(hp): "Connect " + hp;
		};
		var parts = [
			for (i in 0...req.parts.length) {var p = req.parts[i], args = toRawArgs(p.args).map(quote)
				.join(" "), runtime = p.runtimeArgs.map(quote).join(" ");
				"  Part "
				+ (i + 1)
				+ ": "
				+ args
				+ (runtime == "" ? "" : " -- " + runtime);
			}
		];
		return [
			"server_mode: " + mode,
			"connect_arg: " + (req.connectArg == null ? "<none>" : req.connectArg),
			"display_arg: " + (req.displayArg == null ? "<none>" : req.displayArg),
			"parts:",
			parts.join("\n")
		].join("\n");
	}

	public static function limitString(s:String, offset:Int):String {
		var columns = Std.parseInt(Sys.getEnv("COLUMNS"));
		var rest = (columns == null ? 80 : columns) - offset;
		var parts = [], i = 0;
		for (word in s.split(" ")) if (word.length + i + 1 > rest) {
			parts.push("\n" + StringTools.rpad("", " ", offset));
			parts.push(word);
			i = word.length;
		} else {
			parts.push(i == 0 ? "" : " ");
			parts.push(word);
			i += 1 + word.length;
		}
		return parts.join("");
	}

	public static function usageString(usage:String, extended:Bool):String {
		var rows = ArgumentDescriptions.all.filter(row -> extended || !row.advanced);
		var order = [
			"Target",
			"Compilation",
			"Optimization",
			"Debug",
			"Batch",
			"Services",
			"Compilation Server",
			"Target-specific",
			"Miscellaneous"
		];
		inline function label(row:ArgumentDescriptions.ArgumentDescription):String return row.names.join(", ") + " " + row.hint;
		var max = 0;
		for (row in rows) max = Std.int(Math.max(max, label(row).length));
		var lines = [];
		for (category in order) {
			var group = rows.filter(row -> row.category == category);
			if (group.length == 0) continue;
			lines.push("\n" + category + ":");
			for (row in group) lines.push("  " + StringTools.rpad(label(row), " ", max) + "  " + row.doc);
		}
		return usage + lines.join("\n");
	}

	static function globalPath(parts:Array<String>):GlobalTypePath return {pack: parts.slice(0, -1), name: parts[parts.length - 1]};

	public static function processArgs(com:CommonContext):ArgContext {
		var actx:ArgContext = {
			classes: [{pack: [], name: "Std"}],
			xmlOut: null,
			hxbOut: null,
			jsonOut: null,
			cmds: [],
			configMacros: [],
			noOutput: false,
			didSomething: false,
			forceTyping: false,
			preCompilation: [],
			interp: false,
			jvmFlag: false,
			swfVersion: false,
			hxbLibs: [],
			nativeLibs: [],
			raiseUsage: function() {},
			displayArg: null,
			measureTimes: false
		};
		var usage = "Haxe Compiler " + Globals.sVersionFull(com.sctx.version) + " - (C)2005-2025 Haxe Foundation\nUsage: haxe"
			+ (Sys.systemName() == "Windows" ? ".exe" : "") + " <target> [options] [hxml files and dot paths...]\n";
		inline function docs(result:{all:Array<{name:String, description:String}>, maxLength:Int}):Void throw new HelpMessage([
			for (doc in result.all) " "
				+ StringTools.rpad(doc.name, " ", result.maxLength)
				+ ": "
				+ limitString(doc.description, result.maxLength + 3)].join("\n"));
		var args:Array<ParsedArg> = com.parsedArgs;
		for (arg in args) switch arg {
			case SetPlatform(platform, file):
				var platform:core.Globals.Platform = switch platform {
					case Js: Js;
					case Lua: Lua;
					case Flash: Flash;
					case Neko: Neko;
					case Php:
						actx.classes.unshift({pack: ["php"], name: "Boot"});
						Php;
					case Cpp: Cpp;
					case Jvm:
						actx.jvmFlag = true;
						Jvm;
					case Python: Python;
					case Hl: Hl;
				};
				Common.setPlatform(com, platform, file);
			case SetCppiaTarget(file):
				Common.define(com, Defines.Cppia);
				Common.setPlatform(com, Cpp, file);
			case SetCustomTarget(name, path):
				Common.setCustomTarget(com, name, path);
			case AddClassPath(path):
				com.classPaths.add(new core.ClassPath.DirectoryClassPath(core.Path.addTrailingSlash(path), User));
			case AddLibClassPath(path):
				com.classPaths.add(new core.ClassPath.DirectoryClassPath(core.Path.addTrailingSlash(path), Lib));
			case AddHxbLib(file):
				actx.hxbLibs.unshift({libFile: file, libExtern: false, libKind: HxbLib});
			case SetMain(path):
				if (com.main.mainPath != null) throw new ArgumentError("Multiple --main classes specified");
				var path = globalPath(path);
				com.main.mainPath = path;
				actx.classes.unshift(path);
			case AddLib(_) | HaxelibGlobal: // Expanded by the request layer.
			case Define(flag, value):
				if (value == null) Common.externalDefine(com, flag);
				else Common.externalDefineValue(com, flag, value);
				if (flag == "no-opt") com.foptimize = false;
			case Undefine(flag):
				Common.externalUndefine(com, flag);
			case SetVerbose:
				com.verbose = true;
			case SetDebug:
				Common.define(com, Defines.Debug);
				com.debug = true;
			case Interp:
				Common.define(com, Defines.Interp);
				Common.setPlatform(com, Eval, "");
				actx.interp = true;
			case Run(_, _) | RunX(_): // Expanded by the request layer.
			case AddResource(file, name):
				file = try Common.findFile(com, file) catch (_:NotFound) file;
				var data:haxe.io.Bytes;
				try {
					var bytes = sys.io.File.getBytes(file);
					if (bytes.length > 12000000) throw core.ds.Exit.raise();
					data = bytes;
				} catch (e:Dynamic) {
					if (Std.isOfType(e, core.ds.Exit)) throw new Failure("Resource '" + file + "' excess the maximum size of 12MB");
					throw new Failure("Resource file not found: " + file);
				}
				if (com.resources.exists(name)) throw new Failure("Duplicate resource name " + name);
				com.resources.set(name, data);
			case RunCmd(cmd):
				actx.cmds.unshift(cmd);
			case SetSwfVersion(v):
				if (!actx.swfVersion || com.flashVersion < v) com.flashVersion = v;
				actx.swfVersion = true;
			case SetDce(mode):
				if (mode != "std" && mode != "full" && mode != "no") throw new ArgumentError("Invalid DCE mode, expected std | full | no");
				Common.defineValue(com, Defines.Dce, mode);
			case AddNativeLib(lib):
				actx.nativeLibs.unshift(lib);
			case AddNekoLibPath(dir):
				com.nekoLibPaths.unshift(dir);
			case Remap(pack, target):
				var rules = com.packageRules.copy();
				rules.set(pack, context.Common.PackageRule.Remap(target));
				com.packageRules = rules;
			case SetCustomExtension(ext):
				com.customExt = ext;
			case AddMacro(e):
				actx.forceTyping = true;
				actx.configMacros.unshift(e);
			case SetDisplayArg(input):
				actx.displayArg = input;
			case SetXmlOut(file):
				actx.xmlOut = file;
			case SetJsonOut(file):
				actx.jsonOut = file;
			case SetHxbOut(file):
				actx.hxbOut = file;
			case SetNoOutput:
				actx.noOutput = true;
			case SetMeasureTimes:
				actx.measureTimes = true;
			case AddWarning(s):
				com.warningOptions.unshift(Warning.parseOptions(s, Globals.fakePos("-w " + s)));
			case AddClass(path):
				actx.classes.unshift(globalPath(path));
			case IncludeModule(cl):
				actx.forceTyping = true;
				actx.configMacros.unshift("include('" + cl + "', true, null, null, true)");
			case SetPrompt:
				Helper.prompt = true;
			case Cwd(dir):
				try Sys.setCwd(dir)
				catch (_:Dynamic) throw new ArgumentError("Invalid directory: " + dir);
				actx.didSomething = true;
			case HxmlFile(_) | Next | Each | Expand(_) | ServerListen(_) | ServerConnect(_) | Connect(_): // Request-layer directives.
			case ShowVersion:
				throw new HelpMessage(Globals.sVersionFull(com.sctx.version));
			case ShowHelp:
				throw new HelpMessage(usageString(usage, true));
			case ShowHelpDefines:
				docs(Defines.getDocumentationList(com.userDefines));
			case ShowHelpMetas:
				docs(Meta.getDocumentationList(com.userMetas));
			case ShowHelpUserDefines:
				actx.didSomething = true;
				com.callbacks.addAfterInitMacros(function() docs(Defines.getUserDocumentationList(com.userDefines)));
			case ShowHelpUserMetas:
				actx.didSomething = true;
				com.callbacks.addAfterInitMacros(function() docs(Meta.getUserDocumentationList(com.userMetas)));
		}
		if (com.platform == core.Globals.Platform.Cpp
			&& !Defines.defined(com.defines, Defines.DisableUnicodeStrings)
			&& !Defines.defined(com.defines, Defines.HxcppSmartStings)) Defines.define(com.defines, Defines.HxcppSmartStings);
		if (Defines.rawDefined(com.defines,
			"gen_hx_classes")) throw new ArgumentError("Native-library class generation requires the native-library milestone");
		actx.raiseUsage = function() throw new HelpMessage(usageString(usage, false));
		return actx;
	}

	/** Expands HXML markers using the same eager, section-local inclusion rules as args.ml. */
	public static function expandHxml(arguments:Array<ParsedArg>):Array<ParsedArg> {
		var expanded:Array<ParsedArg> = [];
		var included:Array<String> = [];
		function loop(values:Array<ParsedArg>):Void for (argument in values) switch argument {
			case HxmlFile(path):
				if (!sys.FileSystem.exists(path)) throw 'File not found: $path';
				var fullPath = sys.FileSystem.fullPath(path);
				if (included.indexOf(fullPath) != -1) throw 'Duplicate hxml inclusion: $fullPath';
				included.push(fullPath);
				loop(parseArgs(Helper.parseHxml(path)));
			case Cwd(path):
				try Sys.setCwd(path)
				catch (_:Dynamic) {}
				expanded.push(argument);
			case Next | Each:
				included = [];
				expanded.push(argument);
			case _:
				expanded.push(argument);
		}
		loop(arguments);
		return expanded;
	}

	public static function parseArgs(arguments:Array<String>):Array<ParsedArg> {
		var parsed:Array<ParsedArg> = [];
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			switch (argument) {
				case "--next", "-next":
					parsed.push(Next);
				case "--each", "-each":
					parsed.push(Each);
				case "--cwd", "-C":
					parsed.push(Cwd(requiredArgument(argument, arguments, index++)));
				case "--js", "-js":
					parsed.push(SetPlatform(Js, requiredArgument(argument, arguments, index++)));
				case "--lua", "-lua":
					parsed.push(SetPlatform(Lua, requiredArgument(argument, arguments, index++)));
				case "--swf", "-swf":
					parsed.push(SetPlatform(Flash, requiredArgument(argument, arguments, index++)));
				case "--neko", "-neko":
					parsed.push(SetPlatform(Neko, requiredArgument(argument, arguments, index++)));
				case "--php", "-php":
					parsed.push(SetPlatform(Php, requiredArgument(argument, arguments, index++)));
				case "--cpp", "-cpp":
					parsed.push(SetPlatform(Cpp, requiredArgument(argument, arguments, index++)));
				case "--jvm", "-jvm":
					parsed.push(SetPlatform(Jvm, requiredArgument(argument, arguments, index++)));
					parsed.push(AddLib("hxjava"));
				case "--python", "-python":
					parsed.push(SetPlatform(Python, requiredArgument(argument, arguments, index++)));
				case "--hl", "-hl":
					parsed.push(SetPlatform(Hl, requiredArgument(argument, arguments, index++)));
				case "--custom-target", "-custom":
					var target = requiredArgument(argument, arguments, index++);
					var equals = target.indexOf("=");
					parsed.push(equals < 0 ? SetCustomTarget(target,
						"") : SetCustomTarget(target.substr(0, equals), target.substr(equals + 1)));
				case "--cppia", "-cppia":
					parsed.push(SetCppiaTarget(requiredArgument(argument, arguments, index++)));
				case "-x":
					parsed.push(RunX(requiredArgument(argument, arguments, index++)));
				case "--interp":
					parsed.push(Interp);
				case "--run":
					var path = requiredArgument(argument, arguments, index++);
					parsed.push(Run(path, arguments.slice(index)));
					return parsed;
				case "--class-path", "-p", "-cp":
					parsed.push(AddClassPath(requiredArgument(argument, arguments, index++)));
				case "-libcp":
					parsed.push(AddLibClassPath(requiredArgument(argument, arguments, index++)));
				case "--hxb-lib", "-hxb-lib":
					parsed.push(AddHxbLib(requiredArgument(argument, arguments, index++)));
				case "--main", "-m", "-main":
					parsed.push(SetMain(parseTypePath(requiredArgument(argument, arguments, index++))));
				case "--library", "-L", "-lib":
					parsed.push(AddLib(requiredArgument(argument, arguments, index++)));
				case "--define", "-D":
					var define = requiredArgument(argument, arguments, index++);
					var equals = define.indexOf("=");
					parsed.push(equals < 0 ? Define(define, null) : Define(define.substr(0, equals), define.substr(equals + 1)));
				case "--undefine":
					parsed.push(Undefine(requiredArgument(argument, arguments, index++)));
				case "--verbose", "-v":
					parsed.push(SetVerbose);
				case "--debug", "-debug":
					parsed.push(SetDebug);
				case "--version", "-version":
					parsed.push(ShowVersion);
					return parsed;
				case "--help", "-h", "-help":
					parsed.push(ShowHelp);
					return parsed;
				case "--help-defines":
					parsed.push(ShowHelpDefines);
					return parsed;
				case "--help-metas":
					parsed.push(ShowHelpMetas);
					return parsed;
				case "--help-user-defines":
					parsed.push(ShowHelpUserDefines);
					return parsed;
				case "--help-user-metas":
					parsed.push(ShowHelpUserMetas);
					return parsed;
				case "--dce", "-dce":
					parsed.push(SetDce(requiredArgument(argument, arguments, index++)));
				case "--swf-version", "-swf-version":
					var version = Std.parseFloat(requiredArgument(argument, arguments, index++));
					if (!Math.isNaN(version)) parsed.push(SetSwfVersion(version));
				case "--swf-lib", "-swf-lib":
					parsed.push(AddNativeLib(nativeLib(requiredArgument(argument, arguments, index++), false, SwfLib)));
				case "--swf-lib-extern", "-swf-lib-extern":
					parsed.push(AddNativeLib(nativeLib(requiredArgument(argument, arguments, index++), true, SwfLib)));
				case "--java-lib", "-java-lib":
					parsed.push(AddNativeLib(nativeLib(requiredArgument(argument, arguments, index++), false, JavaLib)));
				case "--java-lib-extern":
					parsed.push(AddNativeLib(nativeLib(requiredArgument(argument, arguments, index++), true, JavaLib)));
				case "--neko-lib-path":
					parsed.push(AddNekoLibPath(requiredArgument(argument, arguments, index++)));
				case "--resource", "-r", "-resource":
					var resource = requiredArgument(argument, arguments, index++);
					var at = resource.indexOf("@");
					parsed.push(at < 0 ? AddResource(resource, resource) : AddResource(resource.substr(0, at), resource.substr(at + 1)));
				case "--cmd", "-cmd":
					parsed.push(RunCmd(Helper.unquote(requiredArgument(argument, arguments, index++))));
				case "--prompt", "-prompt":
					parsed.push(SetPrompt);
				case "--display":
					parsed.push(SetDisplayArg(requiredArgument(argument, arguments, index++)));
				case "--xml", "-xml":
					parsed.push(SetXmlOut(requiredArgument(argument, arguments, index++)));
				case "--json":
					parsed.push(SetJsonOut(requiredArgument(argument, arguments, index++)));
				case "--hxb":
					parsed.push(SetHxbOut(requiredArgument(argument, arguments, index++)));
				case "--no-output":
					parsed.push(SetNoOutput);
				case "--times":
					parsed.push(SetMeasureTimes);
				case "--macro", "-macro":
					parsed.push(AddMacro(requiredArgument(argument, arguments, index++)));
				case "--remap", "-remap":
					var remap = requiredArgument(argument, arguments, index++);
					var colon = remap.indexOf(":");
					if (colon >= 0) parsed.push(Remap(remap.substr(0, colon), remap.substr(colon + 1)));
				case "--custom-extension":
					parsed.push(SetCustomExtension(requiredArgument(argument, arguments, index++)));
				case "--server-listen", "--wait":
					parsed.push(ServerListen(requiredArgument(argument, arguments, index++)));
				case "--server-connect":
					parsed.push(ServerConnect(requiredArgument(argument, arguments, index++)));
				case "--connect":
					parsed.push(Connect(requiredArgument(argument, arguments, index++)));
				case "--haxelib-global":
					parsed.push(HaxelibGlobal);
				case "-w":
					parsed.push(AddWarning(requiredArgument(argument, arguments, index++)));
				default:
					if (StringTools.endsWith(argument, ".hxml")) parsed.push(HxmlFile(argument));
					else {
						var path = try core.Path.parsePath(argument) catch (_:String) null;
						if (path == null) parsed.push(IncludeModule(argument));
						else if (core.StringHelper.startsUppercaseIdentifier(path.name))
							parsed.push(AddClass(path.pack.concat([path.name])));
						else parsed.push(IncludeModule(argument));
					}
			}
		}
		return parsed;
	}

	static function requiredArgument(option:String, arguments:Array<String>, index:Int):String {
		if (index >= arguments.length) throw 'Missing argument for $option';
		return arguments[index];
	}

	static function parseTypePath(path:String):Array<String> {
		return path.split(".");
	}

	static function nativeLib(file:String, isExtern:Bool, kind:NativeLibKind):NativeLibArg {
		return {libFile: file, libExtern: isExtern, libKind: kind};
	}
}

// Request structures from args.ml.
@:structInit class PartArgs {
	public var args:Array<ParsedArg>;
	public var runtimeArgs:Array<String>;

	public inline function new(args:Array<ParsedArg>, runtimeArgs:Array<String>) {
		this.args = args;
		this.runtimeArgs = runtimeArgs;
	}

	public inline function clone():PartArgs return new PartArgs(args, runtimeArgs);
}

enum RequestServerMode {
	SMNone;
	SMListen(hostPort:String);
	SMConnect(hostPort:String);
}

@:structInit class RequestArgs {
	public var parts:Array<PartArgs>;
	public var serverMode:RequestServerMode;
	public var connectArg:Null<String>;
	public var displayArg:Null<String>;

	public inline function new(parts:Array<PartArgs>, serverMode:RequestServerMode, connectArg:Null<String>, displayArg:Null<String>) {
		this.parts = parts;
		this.serverMode = serverMode;
		this.connectArg = connectArg;
		this.displayArg = displayArg;
	}

	public inline function clone():RequestArgs return new RequestArgs(parts, serverMode, connectArg, displayArg);
}
