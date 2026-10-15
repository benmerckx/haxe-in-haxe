package hxmc.rt;

// The runtime's Haxe modules (README.md, "Runtime in Haxe"), loaded
// into every program through Std (hxmc/std/Std.hx). Their classes are
// @:keep (DCE keeps them typed); hxmc compiles only the functions a program
// calls, and the @:hxmc.export ones the runtime's C code calls.
import hxmc.rt.Str;
import hxmc.rt.Dyn;
import hxmc.rt.Arr;
import hxmc.rt.Bytes;
import hxmc.rt.Date;
import hxmc.rt.LibM;
import hxmc.rt.LibMTrig;
import hxmc.rt.LibMArc;
// WebAssembly's runtime (@:hxmc.wasm: what C provides on the native
// targets), typed for a program built for it only
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.wasm.Heap;
import hxmc.rt.wasm.Gc;
import hxmc.rt.wasm.Boxes;
import hxmc.rt.wasm.Names;
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.FloatText;
import hxmc.rt.wasm.Libc;
import hxmc.rt.wasm.Threads;
import hxmc.rt.wasm.NoSslUv;
#end

class Runtime {}
