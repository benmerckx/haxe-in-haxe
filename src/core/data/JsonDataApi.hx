package core.data;

import haxe.DynamicAccess;

// Port of haxe/src/core/data/jsonDataApi.ml.
@:structInit class JsonField {
	public var name:String;
	public var value:Dynamic;

	public inline function new(name:String, value:Dynamic) {
		this.name = name;
		this.value = value;
	}

	public inline function clone():JsonField return new JsonField(name, value);
}

class JsonReaderApi {
	public static function readOptional(data:Dynamic, callback:Dynamic->Void):Void {
		if (data != null) callback(data);
	}

	public static function readObject(data:Dynamic):Array<JsonField> {
		if (data == null || Std.isOfType(data, Array) || !Reflect.isObject(data)) fail('Expected JObject, found ${dataToString(data)}');
		var fields:DynamicAccess<Dynamic> = cast data;
		return [for (name in fields.keys()) {name: name, value: fields[name]}];
	}

	public static function readArray(data:Dynamic):Array<Dynamic> {
		if (!Std.isOfType(data, Array)) fail('Expected JArray, found ${dataToString(data)}');
		return cast data;
	}

	public static function readString(data:Dynamic):String {
		if (!Std.isOfType(data, String)) fail('Expected JString, found ${dataToString(data)}');
		return cast data;
	}

	public static function readIdent(data:Dynamic):String {
		if (!Std.isOfType(data, String)) fail('Expected identifier string, found ${dataToString(data)}');
		return cast data;
	}

	public static function readBool(data:Dynamic):Bool {
		if (!Std.isOfType(data, Bool)) fail('Expected JBool, found ${dataToString(data)}');
		return cast data;
	}

	public static function readInt(data:Dynamic):Int {
		if (!Std.isOfType(data, Int)) fail('Expected JInt, found ${dataToString(data)}');
		return cast data;
	}

	public static function dataToString(data:Dynamic):String {
		return haxe.Json.stringify(data);
	}

	static function fail(message:String):Dynamic {
		throw message;
	}
}

class JsonWriterApi {
	public static function writeOptional(data:Null<Dynamic>):Dynamic {
		return data;
	}

	public static function writeObject(fields:Array<JsonField>):Dynamic {
		var object:DynamicAccess<Dynamic> = {};
		for (field in fields) object[field.name] = field.value;
		return object;
	}

	public static function writeArray(values:Array<Dynamic>):Dynamic {
		return values;
	}

	public static function writeString(value:String):Dynamic return value;

	public static function writeBool(value:Bool):Dynamic return value;

	public static function writeInt(value:Int):Dynamic return value;
}
