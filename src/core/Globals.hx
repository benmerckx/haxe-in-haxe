package core;

// Port of the foundational definitions in haxe/src/core/globals.ml.
// A class rather than a structure so static targets access fields directly;
// @:structInit keeps `{pfile:..., pmin:..., pmax:...}` literals working.
@:structInit class Pos {
	public var pfile:String;
	public var pmin:Int;
	public var pmax:Int;

	public inline function new(pfile:String, pmin:Int, pmax:Int) {
		this.pfile = pfile;
		this.pmin = pmin;
		this.pmax = pmax;
	}

	public inline function clone():Pos return new Pos(pfile, pmin, pmax);
}

// A class so map keys (module lookups) compare without reflection; see
// core.ds.Key. @:structInit keeps `{pack:..., name:...}` literals working.
@:structInit class GlobalTypePath {
	public var pack:Array<String>;
	public var name:String;

	public inline function new(pack:Array<String>, name:String) {
		this.pack = pack;
		this.name = name;
	}

	// "pack.name#" style key, cached while pack and name are unchanged (HXB pools).
	var keyCache:Null<String> = null;
	var keyPack:Null<Array<String>> = null;
	var keyName:Null<String> = null;
	var keyPackLength = 0;

	public function hashKey():String {
		if (keyCache == null || keyPack != pack || keyName != name || keyPackLength != pack.length) {
			keyCache = pack.join(".") + "#" + name;
			keyPack = pack;
			keyName = name;
			keyPackLength = pack.length;
		}
		return keyCache;
	}

	public inline function clone():GlobalTypePath return new GlobalTypePath(pack, name);
}

@:structInit class CompilerVersion {
	public var version:Int;
	public var major:Int;
	public var minor:Int;
	public var revision:Int;
	public var pre:Null<String>;
	public var extra:Null<{name:String, build:String}>;

	public inline function new(version:Int, major:Int, minor:Int, revision:Int, pre:Null<String>, extra:Null<{name:String, build:String}>) {
		this.version = version;
		this.major = major;
		this.minor = minor;
		this.revision = revision;
		this.pre = pre;
		this.extra = extra;
	}

	public inline function clone():CompilerVersion return new CompilerVersion(version, major, minor, revision, pre, extra);
}

enum Platform {
	Cross;
	Js;
	Lua;
	Neko;
	Flash;
	Php;
	Cpp;
	Jvm;
	Python;
	Hl;
	Eval;
	CustomTarget(name:String);
}

class Globals {
	public static final genLocalPrefix = "`";
	public static final version = 5000;
	public static final versionMajor = Std.int(version / 1000);
	public static final versionMinor = Std.int((version % 1000) / 100);
	public static final versionRevision = version % 100;
	public static final versionPre:Null<String> = "preview.1";

	public static final isWindows = Sys.systemName() == "Windows" || Sys.systemName() == "Cygwin";
	public static final maxCustomTargetLen = 16;
	public static final platforms:Array<Platform> = [Js, Lua, Neko, Flash, Php, Cpp, Jvm, Python, Hl, Eval];
	public static final sVersion = versionToString();

	static function versionToString():String {
		return versionMajor + "." + versionMinor + "." + versionRevision + (versionPre == null ? "" : "-" + versionPre);
	}

	public static function filePos(file:String):Pos return {pfile: file, pmin: 0, pmax: 0};

	public static function fakePos(file:String):Pos return {pfile: file, pmin: -1, pmax: -1};

	public static final nullPos:Pos = fakePos("?");

	public static function platformName(platform:Platform):String {
		return switch (platform) {
			case Cross: "cross";
			case Js: "js";
			case Lua: "lua";
			case Neko: "neko";
			case Flash: "flash";
			case Php: "php";
			case Cpp: "cpp";
			case Jvm: "jvm";
			case Python: "python";
			case Hl: "hl";
			case Eval: "eval";
			case CustomTarget(name): name;
		};
	}

	public static function parsePlatform(name:String):Platform {
		return switch (name) {
			case "cross": Cross;
			case "js": Js;
			case "lua": Lua;
			case "neko": Neko;
			case "flash": Flash;
			case "php": Php;
			case "cpp": Cpp;
			case "jvm": Jvm;
			case "python": Python;
			case "hl": Hl;
			case "eval": Eval;
			case _: CustomTarget(name);
		};
	}

	public static function platformListHelp(platforms:Array<Platform>):String {
		return switch (platforms.length) {
			case 0: "";
			case 1: " (" + platformName(platforms[0]) + " only)";
			case _: " (for " + [for (platform in platforms) platformName(platform)].join(",") + ")";
		};
	}

	public static function mkZeroRangePos(pos:Pos):Pos return {pfile: pos.pfile, pmin: pos.pmin, pmax: pos.pmin};

	public static function sTypePath(path:GlobalTypePath):String return path.pack.length == 0 ? path.name : path.pack.join(".")
		+ "."
		+ path.name;

	public static function startsWith(value:String, char:String):Bool return value.length > 0 && value.charAt(0) == char;

	public static function patchStringPos(pos:Pos,
			value:String):Pos return {pfile: pos.pfile, pmin: pos.pmax - value.length, pmax: pos.pmax};

	// Like globals.ml, this only appends the build portion of the supplied version.
	public static function sVersionFull(version:CompilerVersion):String return version.extra == null ? sVersion : sVersion
		+ "+"
		+ version.extra.build;

	// globals.ml:195: preserve the failure payload and source location with a Haxe stack.
	public static function die(msg:String, source:String, ?p:Pos):Dynamic {
		var prefix = p == null ? "" : p.pfile + ":" + p.pmin + ": ";
		var message = prefix
			+ "Compiler failure"
			+ (msg == "" ? "" : ": " + msg)
			+ "\n"
			+ prefix
			+ "Please submit an issue at https://github.com/HaxeFoundation/haxe/issues/new\n"
			+ prefix
			+ "Attach "
			+ (p == null ? "" : "the expression example and ")
			+ "the following information:";
		throw new InternalCompilerError(message, source + "\n" + haxe.CallStack.toString(haxe.CallStack.callStack().slice(1, 21)));
	}
}

class InternalCompilerError extends haxe.Exception {
	public final backtrace:String;

	public function new(message:String, backtrace:String) {
		super(message);
		this.backtrace = backtrace;
	}
}
