package compiler;

// Help rows from haxe/src/compiler/args.ml; callbacks are never part of usage rendering.
@:structInit class ArgumentDescription {
	public var category:String;
	public var names:Array<String>;
	public var hint:String;
	public var doc:String;
	public var advanced:Bool;

	public inline function new(category:String, names:Array<String>, hint:String, doc:String, advanced:Bool) {
		this.category = category;
		this.names = names;
		this.hint = hint;
		this.doc = doc;
		this.advanced = advanced;
	}

	public inline function clone():ArgumentDescription return new ArgumentDescription(category, names, hint, doc, advanced);
}

class ArgumentDescriptions {
	public static final all:Array<ArgumentDescription> = [
		{
			"category": "Target",
			"names": ["--js"],
			"hint": "<file>",
			"doc": "generate JavaScript code into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--lua"],
			"hint": "<file>",
			"doc": "generate Lua code into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--swf"],
			"hint": "<file>",
			"doc": "generate Flash SWF bytecode into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--neko"],
			"hint": "<file>",
			"doc": "generate Neko bytecode into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--php"],
			"hint": "<directory>",
			"doc": "generate PHP code into target directory",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--cpp"],
			"hint": "<directory>",
			"doc": "generate C++ code into target directory",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--cppia"],
			"hint": "<file>",
			"doc": "generate Cppia bytecode into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--jvm"],
			"hint": "<file>",
			"doc": "generate JVM bytecode into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--python"],
			"hint": "<file>",
			"doc": "generate Python code into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--hl"],
			"hint": "<file>",
			"doc": "generate HashLink .hl bytecode or .c code into target file",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--custom-target"],
			"hint": "<name[=path]>",
			"doc": "generate code for a custom target",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--interp"],
			"hint": "",
			"doc": "interpret the program using internal macro system",
			"advanced": false
		},
		{
			"category": "Target",
			"names": ["--run"],
			"hint": "<module> [args...]",
			"doc": "interpret a Haxe module with command line arguments",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["-p", "--class-path"],
			"hint": "<path>",
			"doc": "add a directory to find source files",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["--hxb-lib"],
			"hint": "<path>",
			"doc": "add a hxb library",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["-m", "--main"],
			"hint": "<class>",
			"doc": "select startup class",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["-L", "--library"],
			"hint": "<name[:ver]>",
			"doc": "use a haxelib library",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["-D", "--define"],
			"hint": "<var[=value]>",
			"doc": "define a conditional compilation flag",
			"advanced": false
		},
		{
			"category": "Compilation",
			"names": ["--undefine"],
			"hint": "<var>",
			"doc": "remove a conditional compilation flag",
			"advanced": false
		},
		{
			"category": "Debug",
			"names": ["-v", "--verbose"],
			"hint": "",
			"doc": "turn on verbose mode",
			"advanced": false
		},
		{
			"category": "Debug",
			"names": ["--debug"],
			"hint": "",
			"doc": "add debug information to the compiled code",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["--version"],
			"hint": "",
			"doc": "print version and exit",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["-h", "--help"],
			"hint": "",
			"doc": "show extended help information",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["--help-defines"],
			"hint": "",
			"doc": "print help for all compiler specific defines",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["--help-user-defines"],
			"hint": "",
			"doc": "print help for all user defines",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["--help-metas"],
			"hint": "",
			"doc": "print help for all compiler metadatas",
			"advanced": false
		},
		{
			"category": "Miscellaneous",
			"names": ["--help-user-metas"],
			"hint": "",
			"doc": "print help for all user metadatas",
			"advanced": false
		},
		{
			"category": "Optimization",
			"names": ["--dce"],
			"hint": "[std|full|no]",
			"doc": "set the dead code elimination mode (default std)",
			"advanced": true
		},
		{
			"category": "Target-specific",
			"names": ["--swf-version"],
			"hint": "<version>",
			"doc": "change the SWF version",
			"advanced": true
		},
		{
			"category": "Target-specific",
			"names": ["--swf-lib"],
			"hint": "<file>",
			"doc": "add the SWF library to the compiled SWF",
			"advanced": true
		},
		{
			"category": "Target-specific",
			"names": ["--swf-lib-extern"],
			"hint": "<file>",
			"doc": "use the SWF library for type checking",
			"advanced": true
		},
		{
			"category": "Target-specific",
			"names": ["--java-lib"],
			"hint": "<file>",
			"doc": "add an external JAR or directory of JAR files",
			"advanced": true
		},
		{
			"category": "Target-specific",
			"names": ["--java-lib-extern"],
			"hint": "<file>",
			"doc": "use an external JAR or directory of JAR files for type checking",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["-r", "--resource"],
			"hint": "<file>[@name]",
			"doc": "add a named resource file",
			"advanced": true
		},
		{
			"category": "Debug",
			"names": ["--prompt"],
			"hint": "",
			"doc": "prompt on error",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["--cmd"],
			"hint": "<command>",
			"doc": "run the specified command after successful compilation",
			"advanced": true
		},
		{
			"category": "Batch",
			"names": ["--next"],
			"hint": "",
			"doc": "separate several haxe compilations",
			"advanced": true
		},
		{
			"category": "Batch",
			"names": ["--each"],
			"hint": "",
			"doc": "append preceding parameters to all Haxe compilations separated by --next",
			"advanced": true
		},
		{
			"category": "Services",
			"names": ["--display"],
			"hint": "",
			"doc": "display code tips",
			"advanced": true
		},
		{
			"category": "Services",
			"names": ["--xml"],
			"hint": "<file>",
			"doc": "generate XML types description",
			"advanced": true
		},
		{
			"category": "Services",
			"names": ["--json"],
			"hint": "<file>",
			"doc": "generate JSON types description",
			"advanced": true
		},
		{
			"category": "Services",
			"names": ["--hxb"],
			"hint": "<file>",
			"doc": "generate haxe binary representation to target archive",
			"advanced": true
		},
		{
			"category": "Optimization",
			"names": ["--no-output"],
			"hint": "",
			"doc": "compiles but does not generate any file",
			"advanced": true
		},
		{
			"category": "Debug",
			"names": ["--times"],
			"hint": "",
			"doc": "measure compilation times",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["--remap"],
			"hint": "<package:target>",
			"doc": "remap a package to another one",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["--custom-extension"],
			"hint": "<extension>",
			"doc": "custom extension used to shadow modules with Module.custom.hx files",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["--macro"],
			"hint": "<macro>",
			"doc": "call the given macro before typing anything else",
			"advanced": true
		},
		{
			"category": "Compilation Server",
			"names": ["--server-listen"],
			"hint": "[[host:]port]|stdio]",
			"doc": "wait on the given port (or use standard i/o) for commands to run",
			"advanced": true
		},
		{
			"category": "Compilation Server",
			"names": ["--server-connect"],
			"hint": "[host:]port]",
			"doc": "connect to the given port and wait for commands to run",
			"advanced": true
		},
		{
			"category": "Compilation Server",
			"names": ["--connect"],
			"hint": "<[host:]port>",
			"doc": "connect on the given port and run commands there",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["-C", "--cwd"],
			"hint": "<directory>",
			"doc": "set current working directory",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["--haxelib-global"],
			"hint": "",
			"doc": "pass --global argument to haxelib",
			"advanced": true
		},
		{
			"category": "Compilation",
			"names": ["-w"],
			"hint": "<warning list>",
			"doc": "enable or disable specific warnings",
			"advanced": true
		}
	];
}
