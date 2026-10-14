package hxmc;

import hxmc.ir.Facts;
import hxmc.ir.Ir;

// The program-wide facts the code generator, the data and the runtime agree
// on (hxmc.ir.Facts): no-GC functions, cold sites, type indices and object
// layouts, field ids, the names and values of ids, string literal names.
@:access(hxmc.ir.Facts)
class Prep {
	public var e:Facts;
	public var p:Program;

	// the exported runtime functions (@:hxmc.export): C name -> function
	public var exports = new Map<String, FuncInfo>();

	public function new(p:Program) {
		this.p = p;
		e = new Facts(p);
		for (f in p.funcs)
			if (f.cSymbol != null) exports.set(f.cSymbol, f);
	}

	// the symbol the program's code calls runtime function n by (its Haxe
	// implementation's when exported, not the entry C calls)
	public inline function hostSym(n:String):String {
		var f = exports.get(n);
		return f == null ? n : e.cname(f);
	}

	// whether sym is one of the program's functions (stack maps: a call of
	// anything else is a call of C)
	public inline function isHaxe(sym:String):Bool
		return e.byCName.exists(sym);

	public inline function id(name:String):Int
		return e.ids.get(name);

	// Program-wide numbers are referenced by name in machine code (absolute
	// symbols DataGen defines), so a module's code
	// does not change when another module adds a type, field or global:
	// the symbol of a type index (null for the runtime's fixed ones)
	public function tySym(tindex:Int):Null<String>
		return tindex < Abi.T_FIRST ? null : e.typeNames[tindex];

	public function fidSym(name:String):String {
		e.fid(name);
		return e.fidNames.get(name);
	}

	public function sigSym(s:SigInfo):String
		return e.sigNames[s.id];

	// 8 * the rt_globals index of a reference global
	public function globalOffSym(g:Int):String
		return "GIOFF_" + e.globalNames[g].substr(3);

	// the type object (Class<T>/Enum<T> value) of a type
	public function typeObjSym(tindex:Int):String
		return "TYOBJ_" + (tindex < Abi.T_FIRST ? Std.string(tindex) : e.typeNames[tindex].substr(3));

	// a class's last descendant minus its type index (instance tests)
	public function spanSym(c:ClassInfo):String
		return "TYSPAN_" + e.typeNames[c.tindex].substr(3);

	// a field id
	public inline function fid(name:String):Int
		return e.fid(name);

	// a string literal's symbol if it has one (read-only: threads may call it)
	public function strSymIfKnown(s:String):Null<String>
		return e.strNames.get(s);

	// the symbol Facts.str gives a literal (pure: threads may call it)
	public static function strName(s:String):String
		return "S_" + haxe.crypto.Md5.encode([for (i in 0...s.length) StringTools.hex(s.charCodeAt(i))].join(",")).substr(0, 16);

	// registers a literal named by strName, as Facts.str does
	public function addStr(s:String, n:String) {
		if (e.strNames.exists(s)) return;
		if (e.strByName.exists(n)) throw "string literal hash collision: " + n;
		e.strByName.set(n, s);
		e.strNames.set(s, n);
		e.strOrder.push(s);
	}

	public function strSym(s:String):String {
		return e.str(s);
	}

	public function funcSym(f:FuncInfo):String
		return e.cname(f);

	public function selectorSym(sel:Int):String
		return e.selNames[sel];

	// rt_globals index of a reference global, or the symbol of a scalar one
	public function globalIndex(g:Int):Int
		return g;

	public function scalarGlobalSym(g:Int):String
		return e.scalarGlobal(g);

	public function sigId(s:SigInfo):Int
		return s.id;
}
