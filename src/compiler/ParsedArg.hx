package compiler;

// Port of haxe/src/compiler/parsedArg.ml.

enum Platform {
	Js;
	Lua;
	Flash;
	Neko;
	Php;
	Cpp;
	Jvm;
	Python;
	Hl;
}

enum NativeLibKind {
	JavaLib;
	SwfLib;
	HxbLib;
}

@:structInit class NativeLibArg {
	public var libFile:String;
	public var libKind:NativeLibKind;
	public var libExtern:Bool;

	public inline function new(libFile:String, libKind:NativeLibKind, libExtern:Bool) {
		this.libFile = libFile;
		this.libKind = libKind;
		this.libExtern = libExtern;
	}

	public inline function clone():NativeLibArg return new NativeLibArg(libFile, libKind, libExtern);
}

enum ExpandingArgFunction {
	AddLibs(libs:Array<String>, cwd:String);
}

enum ExpandingArgState {
	NotYetExpanded(f:ExpandingArgFunction);
	AlreadyExpanded(args:Array<ParsedArg>);
}

class ExpandingArg {
	public final original:Array<ParsedArg>;
	public var state:ExpandingArgState;

	public function new(original:Array<ParsedArg>, state:ExpandingArgState) {
		this.original = original;
		this.state = state;
	}
}

/** The CLI representation is intentionally separate from compiler context mutation. */
enum ParsedArg {
	SetPlatform(platform:Platform, output:String);
	SetCustomTarget(name:String, path:String);
	SetCppiaTarget(output:String);
	AddClassPath(path:String);
	AddLibClassPath(path:String);
	AddHxbLib(file:String);
	SetMain(path:Array<String>);
	AddLib(name:String);
	HaxelibGlobal;
	Define(flag:String, value:Null<String>);
	Undefine(flag:String);
	SetVerbose;
	SetDebug;
	Interp;
	Run(path:String, arguments:Array<String>);
	RunX(path:String);
	AddResource(file:String, name:String);
	RunCmd(command:String);
	SetSwfVersion(version:Float);
	SetDce(mode:String);
	AddNativeLib(library:NativeLibArg);
	AddNekoLibPath(path:String);
	Remap(pack:String, target:String);
	SetCustomExtension(extension:String);
	AddMacro(expression:String);
	SetDisplayArg(input:String);
	SetXmlOut(file:String);
	SetJsonOut(file:String);
	SetHxbOut(file:String);
	SetNoOutput;
	SetMeasureTimes;
	AddWarning(setting:String);
	AddClass(path:Array<String>);
	IncludeModule(module:String);
	SetPrompt;
	Next;
	Each;
	Expand(ex:ExpandingArg);
	ServerListen(hostPort:String);
	ServerConnect(hostPort:String);
	Connect(hostPort:String);
	Cwd(path:String);
	HxmlFile(file:String);
	ShowVersion;
	ShowHelp;
	ShowHelpDefines;
	ShowHelpMetas;
	ShowHelpUserDefines;
	ShowHelpUserMetas;
}
