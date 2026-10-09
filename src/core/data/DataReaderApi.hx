package core.data;

// Mechanical translation of haxe/src/core/data/dataReaderApi.ml. Draft; not compiled or tested.
// An OCaml module signature is represented as a structural record of functions.
@:structInit class DataReaderApi<Data> {
	public var readOptional:Data->(Data->Void)->Void;
	public var readObject:Data->Array<{name:String, value:Data}>;
	public var readArray:Data->Array<Data>;
	public var readString:Data->String;
	public var readIdent:Data->String;
	public var readBool:Data->Bool;
	public var readInt:Data->Int;
	public var dataToString:Data->String;

	public inline function new(readOptional:Data->(Data->Void)->Void, readObject:Data->Array<{name:String, value:Data}>,
			readArray:Data->Array<Data>, readString:Data->String, readIdent:Data->String, readBool:Data->Bool, readInt:Data->Int,
			dataToString:Data->String) {
		this.readOptional = readOptional;
		this.readObject = readObject;
		this.readArray = readArray;
		this.readString = readString;
		this.readIdent = readIdent;
		this.readBool = readBool;
		this.readInt = readInt;
		this.dataToString = dataToString;
	}

	public inline function clone():DataReaderApi<Data> return new DataReaderApi(readOptional, readObject, readArray, readString,
		readIdent, readBool, readInt, dataToString);
}
