package hxmc;

// The machine-independent IR hxmc compiles its IR (hxmc.ir) to (MirBuild): a control
// flow graph of basic blocks in SSA form over three value types. Values are
// instructions, numbered by `id` in their function (MFunc.vals). Pointers
// are I64. Calls follow the C ABI of the target (lowered by the target's
// instruction selection).
enum abstract MTy(Int) to Int {
	var I32;
	var I64;
	var F64;
	var Void;
}

enum abstract Op(Int) to Int {
	// values
	var Param; // imm: argument index
	var Const; // imm (I32), imm/imm2 (I64: low/high)
	var ConstF; // f
	var SymAddr; // sym + imm
	var TlsLoad; // sym: a runtime thread-local variable (I64)
	var TlsStore; // sym, a
	var StackAddr; // imm: frame slot (MFunc.slots)
	var Copy; // a
	var Phi; // args, in the order of the block's preds
	var Add;
	var Sub;
	var Mul;
	var And;
	var Or;
	var Xor;
	var Shl; // count masked by the width (as x86-64 and arm64 do)
	var Sar;
	var Shr;
	var Neg;
	var Not;
	var Div; // signed, machine semantics (the builder excludes /0 and MIN/-1)
	var Rem;
	var FAdd;
	var FSub;
	var FMul;
	var FDiv;
	var FNeg;
	var FSqrt;
	var FAbs;
	var Cmp; // imm: Cond; a, b; the result is an I32 0/1
	var SExt; // I32 -> I64
	var ZExt; // I32 -> I64
	var Trunc; // I64 -> I32
	var I2F; // I32 or I64 (from a's type) -> F64
	var F2I; // F64 -> I32/I64, truncating (machine semantics out of range)
	var BitsToF; // I64 -> F64
	var FToBits; // F64 -> I64
	var Select; // a ? b : c (a: I32)
	var Load; // a: base, b: index (-1 none), imm: displacement, imm2: scale, size: bytes, signed
	var Store; // a: base, b: index, c: value, imm, imm2, size
	var Call; // sym (direct) or a (indirect); args; ty: result
	// terminators
	var Jmp; // targets[0]
	var Br; // a != 0 ? targets[0] : targets[1]
	var Switch; // a; cases (values) -> targets[i], targets[last]: default
	var Ret; // a (-1: none)
	var Unreachable; // after a call that does not return
	// values (late additions)
	var Rotr; // a rotated right by the constant b (I32/I64)
	var FramePtr; // the function's frame pointer (rbp / x29: the frame record)
}

enum abstract Cond(Int) to Int from Int {
	var CEq;
	var CNe;
	var CLt;
	var CLe;
	var CGt;
	var CGe;
	var CULt;
	var CULe;
	var CUGt;
	var CUGe;
	// doubles (C semantics: an ordered comparison is false with NaN, != true)
	var FEq;
	var FNe;
	var FLt;
	var FLe;
	var FGt;
	var FGe;
}

class MIns {
	public var op:Op;
	public var ty:MTy;
	public var id:Int = -1; // value number (every instruction gets one)
	public var a:Int = -1;
	public var b:Int = -1;
	public var c:Int = -1;
	public var imm:Int = 0;
	public var imm2:Int = 0;
	public var f:Float = 0;
	public var size:Int = 0;
	public var signed:Bool = false;
	public var sym:Null<String>;
	public var args:Null<Array<Int>>;
	public var targets:Null<Array<MBlock>>;
	public var cases:Null<Array<Int>>;
	public var block:MBlock;
	public var noReturn = false; // Call
	public var returnsTwice = false; // Call (setjmp)
	public var keepsFrame = false; // Call: nothing collects meanwhile (Opt: the root slots keep their values)
	public var walkFree = false; // Call: no collection walks the stack meanwhile (the caller needs no frame record for it)
	public var variadic = -1; // Call: the first variadic argument of a C function (-1: none)
	public var argTys:Null<Array<MTy>>; // Call: the C types of the arguments (I32 stays 32-bit in the ABI)
	public var dead = false;
	public var mem = 0; // Load/Store: the memory class (Opt.MOther...)

	public function new(op, ty) {
		this.op = op;
		this.ty = ty;
	}

	public inline function isTerm():Bool
		return op == Jmp || op == Br || op == Switch || op == Ret || op == Unreachable;
}

class MBlock {
	public var id:Int;
	public var ins:Array<MIns> = []; // phis first, the terminator last
	public var preds:Array<MBlock> = [];
	public var succs:Array<MBlock> = [];
	public var sealed = false;
	public var filled = false;
	public var loopDepth = 0;
	public var cold = false; // a slow path: laid out at the end of the function
	public var order = -1; // position in the layout
	public var handler = false; // reached by a second return of setjmp
	public var mark = 0; // a pass's visit mark (MFunc.newMark)
	public var tmp = 0; // a pass's number for the block (valid where marked)

	public function new(id)
		this.id = id;

