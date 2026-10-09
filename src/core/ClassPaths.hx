package core;

import core.ClassPath.ClassPathScope;
import core.ClassPath.DirectoryClassPath;
import core.ClassPath.IClassPath;
import core.StringHelper;

// Port of haxe/src/core/classPaths.ml.
@:structInit class ResolvedFile {
	public var file:String;
	public var classPath:IClassPath;

	public inline function new(file:String, classPath:IClassPath) {
		this.file = file;
		this.classPath = classPath;
	}

	public inline function clone():ResolvedFile return new ResolvedFile(file, classPath);
}

enum FileResolutionSpecificity {
	SpecificityNormal;
	SpecificityPlatformSpecific;
	SpecificityCustomExtension;
	SpecificityMacroSpecific;
	SpecificityCoreApi;
}

@:structInit class FileLookup {
	public var resolvedFile:ResolvedFile;
	public var specificity:FileResolutionSpecificity;

	public inline function new(resolvedFile:ResolvedFile, specificity:FileResolutionSpecificity) {
		this.resolvedFile = resolvedFile;
		this.specificity = specificity;
	}

	public inline function clone():FileLookup return new FileLookup(resolvedFile, specificity);
}

class ClassPaths {
	public static final absoluteClassPath:IClassPath = new DirectoryClassPath("", User);

	var paths:Array<IClassPath> = [];
	var fileLookupCache:Map<String, Null<FileLookup>> = new Map();
	var customExtension:Null<String> = null;
	var platformExtension:String = "";
	var isLoadingCoreApi:Bool = false;

	public function new() {}

	public function lockContext(customExtension:Null<String>, platformName:String, coreApi:Bool):Void {
		this.customExtension = customExtension == null ? null : "." + customExtension;
		platformExtension = "." + platformName;
		isLoadingCoreApi = coreApi;
		clearCache();
	}

	public function asStringList():Array<String> {
		return paths.map(function(path) return path.path);
	}

	public function add(path:IClassPath):Void {
		paths.unshift(path);
		clearCache();
	}

	public function push(path:IClassPath):Void {
		paths.push(path);
		clearCache();
	}

	public function find(predicate:IClassPath->Bool):IClassPath {
		for (path in paths) if (predicate(path)) return path;
		throw "Not_found";
	}

	public function iter(callback:IClassPath->Void):Void {
		for (path in paths) callback(path);
	}

	public function exists(predicate:IClassPath->Bool):Bool {
		for (path in paths) if (predicate(path)) return true;
		return false;
	}

	public function filter(predicate:IClassPath->Bool):Array<IClassPath> {
		return paths.filter(predicate);
	}

	public function modify(transform:IClassPath->Array<IClassPath>, classPaths:Array<IClassPath>):Void {
		var result:Array<IClassPath> = [];
		for (path in classPaths) result = transform(path).concat(result);
		result.reverse();
		paths = result;
		clearCache();
	}

	public function modifyInplace(transform:IClassPath->Array<IClassPath>):Void {
		modify(transform, paths);
	}

	public function getStdPaths():Array<IClassPath> {
		return filter(function(path) return path.isStdPath());
	}

	public function asList():Array<IClassPath> {
		return paths;
	}

	public function clearCache():Void {
		fileLookupCache = new Map();
		for (path in paths) path.clearCache();
	}

	public function findFileNoRaise(file:String):Null<FileLookup> {
		if (fileLookupCache.exists(file)) return fileLookupCache.get(file);
		var result:Null<FileLookup> = null;
		if (isAbsolutePath(file)) {
			if (sys.FileSystem.exists(file)) result = {
				resolvedFile: {file: file, classPath: absoluteClassPath},
				specificity: SpecificityNormal
			};
		} else {
			for (path in paths) {
				var listing = path.getUncachedDirListing(file);
				if (listing == null) continue;
				result = cacheDirectory(path, listing.directory, file, listing.files);
				if (result != null) break;
			}
		}
		fileLookupCache.set(file, result);
		return result;
	}

	public function findFile(file:String):ResolvedFile {
		var result = findFileNoRaise(file);
		if (result == null) throw "Not_found";
		return result.resolvedFile;
	}

	public function relativePath(file:String):String {
		// Path.get_full_path: absolute and normalized, without resolving symbolic links.
		var fullPath = normalize(core.Path.getFullPath(file));
		var lowerFullPath = fullPath.toLowerCase();
		for (path in paths) {
			var classPath = normalize(path.path).toLowerCase();
			if (classPath.length > 0
				&& classPath.length < lowerFullPath.length
				&& lowerFullPath.substr(0, classPath.length) == classPath) return fullPath.substr(classPath.length);
		}
		return file;
	}

	public function dump():Void {
		Sys.println('Class paths for $platformExtension${isLoadingCoreApi ? " (coreApi)" : ""}:');
		for (path in paths) path.dump();
	}

	function cacheDirectory(classPath:IClassPath, directory:String, search:String, listing:Array<String>):Null<FileLookup> {
		var found:Null<FileLookup> = null;
		var searchDirectory = core.ClassPath.DirectoryClassPath.ocamlDirname(search);
		for (ownName in listing) {
			var relative = searchDirectory == "." ? ownName : searchDirectory + "/" + ownName;
			var representation:String;
			var specificity:FileResolutionSpecificity;
			if (isLoadingCoreApi) {
				representation = relative;
				specificity = SpecificityCoreApi;
			} else {
				var suffix = StringHelper.extension(relative);
				var withoutExtension = StringHelper.removeExtension(relative);
				var secondExtension = StringHelper.extension(withoutExtension);
				if (customExtension != null && secondExtension == customExtension) {
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityCustomExtension;
				} else if (platformExtension == secondExtension && secondExtension == ".macro") {
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityMacroSpecific;
				} else if (platformExtension == secondExtension) {
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityPlatformSpecific;
				} else {
					representation = relative;
					specificity = SpecificityNormal;
				}
			}
			var fullPath = directory == "." ? ownName : directory + "/" + ownName;
			var resolved:FileLookup = {resolvedFile: {file: fullPath, classPath: classPath}, specificity: specificity};
			var previous = fileLookupCache.get(representation);
			if (!fileLookupCache.exists(representation)
				|| previous == null
				|| specificityRank(previous.specificity) < specificityRank(specificity)) fileLookupCache.set(representation, resolved);
			if (representation == search
				&& (found == null || specificityRank(found.specificity) < specificityRank(specificity))) found = resolved;
		}
		return found;
	}

	static function specificityRank(specificity:FileResolutionSpecificity):Int {
		return switch (specificity) {
			case SpecificityNormal: 0;
			case SpecificityPlatformSpecific: 1;
			case SpecificityCustomExtension: 2;
			case SpecificityMacroSpecific: 3;
			case SpecificityCoreApi: 4;
		};
	}

	static function isAbsolutePath(path:String):Bool {
		return StringTools.startsWith(path, "/") || ~/^[A-Za-z]:[\\\/]/.match(path);
	}

	static function normalize(path:String):String {
		return path.split("\\").join("/");
	}
}
