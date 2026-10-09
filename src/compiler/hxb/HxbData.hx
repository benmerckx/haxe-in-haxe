package compiler.hxb;

import haxe.io.BytesOutput;

// Port of haxe/src/compiler/hxb/hxbData.ml.
enum ChunkKind {
	STR;
	DOC;
	MDF;
	MTF;
	IMP;
	CLR;
	ENR;
	ABR;
	TDR;
	OFR;
	OFD;
	OBD;
	CLD;
	END;
	ABD;
	TDD;
	EOT;
	EFR;
	CFR;
	CFD;
	EFD;
	AFD;
	EOF;
	EXD;
	EOM;
}

typedef CachedChunk = {kind:ChunkKind, data:haxe.io.Bytes};
typedef CachedChunks = Array<CachedChunk>;

@:structInit class ModuleCache {
	public var mcPath:core.Globals.GlobalTypePath;
	public var mcId:Int;
	public var mcChunks:CachedChunks;
	public var mcExtra:core.TType.ModuleDefExtra;

	public inline function new(mcPath:core.Globals.GlobalTypePath, mcId:Int, mcChunks:CachedChunks, mcExtra:core.TType.ModuleDefExtra) {
		this.mcPath = mcPath;
		this.mcId = mcId;
		this.mcChunks = mcChunks;
		this.mcExtra = mcExtra;
	}
}

enum TypingMode {
	FullTyping;
	AllowPartialTyping;
}

class HxbFailure {
	public final message:String;

	public function new(message:String) {
		this.message = message;
	}

	public function toString():String {
		return message;
	}
}

class HxbData {
	public static inline var VERSION = 1;

	public static function stringOfChunkKind(kind:ChunkKind):String {
		return switch (kind) {
			case STR: "STR";
			case DOC: "DOC";
			case MDF: "MDF";
			case MTF: "MTF";
			case IMP: "IMP";
			case CLR: "CLR";
			case ENR: "ENR";
			case ABR: "ABR";
			case TDR: "TDR";
			case OFR: "OFR";
			case OFD: "OFD";
			case OBD: "OBD";
			case CLD: "CLD";
			case END: "END";
			case ABD: "ABD";
			case TDD: "TDD";
			case EOT: "EOT";
			case EFR: "EFR";
			case CFR: "CFR";
			case CFD: "CFD";
			case EFD: "EFD";
			case AFD: "AFD";
			case EOF: "EOF";
			case EXD: "EXD";
			case EOM: "EOM";
		};
	}

	public static function chunkKindOfString(name:String):ChunkKind {
		return switch (name) {
			case "STR": STR;
			case "DOC": DOC;
			case "MDF": MDF;
			case "MTF": MTF;
			case "IMP": IMP;
			case "CLR": CLR;
			case "ENR": ENR;
			case "ABR": ABR;
			case "TDR": TDR;
			case "OFR": OFR;
			case "OFD": OFD;
			case "OBD": OBD;
			case "CLD": CLD;
			case "END": END;
			case "ABD": ABD;
			case "TDD": TDD;
			case "EOT": EOT;
			case "EFR": EFR;
			case "CFR": CFR;
			case "CFD": CFD;
			case "EFD": EFD;
			case "AFD": AFD;
			case "EOF": EOF;
			case "EXD": EXD;
			case "EOM": EOM;
			case _: throw new HxbFailure('Invalid chunk name: $name');
		};
	}

	public static function error(message:String):Dynamic {
		Sys.stderr().writeString('[error] $message\n');
		throw new HxbFailure(message);
	}

	public static function writeHeader(output:BytesOutput):Void {
		output.writeString("hxb");
		output.writeByte(VERSION);
	}

	public static function writeChunkPrefix(kind:ChunkKind, length:Int, output:BytesOutput):Void {
		output.writeString(stringOfChunkKind(kind));
		output.writeInt32(length);
	}
}
