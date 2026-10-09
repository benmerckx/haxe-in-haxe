package core.data;

// Mechanical translation of haxe/src/core/data/dataWriterApi.ml. Draft; not compiled or tested.
@:structInit class DataWriterApi<Data> {
	public var writeOptional:Null<Data>->Data;
	public var writeObject:Array<{name:String, value:Data}>->Data;
	public var writeArray:Array<Data>->Data;
	public var writeString:String->Data;
	public var writeBool:Bool->Data;
	public var writeInt:Int->Data;

	public inline function new(writeOptional:Null<Data>->Data, writeObject:Array<{name:String, value:Data}>->Data,
			writeArray:Array<Data>->Data, writeString:String->Data, writeBool:Bool->Data, writeInt:Int->Data) {
		this.writeOptional = writeOptional;
		this.writeObject = writeObject;
		this.writeArray = writeArray;
		this.writeString = writeString;
		this.writeBool = writeBool;
		this.writeInt = writeInt;
	}

	public inline function clone():DataWriterApi<Data> return new DataWriterApi(writeOptional, writeObject, writeArray, writeString,
		writeBool, writeInt);
}
