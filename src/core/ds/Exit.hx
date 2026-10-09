package core.ds;

/** Shared exception used for the OCaml Exit control flow. */
class Exit extends haxe.Exception {
	// Shared instance; see NotFound.
	public static final instance = new Exit();

	// Throw site helper: `throw X.raise()`. On HashLink the shared instance is
	// thrown with rethrow, which skips libhl's native stack capture per throw.
	public static inline function raise():Exit {
		#if hl hl.Api.rethrow(instance); #end
		return instance;
	}

	// Printexc.to_string Exit
	public function new() super("Stdlib.Exit");
}
