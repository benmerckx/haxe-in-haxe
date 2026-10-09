package core;

// Port of haxe/src/core/classPath.ml.
enum ClassPathScope {
	Std;
	StdTarget;
	Lib;
	User;
}

enum FileKind {
	FFile;
}

@:structInit class DirectoryListing {
	public var directory:String;
	public var files:Array<String>;

	public inline function new(directory:String, files:Array<String>) {
		this.directory = directory;
		this.files = files;
	}

	public inline function clone():DirectoryListing return new DirectoryListing(directory, files);
}

interface IClassPath {
	public var path(get, never):String;
	public var scope(get, never):ClassPathScope;
	public var fileKind(get, never):FileKind;
	public function clone():IClassPath;
	public function clearCache():Void;
	public function getDirectoryPath():Null<String>;
	public function getUncachedDirListing(file:String):Null<DirectoryListing>;
	public function dump():Void;
	public function isStdPath():Bool;
	public function scopeString():String;
}

class DirectoryClassPath implements IClassPath {
	final classPath:String;
	final classPathScope:ClassPathScope;
	var directoryCache:Map<String, Null<Array<String>>> = new Map();

	public function new(path:String, scope:ClassPathScope) {
		classPath = path;
		classPathScope = scope;
	}

	public var path(get, never):String;

	function get_path():String return classPath;

	public var scope(get, never):ClassPathScope;

	function get_scope():ClassPathScope return classPathScope;

	public var fileKind(get, never):FileKind;

	function get_fileKind():FileKind return FFile;

	public function clone():IClassPath {
		return new DirectoryClassPath(classPath, classPathScope);
	}

	public function clearCache():Void {
		directoryCache = new Map();
	}

	public function getDirectoryPath():Null<String> {
		return classPath;
	}

	public function getUncachedDirListing(file:String):Null<DirectoryListing> {
		var fullPath = classPath + file;
		var directory = ocamlDirname(fullPath);
		if (directoryCache.exists(directory)) return null;
		var listing:Null<Array<String>>;
		try listing = sys.FileSystem.readDirectory(directory)
		catch (_:Dynamic) listing = null;
		directoryCache.set(directory, listing);
		return listing == null ? null : {directory: directory, files: listing};
	}

	// OCaml Filename.dirname (Unix): "Main.hx" is ".", unlike haxe.io.Path.directory.
	public static function ocamlDirname(name:String):String {
		inline function isSep(n:Int):Bool return name.charCodeAt(n) == "/".code;
		if (name == "") return ".";
		var n = name.length - 1;
		while (n >= 0 && isSep(n)) n--;
		if (n < 0) return name.substr(0, 1);
		while (n >= 0 && !isSep(n)) n--;
		if (n < 0) return ".";
		while (n >= 0 && isSep(n)) n--;
		if (n < 0) return name.substr(0, 1);
		return name.substr(0, n + 1);
	}

	public function dump():Void {
		Sys.println('    dir ${scopeString()}: $classPath');
	}

	public function isStdPath():Bool {
		return classPathScope == Std;
	}

	public function scopeString():String {
		return switch (classPathScope) {
			case Std: "Std";
			case StdTarget: "StdTarget";
			case Lib: "Lib";
			case User: "User";
		};
	}
}
