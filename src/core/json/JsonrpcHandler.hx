package core.json;

import core.Json.JsonValue;
import core.Json.JsonField;
import core.json.JsonRpc;

// haxe/src/core/json/jsonrpc_handler.ml
enum HaxeJsonError {
	MissingField(name:String, on:String);
	BadType(desc:String, expected:String);
}

class JsonrpcHandler {
	final id:JsonValue;
	final methodName:String;
	final params:JsonValue;

	public function new(req:JsonRpcRequest) {
		id = req.id;
		methodName = req.method;
		params = req.params == null ? JNull : req.params;
	}

	public function getId():JsonValue return id;

	public function getMethodName():String return methodName;

	public function hasParams():Bool return switch params {
		case JNull: false;
		case _: true;
	};

	public function raiseHaxeJsonError<T>(e:HaxeJsonError):T return switch e {
		case MissingField(name, on): JsonRpc.raiseCustom(id, 1, 'Missing param "$name" on "$on"');
		case BadType(desc, expected): JsonRpc.raiseCustom(id, 2, 'Unexpected value for "$desc", expected $expected');
	};

	public function getField(desc:String, fl:Array<JsonField>, name:String):JsonValue {
		for (f in fl) if (f.name == name) return f.value;
		return raiseHaxeJsonError(MissingField(name, desc));
	}

	public function getString(desc:String, j:JsonValue):String return switch j {
		case JString(s): s;
		case _: raiseHaxeJsonError(BadType(desc, "String"));
	};

	public function getInt(desc:String, j:JsonValue):Int return switch j {
		case JInt(i): i;
		case _: raiseHaxeJsonError(BadType(desc, "String"));
	};

	public function getBool(desc:String, j:JsonValue):Bool return switch j {
		case JBool(b): b;
		case _: raiseHaxeJsonError(BadType(desc, "Bool"));
	};

	public function getArray(desc:String, j:JsonValue):Array<JsonValue> return switch j {
		case JArray(a): a;
		case _: raiseHaxeJsonError(BadType(desc, "Array"));
	};

	public function getObject(desc:String, j:JsonValue):Array<JsonField> return switch j {
		case JObject(o): o;
		case _: raiseHaxeJsonError(BadType(desc, "Object"));
	};

	public function getStringField(desc:String, name:String, fl:Array<JsonField>):String return getString(desc, getField(desc, fl, name));

	public function getIntField(desc:String, name:String, fl:Array<JsonField>):Int return getInt(desc, getField(desc, fl, name));

	public function getBoolField(desc:String, name:String, fl:Array<JsonField>):Bool return getBool(desc, getField(desc, fl, name));

	public function getArrayField(desc:String, name:String,
			fl:Array<JsonField>):Array<JsonValue> return getArray(desc, getField(desc, fl, name));

	public function getObjectField(desc:String, name:String,
			fl:Array<JsonField>):Array<JsonField> return getObject(desc, getField(desc, fl, name));

	function getObjParams():Array<JsonField> return switch params {
		case JObject(fl): fl;
		case _: throw new core.ds.InvalidArgument("params");
	};

	public function getStringParam(name:String):String return getStringField("params", name, getObjParams());

	public function getIntParam(name:String):Int return getIntField("params", name, getObjParams());

	public function getBoolParam(name:String):Bool return getBoolField("params", name, getObjParams());

	public function getArrayParam(name:String):Array<JsonValue> return getArrayField("params", name, getObjParams());

	public function getObjectParam(name:String):Array<JsonField> return getObjectField("params", name, getObjParams());

	public function getOptParam<T>(f:Void->T, def:T):T {
		try {
			return f();
		} catch (_:JsonRpcError) {
			return def;
		}
	}

	public function getParams():JsonValue return params;
}
