package context;

import core.Globals.GlobalTypePath;
import core.TType;

// haxe/src/context/memory.ml
// Memory inspection measures OCaml heap objects (Objsize, Obj.reachable_words).
// Object-size support is outside the scope of this port (AGENTS.md): the size
// primitives raise instead of reporting made-up numbers.
enum MemoryRequest {
	MCache;
	MContext(sign:String);
	MModule(sign:String, path:GlobalTypePath);
}

class Memory {
	public static function clearDescendants(md:ModuleDef):Void {
		for (t in md.mTypes) switch t {
			case TClassDecl(c):
				c.clDescendants = [];
			case _:
		}
	}

	public static function moduleSign(key:String, md:ModuleDef):String return md.mExtra.mSign == key ? "" : "(" + md.mExtra.mSign + ")";

	public static function fmtSize(sz:Int):String {
		if (sz < 1024) return Std.string(sz) + " B";
		if (sz < 1024 * 1024) return Std.string(sz >> 10) + " KB";
		return core.ds.OcamlPrintf.formatG(12, Math.round(sz / (1024. * 1024.) * 10) / 10) + " MB";
	}

	/** `Common.mem_size` / `Objsize.objsize` **/
	public static function memSize(v:Dynamic):Int
		throw new core.ds.Failure("Memory statistics need object-size measurement, which is not supported by haxe-in-haxe");

	public static function size(v:Dynamic):String return fmtSize(memSize(v));
}
