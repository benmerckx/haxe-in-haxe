package hxmc.unsafe;

import hxmc.I64;

// Raw memory intrinsics for the runtime's Haxe code (README.md,
// "Runtime in Haxe"), expanded inline by the code generator (MirBuild):
// none is a function call and none but the allocations is a GC point.
// Offsets are bytes; an object's address is its payload (the header word is
// at -8, rt.h). `name` arguments must be string literals. Internal to the
// runtime's std, not a user API.
extern class Mem {
	// the payload address of a reference, and back (no conversion)
	static function addr(o:Dynamic):Ptr;
	static function obj(p:Ptr):Dynamic;
	// the address of a symbol of the program or the runtime object (data or code)
	static function sym(name:String):Ptr;
	// the runtime's pointer-sized thread-local variables (rt_sp, rt_young_ptr, ...)
	static function tlsGet(name:String):Ptr;
	static function tlsSet(name:String, v:Ptr):Void;
	// a constant of the code generator's Abi (TYPE_SIZE, IC_SLOT, ...)
	static function abi(name:String):Int;
	// the target: os() 0 Linux, 1 macOS, 2 Windows, 3 WASI (WebAssembly); arm() true on arm64
	static function os():Int;
	static function arm():Bool;
	// the target as one number (one comparison folds: write platform tests
	// as a single comparison of os(), arm() or target(), not a && b):
	// 0 linux-x86_64, 1 linux-arm64, 2 macos-x86_64, 3 macos-arm64,
	// 4 windows-x86_64, 5 windows-arm64, 6 wasm32-wasi
	static function target():Int;
	// a frame area of `bytes` (a constant), 16-byte aligned, valid while the function runs
	static function stack(bytes:Int):Ptr;
	// unsigned comparison
	static function ult(a:I64, b:I64):Bool;
	// a * b + c rounded once, by the processor's fused multiply-add (x86-64:
	// vfmadd231sd, only where hasFma(); arm64: fmadd; not on WebAssembly)
	static function fma(a:Float, b:Float, c:Float):Float;
	// whether the processor and the OS support fma (x86-64: CPUID's FMA and
	// OSXSAVE, XGETBV's xmm and ymm state; arm64: always; WebAssembly: never)
	static function hasFma():Bool;
	// the high 64 bits of the 128-bit product of a and b, unsigned and
	// signed (x86-64: mul, imul; arm64: umulh, smulh; WebAssembly: 32-bit
	// halves)
	static function umulhi(a:I64, b:I64):I64;
	static function mulhi(a:I64, b:I64):I64;
	// the bits of a double, and the double of bits (movq, fmov; no memory)
	static function f64Bits(v:Float):I64;
	static function bitsF64(b:I64):Float;
	// calls code at fn with the C ABI (GC points: the callee may collect):
	// fn(a) and fn(a, b) returning a reference
	static function callRef1(fn:Ptr, a:Dynamic):Dynamic;
	static function callRef2(fn:Ptr, a:Dynamic, b:Ptr):Dynamic;

	// loads at p + off (8/16-bit and f32 loads widen; getI32 of 4 bytes)
	static function getI8(p:Ptr, off:Int):Int;
	static function getU8(p:Ptr, off:Int):Int;
	static function getI16(p:Ptr, off:Int):Int;
	static function getU16(p:Ptr, off:Int):Int;
	static function getI32(p:Ptr, off:Int):Int;
	static function getI64(p:Ptr, off:Int):I64;
	static function getF32(p:Ptr, off:Int):Float;
	static function getF64(p:Ptr, off:Int):Float;
	static function getPtr(p:Ptr, off:Int):Ptr;
	static function getRef(p:Ptr, off:Int):Dynamic;
	// stores at p + off (narrowing); setRef has no write barrier (young
	// objects, or the runtime's own roots), setRefBarrier stores into heap
	// object `o` at payload offset `off` through the write barrier
	static function setI8(p:Ptr, off:Int, v:Int):Void;
	static function setI16(p:Ptr, off:Int, v:Int):Void;
	static function setI32(p:Ptr, off:Int, v:Int):Void;
	static function setI64(p:Ptr, off:Int, v:I64):Void;
	static function setF32(p:Ptr, off:Int, v:Float):Void;
	static function setF64(p:Ptr, off:Int, v:Float):Void;
	static function setPtr(p:Ptr, off:Int, v:Ptr):Void;
	static function setRef(p:Ptr, off:Int, v:Dynamic):Void;
	static function setRefBarrier(o:Dynamic, off:Int, v:Dynamic):Void;
	// indexed: at p + off + i * (element size)
	static function getU8At(p:Ptr, off:Int, i:Int):Int;
	static function getU16At(p:Ptr, off:Int, i:Int):Int;
	static function getI32At(p:Ptr, off:Int, i:Int):Int;
	static function getI64At(p:Ptr, off:Int, i:Int):I64;
	static function getF64At(p:Ptr, off:Int, i:Int):Float;
	static function getRefAt(p:Ptr, off:Int, i:Int):Dynamic;
	static function setU8At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setU16At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setI32At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setI64At(p:Ptr, off:Int, i:Int, v:I64):Void;
	static function setF64At(p:Ptr, off:Int, i:Int, v:Float):Void;

	// a new heap object of `nslots` 8-byte slots with this type index and
	// kind (rt.h K_*): zeroed (alloc), or not (allocRaw: K_RAW objects
	// only, which the collector does not scan). GC points.
	static function alloc(nslots:Int, tindex:Int, kind:Int):Dynamic;
	static function allocRaw(nslots:Int, tindex:Int, kind:Int):Dynamic;
}
