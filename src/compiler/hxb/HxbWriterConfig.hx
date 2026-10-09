package compiler.hxb;

import haxe.DynamicAccess;

// Port of haxe/src/compiler/hxb/hxbWriterConfig.ml.
class WriterTargetConfig {
	public var generate:Bool = true;
	public var exclude:Array<Array<String>> = [];
	public var include:Array<Array<String>> = [];
	public var hxbVersion:Int = HxbData.VERSION;
	public var generateDocumentation:Bool = true;

	public function new() {}
}

class HxbWriterConfig {
	public var archivePath:String = "";
	public var targetConfig:WriterTargetConfig = new WriterTargetConfig();
	public var macroConfig:WriterTargetConfig = new WriterTargetConfig();

	public function new() {}

	public static function parse(config:HxbWriterConfig, input:String):Void {
		processJson(config, haxe.Json.parse(input));
	}

	public static function processArgument(file:String):HxbWriterConfig {
		var config = new HxbWriterConfig();
		if (extension(file) == "json") {
			var content:String;
			try content = sys.io.File.getContent(file)
			catch (error:Dynamic) throw 'Could not open file $file: ${Std.string(error)}';
			parse(config, content);
		} else {
			config.archivePath = file;
		}
		return config;
	}

	public static function toJson(config:HxbWriterConfig):String {
		return haxe.Json.stringify({
			archivePath: config.archivePath,
			targetConfig: targetToJson(config.targetConfig),
			macroConfig: targetToJson(config.macroConfig)
		});
	}

	static function processJson(config:HxbWriterConfig, data:Dynamic):Void {
		if (data == null) return;
		var fields:DynamicAccess<Dynamic> = cast data;
		for (name in fields.keys()) switch (name) {
			case "archivePath":
				config.archivePath = string(fields[name]);
			case "targetConfig":
				if (fields[name] != null) readTargetConfig(config.targetConfig, fields[name]);
			case "macroConfig":
				if (fields[name] != null) readTargetConfig(config.macroConfig, fields[name]);
			case _:
				fail('Unknown key for writer config: $name');
		}
	}

	static function readTargetConfig(config:WriterTargetConfig, data:Dynamic):Void {
		var fields:DynamicAccess<Dynamic> = cast data;
		for (name in fields.keys()) switch (name) {
			case "generate":
				config.generate = bool(fields[name]);
			case "exclude":
				if (fields[name] != null) config.exclude = paths(fields[name]);
			case "include":
				if (fields[name] != null) config.include = paths(fields[name]);
			case "hxbVersion":
				config.hxbVersion = integer(fields[name]);
			case "generateDocumentation":
				config.generateDocumentation = bool(fields[name]);
			case _:
				fail('Unknown key for target config: $name');
		}
	}

	static function targetToJson(config:WriterTargetConfig):Dynamic {
		return {
			generate: config.generate,
			exclude: config.exclude.map(function(path) return path.join(".")),
			include: config.include.map(function(path) return path.join(".")),
			hxbVersion: config.hxbVersion,
			generateDocumentation: config.generateDocumentation
		};
	}

	static function paths(data:Dynamic):Array<Array<String>> {
		if (!Std.isOfType(data, Array)) fail("Expected array");
		return (cast(data, Array<Dynamic>)).map(function(path) return string(path).split("."));
	}

	static function string(value:Dynamic):String {
		if (!Std.isOfType(value, String)) fail("Expected string");
		return cast value;
	}

	static function bool(value:Dynamic):Bool {
		if (!Std.isOfType(value, Bool)) fail("Expected boolean");
		return cast value;
	}

	static function integer(value:Dynamic):Int {
		if (!Std.isOfType(value, Int)) fail("Expected integer");
		return cast value;
	}

	static function extension(file:String):String {
		var dot = file.lastIndexOf(".");
		return dot < 0 ? "" : file.substr(dot + 1);
	}

	static function fail(message:String):Dynamic {
		throw message;
	}
}
