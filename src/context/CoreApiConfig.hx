package context;

import core.Globals;
import core.Ast;
import core.Meta;
import core.data.MetaDataApi;
import core.Error;

// Draft mechanical translation of haxe/src/context/coreApiConfig.ml; unvalidated.
enum CoreApiCheck {
	On;
	Off;
	Implied;
}

@:structInit class CoreApiConfiguration {
	public var check:CoreApiCheck;

	public inline function new(check:CoreApiCheck) {
		this.check = check;
	}

	public inline function clone():CoreApiConfiguration return new CoreApiConfiguration(check);
}

class CoreApiConfigReader {
	final api:Dynamic;

	public function new(api:Dynamic) this.api = api;

	public function readCoreApiCheck(data:Dynamic):CoreApiCheck return switch api.readIdent(data) {
		case "On": On;
		case "Off": Off;
		case "Implied": Implied;
		case s: Error.raiseTypingError("Unknown value for check: " + s + " (expected On, Off, or Implied)", Globals.nullPos);
	};

	public function readCoreApiConfig(config:CoreApiConfiguration, data:Dynamic):Void {
		function read(data:Dynamic):Void {
			var fields:Array<Dynamic> = api.readObject(data);
			for (field in fields) switch field.name {
				case "check":
					config.check = readCoreApiCheck(field.value);
				case s:
					Error.raiseTypingError("Unknown key for coreApi config: " + s, Globals.nullPos);
			}
		}
		api.readOptional(data, read);
	}
}

class CoreApiConfig {
	public static function defaultCoreApiConfig():CoreApiConfiguration return {check: On};

	public static function ofCoreApiMetadataEntry(entry:MetadataEntry):CoreApiConfiguration {
		var config = defaultCoreApiConfig();
		new CoreApiConfigReader(MetaReaderApi).readCoreApiConfig(config, MetaDataApi.ofMetadataEntry(entry));
		return config;
	}

	public static function isImpliedCoreApiFile(filePath:String):Bool {
		var normalizedPath = filePath.split("\\").join("/");
		var marker = "/_std/";
		var index = normalizedPath.indexOf(marker);
		if (index == -1) return false;
		var afterStd = normalizedPath.substr(index + marker.length);
		return afterStd.indexOf("/") == -1 || StringTools.startsWith(afterStd, "haxe/") || StringTools.startsWith(afterStd, "sys/");
	}

	public static function getCoreApiCheck(meta:Metadata, filePath:String):CoreApiCheck {
		var entry = try Meta.get(Meta.CoreApi, meta) catch (_:core.Meta.MetaNotFound) null;
		return entry != null ? ofCoreApiMetadataEntry(entry).check : isImpliedCoreApiFile(filePath) ? Implied : Off;
	}

	public static function sCoreApiCheck(value:CoreApiCheck):String return switch value {
		case On: "On";
		case Off: "Off";
		case Implied: "Implied";
	};
}
