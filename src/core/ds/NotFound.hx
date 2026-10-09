package core.ds;

/** Shared representation of OCaml Not_found. */
class NotFound extends haxe.Exception {
	// Thrown as a shared instance: constructing a haxe.Exception captures a stack
	// trace, and lookups throw Not_found tens of thousands of times per build.
	public static final instance = new NotFound();

	// Throw site helper: `throw X.raise()`. On HashLink the shared instance is
	// thrown with rethrow, which skips libhl's native stack capture per throw.
	public static inline function raise():NotFound {
		// -D hih-fresh-not-found: a new instance per throw, for debug stack traces
		#if hih_fresh_not_found
		return new NotFound();
		#else
		#if hl hl.Api.rethrow(instance); #end
		return instance;
		#end
	}

	public function new() super("Not_found");
}
