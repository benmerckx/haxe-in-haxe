package coro;

import core.Error;
import core.Ast;
import core.data.DataReaderApi;
import core.TFunctions.NotFound;
import core.data.MetaDataApi;

// haxe/src/coro/coroScopeConfig.ml — mechanical draft; not compile-validated.
@:structInit class CoroScopeConfigData {
	public var restrictedSuspension:Bool;

	public inline function new(restrictedSuspension:Bool) {
		this.restrictedSuspension = restrictedSuspension;
	}

	public inline function clone():CoroScopeConfigData return new CoroScopeConfigData(restrictedSuspension);
}

class CoroScopeConfigReader<Data> {
	var api:DataReaderApi<Data>;

	public function new(api:DataReaderApi<Data>) this.api = api;

	public function readCoroScopeConfig(config:CoroScopeConfigData, data:Data):Void api.readOptional(data, function(data) {
		for (field in api.readObject(data)) switch field.name {
			case "restrictedSuspension":
				config.restrictedSuspension = api.readBool(field.value);
			case s:
				Error.raiseTypingError('Unknown key for coroutine scope config: $s', core.Globals.nullPos);
		}
	});
}

class CoroScopeConfig {
	public static function create():CoroScopeConfigData return {restrictedSuspension: false};

	public static function ofMetaList(meta:Metadata):Null<CoroScopeConfigData> {
		var entry;
		try {
			entry = core.Meta.get(core.MetaList.StrictMeta.CoroutineScope, meta);
		} catch (e:NotFound) {
			return null;
		}
		var config = create();
		new CoroScopeConfigReader(CoroConfig.metaReaderApi()).readCoroScopeConfig(config, MetaDataApi.ofMetadataEntry(entry));
		return config;
	}
}