	public inline function term():Null<MIns>
		return ins.length > 0 && ins[ins.length - 1].isTerm() ? ins[ins.length - 1] : null;
}

class MFunc {
	public var name:String;
	public var params:Array<MTy> = [];
	public var ret:MTy = Void;
	public var blocks:Array<MBlock> = [];
	public var vals:Array<MIns> = [];
	public var slots:Array<{size:Int, align:Int}> = []; // frame slots (StackAddr)
	// stack maps (hxmc/rt/rt_frames.c): the slots holding references across
	// GC points (8 bytes per reference, null or valid whenever the function
	// calls: zeroed by the prologue), laid out together after the outgoing
	// arguments; an entry function's (C calls it) slot of the transition
	// record it saves (StackMaps.entry)
	public var rootSlots:Array<Int> = [];
	public var rootZero:Array<Int> = []; // per root slot: the bytes at its end the prologue zeroes
	public var entrySlot = -1;
	public var section:Null<String>; // a section of its own (DataGen's GC-able functions)
	public var blocksHere = false; // FuncInfo.blocksHere (Inline: its calls never keep the frame)
	public var inlineRecords = false; // StackMaps.record: no thunks (thunks, allocation stubs)
	public var entry:MBlock;
	var marks = 0;

	public function new(name)
		this.name = name;

	// a fresh mark: the blocks a pass sets MBlock.mark to it are visited
	public inline function newMark():Int
		return ++marks;

	// arrays of n numbers (sized once)
	public static function ints(n:Int, v:Int):Array<Int> {
		var a:Array<Int> = [];
		a.resize(n);
		if (v != 0)
			for (i in 0...n)
				a[i] = v;
		return a;
	}

	public static function iota(n:Int):Array<Int> {
		var a:Array<Int> = [];
		a.resize(n);
		for (i in 0...n)
			a[i] = i;
		return a;
	}

	public function newBlock():MBlock {
		var b = new MBlock(blocks.length);
		blocks.push(b);
		return b;
	}

	public function slot(size:Int, align:Int):Int {
		slots.push({size: size, align: align});
		return slots.length - 1;
	}

	public function dump():String {
		var s = new StringBuf();
		s.add('func $name(${params.join(", ")}) -> $ret\n');
		for (b in blocks) {
			s.add('b${b.id}: preds ${[for (p in b.preds) "b" + p.id].join(",")}${b.cold ? " cold" : ""}${b.handler ? " handler" : ""}\n');
			for (i in b.ins)
				if (!i.dead) s.add("  " + insString(i) + "\n");
		}
		return s.toString();
	}

	public static function insString(i:MIns):String {
		var s = (i.ty != Void ? 'v${i.id}:${tyName(i.ty)} = ' : '') + opName(i.op);
		var parts = [];
		if (i.op == Const) parts.push(Std.string(i.imm) + (i.ty == I64 && i.imm2 != (i.imm < 0 ? -1 : 0) ? ' hi ${i.imm2}' : ""));
		if (i.op == ConstF) parts.push(Std.string(i.f));
		if (i.op == Cmp) parts.push(condName(i.imm));
		if (i.sym != null) parts.push(i.sym + (i.imm != 0 && i.op == SymAddr ? '+${i.imm}' : ""));
		for (x in [i.a, i.b, i.c])
			if (x >= 0) parts.push('v$x');
		if (i.op == Load || i.op == Store) parts.push('disp ${i.imm} scale ${i.imm2} size ${i.size}${i.signed ? " s" : ""}');
		if (i.op == Param || i.op == StackAddr) parts.push(Std.string(i.imm));
		if (i.args != null) parts.push("(" + [for (x in i.args) 'v$x'].join(", ") + ")");
		if (i.cases != null) parts.push("[" + i.cases.join(",") + "]");
		if (i.targets != null) parts.push("-> " + [for (t in i.targets) 'b${t.id}'].join(", "));
		return s + " " + parts.join(" ");
	}

	public static function tyName(t:MTy):String
		return switch t {
			case I32: "i32";
			case I64: "i64";
			case F64: "f64";
			case Void: "void";
		};

	public static function condName(c:Int):String
		return ["eq", "ne", "lt", "le", "gt", "ge", "ult", "ule", "ugt", "uge", "feq", "fne", "flt", "fle", "fgt", "fge"][c];

	public static function opName(o:Op):String
		return [
			"param", "const", "constf", "symaddr", "tlsload", "tlsstore", "stackaddr", "copy", "phi", "add", "sub", "mul", "and", "or", "xor", "shl", "sar",
			"shr", "neg", "not", "div", "rem", "fadd", "fsub", "fmul", "fdiv", "fneg", "fsqrt", "fabs", "cmp", "sext", "zext", "trunc", "i2f", "f2i", "bitstof",
			"ftobits", "select", "load", "store", "call", "jmp", "br", "switch", "ret", "unreachable", "rotr", "frameptr"
		][(o : Int)];
}
