package coro;

import core.Error;
import core.Ast;
import core.data.DataReaderApi;
import core.TFunctions.NotFound;
import core.data.MetaDataApi;

// haxe/src/coro/coroConfig.ml — mechanical draft; not compile-validated.
@:structInit class CoroAssert {
	public var numStates:Null<Int>;
	public var numHoisted:Null<Int>;

	public inline function new(numStates:Null<Int>, numHoisted:Null<Int>) {
		this.numStates = numStates;
		this.numHoisted = numHoisted;
	}

	public inline function clone():CoroAssert return new CoroAssert(numStates, numHoisted);
}

@:structInit class CoroOutcome {
	public var noSuspend:Bool;
	public var noReturn:Bool;
	public var noThrow:Bool;

	public inline function new(noSuspend:Bool, noReturn:Bool, noThrow:Bool) {
		this.noSuspend = noSuspend;
		this.noReturn = noReturn;
		this.noThrow = noThrow;
	}

	public inline function clone():CoroOutcome return new CoroOutcome(noSuspend, noReturn, noThrow);
}

@:structInit class CoroConfigData {
	public var debug:Bool;
	public var transformed:Bool;
	public var assertConfig:Null<CoroAssert>;
	public var outcome:CoroOutcome;

	public inline function new(debug:Bool, transformed:Bool, assertConfig:Null<CoroAssert>, outcome:CoroOutcome) {
		this.debug = debug;
		this.transformed = transformed;
		this.assertConfig = assertConfig;
		this.outcome = outcome;
	}

	public inline function clone():CoroConfigData return new CoroConfigData(debug, transformed, assertConfig, outcome);
}

class CoroConfigReader<Data> {
	var api:DataReaderApi<Data>;

	public function new(api:DataReaderApi<Data>) this.api = api;

	public function readCoroAssert(config:CoroAssert, data:Data):Void {
		for (field in api.readObject(data)) switch field.name {
			case "numStates":
				config.numStates = api.readInt(field.value);
			case "numHoisted":
				config.numHoisted = api.readInt(field.value);
			case s:
				Error.raiseTypingError('Unknown key for coroutine assert config: $s', core.Globals.nullPos);
		}
	}

	public function readCoroOutcome(outcome:CoroOutcome, data:Data):Void {
		for (field in api.readObject(data)) switch field.name {
			case "noSuspend":
				outcome.noSuspend = api.readBool(field.value);
			case "noReturn":
				outcome.noReturn = api.readBool(field.value);
			case "noThrow":
				outcome.noThrow = api.readBool(field.value);
			case s:
				Error.raiseTypingError('Unknown key for coroutine outcome config: $s', core.Globals.nullPos);
		}
	}

	public function readCoroConfig(config:CoroConfigData, data:Data):Void api.readOptional(data, function(data) {
		for (field in api.readObject(data)) switch field.name {
			case "debug":
				config.debug = api.readBool(field.value);
			case "transformed":
				config.transformed = api.readBool(field.value);
			case "assert":
				var assertion:CoroAssert = {numStates: null, numHoisted: null};
				readCoroAssert(assertion, field.value);
				config.assertConfig = assertion;
			case "outcome":
				readCoroOutcome(config.outcome, field.value);
			case s:
				Error.raiseTypingError('Unknown key for coroutine config: $s', core.Globals.nullPos);
		}
	});
}

class CoroConfig {
	public static function metaReaderApi():DataReaderApi<Expr> return {
		readOptional: MetaReaderApi.readOptional,
		readObject: MetaReaderApi.readObject,
		readArray: MetaReaderApi.readArray,
		readString: MetaReaderApi.readString,
		readIdent: MetaReaderApi.readIdent,
		readBool: MetaReaderApi.readBool,
		readInt: MetaReaderApi.readInt,
		dataToString: MetaReaderApi.dataToString
	};

	public static function defaultOutcome():CoroOutcome return {noSuspend: false, noReturn: false, noThrow: false};

	public static function create():CoroConfigData return {
		debug: false,
		transformed: false,
		assertConfig: null,
		outcome: defaultOutcome()
	};

	public static function ofMetadataEntry(entry:MetadataEntry):CoroConfigData {
		var config = create();
		new CoroConfigReader(CoroConfig.metaReaderApi()).readCoroConfig(config, MetaDataApi.ofMetadataEntry(entry));
		return config;
	}

	public static function ofMetaList(meta:Metadata):CoroConfigData {
		var entry;
		try {
			entry = core.Meta.get(core.MetaList.StrictMeta.Coroutine, meta);
		} catch (e:NotFound) {
			return create();
		}
		return ofMetadataEntry(entry);
	}

	public static function getCoroutineConfig(meta:Metadata):Null<CoroConfigData> {
		var config = ofMetaList(meta);
		return config.transformed ? null : config;
	}
}
