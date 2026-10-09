package core;

import sys.FileSystem;
import sys.io.File;
import sys.io.FileOutput;
import sys.thread.Mutex;

// Port of haxe/src/core/path.ml.
@:structInit class FilePathData {
	public var directory:Null<String>;
	public var fileName:Null<String>;
	public var extension:Null<String>;
	public var backslash:Bool;

	public inline function new(directory:Null<String>, fileName:Null<String>, extension:Null<String>, backslash:Bool) {
		this.directory = directory;
		this.fileName = fileName;
		this.extension = extension;
		this.backslash = backslash;
	}

	public inline function clone():FilePathData return new FilePathData(directory, fileName, extension, backslash);
}

class Path {
	// Unix.chdir back to a saved directory. Skips the call when the directory did
	// not change, so hosts without chdir support (JVM) can run the batch driver.
	public static function restoreCwd(cwd:String):Void {
		if (Sys.getCwd() != cwd) Sys.setCwd(cwd);
	}

	// Globals.platforms is not ported yet; this is its current fixed target-name list.
	static final platformNames = ["js", "lua", "neko", "flash", "php", "cpp", "jvm", "python", "hl", "eval"];
	public static final isWindows = Sys.systemName() == "Windows";
	public static final pathSep = isWindows ? "\\" : "/";
	static final mkdirMutex = new Mutex();

	public static function getPathParts(file:String):Array<String> {
		var length = file.length;
		if (length > 3 && file.substr(length - 3) == ".hx") {
			file = file.substr(0, length - 3);
			return file.split("\\").join("/").split("/");
		}
		return file.split(".");
	}

	public static function checkInvalidChar(value:String):Void {
		for (index in 1...value.length) {
			var code = value.charCodeAt(index);
			if (!((code >= "A".code && code <= "Z".code)
				|| (code >= "a".code && code <= "z".code)
				|| (code >= "0".code && code <= "9".code)
				|| code == "_".code
				|| code == ".".code)) throw 'Invalid character: ${StringHelper.sEscape(value.charAt(index))}';
		}
	}

	public static function checkPackageName(value:String):Void {
		if (value.length == 0) throw "Package name must not be empty";
		var code = value.charCodeAt(0);
		if (!((code >= "a".code && code <= "z".code) || code == "_".code)) throw "Package name must start with a lowercase letter";
		checkInvalidChar(value);
	}

	public static function parsePath(file:String):core.Globals.GlobalTypePath {
		var parts = getPathParts(file);
		inline function fail(message:String):Dynamic throw 'Could not process argument $file\n$message';
		function loop(index:Int, pack:Array<String>):core.Globals.GlobalTypePath {
			if (index == parts.length) return fail("Package name must not be empty");
			var value = parts[index];
			if (index == parts.length - 1) {
				checkInvalidChar(value);
				return {pack: pack, name: value};
			}
			// `_ :: ("_std" :: l) -> loop l` drops "_std" and the part before it.
			if (parts[index + 1] == "_std") return loop(index + 2, pack);
			checkPackageName(value);
			pack.push(value);
			return loop(index + 1, pack);
		}
		try return loop(0, [])
		catch (error:Dynamic) return fail(Std.string(error));
	}

	public static function parseTypePath(value:String):{pack:Array<String>, name:String} {
		var path = parsePath(value);
		StringHelper.checkUppercase(path.name);
		return path;
	}

	public static function normalizePath(path:String):String {
		var acc:Array<String> = [];
		var start = 0;
		var index = 0;
		while (index < path.length) {
			var code = path.charCodeAt(index);
			if (code == "/".code || code == "\\".code) {
				var value = path.substr(start, index - start);
				while (index < path.length && (path.charCodeAt(index) == "/".code || path.charCodeAt(index) == "\\".code)) index++;
				if (value == "." && acc.length == 0) {} else if (value == "..") {
					if (acc.length == 0) throw "Exit";
					acc.pop();
				} else acc.push(value);
				start = index;
			} else index++;
		}
		if (start < path.length) acc.push(path.substr(start));
		return acc.join("/");
	}

	public static function isAbsolutePath(file:String):Bool {
		if (file.length == 0) return false;
		var first = file.charCodeAt(0);
		if (first == "/".code) return true;
		if ((first >= "A".code && first <= "Z".code)
			|| (first >= "a".code && first <= "z".code)) return isWindows && file.length > 1 && file.charCodeAt(1) == ":".code;
		return first == "\\".code && isWindows;
	}

