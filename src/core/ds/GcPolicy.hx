package core.ds;

/**
	HashLink only: libhl starts a full (non-generational) mark after
	allocating 20% of the heap, so a heap full of typed modules is marked
	over and over. Like OCaml's space_overhead, collect instead when the
	allocation since the last major exceeds `factor` times the heap size seen
	after it (on HL/C, a multiple of the live data instead). Elsewhere `tick`
	is a no-op.
**/
class GcPolicy {
	#if hl
	static var counter = 0;
	static var enabled = false;
	static var allocatedAtMajor = 0.;
	static var heapAtMajor = 0.;
	#if hlc
	// HL/C links the patched libhl (bench/libhl-allocator.patch), whose
	// currentMemory after a collection is the live data rather than page memory.
	// Fragmentation keeps page memory well above the live data, and growing the
	// threshold with it made the heap size jump between runs on small changes.
	static var factor = 5.0;
	#else
	static var factor = 1.0;
	#end

	public static function init():Void {
		var v = Sys.getEnv("HAXE_IN_HAXE_GC_FACTOR");
		if (v != null) factor = Std.parseFloat(v);
		if (factor <= 0) return; // 0 keeps libhl's own policy
		enabled = true;
		hl.Gc.enable(false);
		var s = hl.Gc.stats();
		allocatedAtMajor = s.totalAllocated;
		heapAtMajor = s.currentMemory;
	}

	public static inline function tick():Void {
		if (++counter & 0xFFF == 0 && enabled) check();
	}

	static function check():Void {
		var s = hl.Gc.stats();
		// At least 64 MB between collections: on small heaps, faulting in fresh
		// pages costs more than marking.
		if (s.totalAllocated - allocatedAtMajor > Math.max(factor * heapAtMajor, 64 * 1024 * 1024)) {
			hl.Gc.major();
			s = hl.Gc.stats();
			allocatedAtMajor = s.totalAllocated;
			heapAtMajor = s.currentMemory;
		}
	}
	#else
	public static inline function init():Void {}

	public static inline function tick():Void {}
	#end
}
