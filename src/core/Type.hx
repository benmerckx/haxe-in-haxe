package core;

// haxe/src/core/type.ml — mechanical draft; not compiled or validated.
// OCaml's include facade is represented by the original TType, TFunctions,
// TPrinting, TUnification, Texpr and TOther modules and their imports at use sites.
import core.TType;
import core.TFunctions;
import core.TPrinting;
import core.TUnification;
import core.Texpr;
import core.TOther;

class Type {
	public static function initialize():Void {
		TFunctions.monomorphBindRef = TUnification.Monomorph.bind;
		TFunctions.monomorphCreateRef = TUnification.Monomorph.create;
	}

	static function __init__():Void initialize();
}