	public static function getFullPath(file:String):String {
		if (isWindows) return try FileSystem.fullPath(file) catch (_:Dynamic) file;
		var length = file.length;
		// Unix.getcwd has no trailing slash, unlike Sys.getCwd.
		var cwd = Sys.getCwd();
		if (cwd.length > 1 && StringTools.fastCodeAt(cwd, cwd.length - 1) == "/".code) cwd = cwd.substr(0, cwd.length - 1);
		var absolutePath = length > 0 && StringTools.fastCodeAt(file, 0) == "/".code ? file : length == 0 ? cwd : cwd + "/" + file;
		var needsNormalization = length > 0 && StringTools.fastCodeAt(file, length - 1) == "/".code;
		// has_dots_or_double_slash: only the first character of each segment is inspected.
		// (fastCodeAt: every index here is checked against the length, and
		// charCodeAt boxes its Null<Int> result on HashLink.)
		var index = 0;
		while (!needsNormalization && index < length) {
			var c = StringTools.fastCodeAt(file, index);
			if (c == ".".code) {
				if (index + 2 < length) needsNormalization = (StringTools.fastCodeAt(file, index + 1) == ".".code
					&& StringTools.fastCodeAt(file, index + 2) == "/".code)
					|| StringTools.fastCodeAt(file, index + 1) == "/".code;
				else if (index + 1 < length) needsNormalization = StringTools.fastCodeAt(file, index + 1) == "/".code
					|| StringTools.fastCodeAt(file, index + 1) == ".".code;
				else needsNormalization = true;
			} else if (c == "/".code && index > 0) needsNormalization = true;
			if (!needsNormalization) {
				while (index < length && StringTools.fastCodeAt(file, index) != "/".code) index++;
				index++;
			}
		}
		if (!needsNormalization) return absolutePath;
		var parts = absolutePath.split("/");
		var skip = 0;
		var normalized:Array<String> = [];
		for (reverseIndex in 0...parts.length) {
			var current = parts[parts.length - reverseIndex - 1];
			if (current == "..") skip++;
			else if (current != "." && current != "") {
				if (skip > 0) skip--;
				else normalized.unshift(current);
			}
		}
		return "/" + normalized.join("/");
	}

	public static function getRealPath(path:String):String {
		// Extc.get_real_path fails for a missing file (falling back to `path`);
		// HashLink's fullPath returns null instead of throwing.
		var r = try FileSystem.fullPath(path) catch (_:Dynamic) null;
		return r == null ? path : r;
	}

	public static function addTrailingSlash(path:String):String return path.length == 0 ? "./" : switch (path.charAt(path.length - 1)) {
		case "/" | "\\": path;
		case _: path + "/";
	};

	public static function removeTrailingSlash(path:String):String {
		while (path.length > 0
			&& (path.charAt(path.length - 1) == "/" || path.charAt(path.length - 1) == "\\")) path = path.substr(0, path.length - 1);
		return path.length == 0 ? "./" : path;
	}

	public static function flatPath(path:{pack:Array<String>, name:String}):String {
		var escape = function(value:String) return value.split("_").join("_$");
		return path.pack.length == 0 ? escape(path.name) : path.pack.map(escape).join("_") + "_" + escape(path.name);
	}

	public static function findDirectories(target:String, recursive:Bool, paths:Array<String>):Array<String> {
		var result:Array<String> = [];
		function loop(directory:String):Void try {
			for (file in FileSystem.readDirectory(directory)) if (file != "." && file != "..") {
				var full = directory + file;
				if (FileSystem.isDirectory(full)
					&& file.charCodeAt(0) >= "a".code
					&& file.charCodeAt(0) <= "z".code
					&& !(platformNames.indexOf(file) >= 0 && file != target)) {
					// consed onto the accumulator, as upstream
					if (recursive) {
						result.unshift(full);
						loop(full + "/");
					} else result.unshift(full);
				}
			}
		} catch (_:Dynamic) {};
		for (directory in paths) loop(directory);
		return result;
	}

	public static function makeValidFilename(value:String):String return ~/[^A-Za-z0-9_\-\.,]/g.replace(value, "_");

	public static function moduleNameOfFile(file:String):String {
		var parts = new EReg("[\\\\/]+", "g").split(getRealPath(file));
		if (parts.length == 0) throw "Unreachable";
		var name = parts[parts.length - 1].split(".");
		return name.length == 1 ? name[0] : name.length == 2 ? name[0] : name.slice(0, name.length - 2).join(".");
	}

