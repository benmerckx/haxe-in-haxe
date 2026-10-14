package hxmc;

import hxmc.Lir;
import hxmc.Mir;

// A target architecture's code generator: instruction selection (which
// also tells the register allocator about its instructions) and emission.
interface Selector extends Regalloc.RegTarget {
	function select(mf:MFunc, layout:Array<MBlock>):LFunc;
}

interface Emitter {
	function func(f:LFunc, usedRegs:Array<Bool>, global:Bool):Obj.Symbol;
	// where the next functions go: their own section (`name`, Link's dead
	// code removal may drop it), or the object's .text (null)
	function useSection(name:Null<String>):Void;
}

class Target {
	public static function selector(abi:Abi):Selector
		return abi.arm ? new hxmc.a64.Isel(abi) : new hxmc.x64.Isel(abi);

	public static function emitter(abi:Abi, obj:Obj):Emitter
		return abi.arm ? new hxmc.a64.Emit(obj, abi.os == "windows") : new hxmc.x64.Emit(obj, abi.os == "windows");
}