	public static function createFile(binary:Bool, extension:String, acc:Array<String>, parts:Array<String>):FileOutput {
		if (parts.length == 0) throw "Unreachable";
		var directory = parts.shift();
		if (parts.length == 0) {
			directory = makeValidFilename(directory);
			var maxLength = 200 - extension.length;
			if (directory.length > maxLength) directory = directory.substr(0, maxLength);
			return binary ? File.write(acc.concat([directory]).join("/") + extension,
				true) : File.write(acc.concat([directory]).join("/") + extension, false);
		}
		var dir = acc.concat([directory]).join("/");
		mkdirMutex.acquire();
		try {
			if (!FileSystem.exists(removeTrailingSlash(dir))) FileSystem.createDirectory(dir);
		} catch (error:haxe.Exception) {
			mkdirMutex.release();
			throw error;
		}
		mkdirMutex.release();
		acc.push(directory);
		return createFile(binary, extension, acc, parts);
	}

	public static function mkdirRecursive(base:String, parts:Array<String>):Void {
		for (directory in parts) {
			var path = base == "" ? directory : base == "/" ? "/" + directory : base + "/" + directory;
			var length = path.length;
			if (length > 0 && (path.charAt(length - 1) == "/" || path.charAt(length - 1) == "\\")) path = path.substr(0, length - 1);
			if (!(path == "" || (length == 2 && path.charAt(1) == ":")) && !FileSystem.exists(path)) FileSystem.createDirectory(path);
			base = path == "" ? "/" : path;
		}
	}

	public static function mkdirFromPathUnixErr(path:String):Void {
		var parts = new EReg("[\\\\/]+", "g").split(path);
		if (parts.length > 0) {
			parts.pop();
			mkdirRecursive("", parts);
		}
	}

	public static function mkdirFromPath(path:String):Void try mkdirFromPathUnixErr(path)
	catch (error:Dynamic) throw Std.string(error);

	public static function fullDotPath(pack:Array<String>, moduleName:String, typeName:String):{pack:Array<String>, name:String}
		return typeName == moduleName ? {pack: pack, name: moduleName} : {pack: pack.concat([moduleName]), name: typeName};

	public static function fileExtension(file:String):String {
		var parts = file.split(".");
		return parts.length == 0 ? "" : parts[parts.length - 1].toLowerCase();
	}

	public static function parseFilePath(path:String):FilePathData {
		if (path == "." || path == "..") return {
			directory: path,
			fileName: null,
			extension: null,
			backslash: false
		};
		var slash = path.lastIndexOf("/");
		var backslash = path.lastIndexOf("\\");
		var directory:Null<String> = null;
		var useBackslash = false;
		if (slash < backslash) {
			directory = path.substr(0, backslash);
			path = path.substr(backslash + 1);
			useBackslash = true;
		} else if (backslash < slash) {
			directory = path.substr(0, slash);
			path = path.substr(slash + 1);
		}
		if (path.length == 0) return {
			directory: directory,
			fileName: null,
			extension: null,
			backslash: useBackslash
		};
		var dot = path.lastIndexOf(".");
		return dot < 0 ? {
			directory: directory,
			fileName: path,
			extension: null,
			backslash: useBackslash
		} : {
			directory: directory,
			fileName: path.substr(0, dot),
			extension: path.substr(dot + 1),
			backslash: useBackslash
			};
	}

	public static function nameAndExtension(path:FilePathData):String {
		if (path.fileName == null) throw "File path has no name";
		return path.extension == null ? path.fileName : path.fileName + "." + path.extension;
	}
}

class UniqueKey {
	public static function create(path:String):String return Path.isWindows ? Path.getFullPath(path).toLowerCase() : Path.getFullPath(path);

	public static function createLazy(path:String):LazyUniqueKey return {path: path, key: null};

	public static function lazyKey(value:LazyUniqueKey):String {
		if (value.key == null) value.key = create(value.path);
		return value.key;
	}

	public static function lazyPath(value:LazyUniqueKey):String return value.path;

	public static function startsWith(subject:String, start:String):Bool return StringTools.startsWith(subject, start);

	public static function toString(key:String):String return key;
}

@:structInit class LazyUniqueKey {
	public var path:String;
	public var key:Null<String>;

	public inline function new(path:String, key:Null<String>) {
		this.path = path;
		this.key = key;
	}

	public inline function clone():LazyUniqueKey return new LazyUniqueKey(path, key);
}

class FilePath {
	public static function create(directory:Null<String>, fileName:Null<String>, extension:Null<String>,
			backslash:Bool):FilePathData return {
			directory: directory,
			fileName: fileName,
			extension: extension,
			backslash: backslash
		};

	public static function parse(path:String):FilePathData return Path.parseFilePath(path);

	public static function nameAndExtension(path:FilePathData):String return Path.nameAndExtension(path);
}
