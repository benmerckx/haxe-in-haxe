package core.ds;

import core.Error.CompilerError;
import core.Error.TypingError;
import core.TUnification.UnifyError;
import core.TUnification.Unify_error;
import context.Typecore.WithTypeError;
import haxe.ds.Option;

/** Typed extractors retain OCaml exception-match branch order in Haxe switches. */
class ExceptionTools {
	public static function typing(value:Dynamic):Option<CompilerError> return Std.isOfType(value,
		TypingError) ? Some((cast value : TypingError).error) : None;

	public static function unification(value:Dynamic):Option<Array<UnifyError>> return Std.isOfType(value,
		Unify_error) ? Some((cast value : Unify_error).errors) : None;

	public static function withType(value:Dynamic):Option<CompilerError> return Std.isOfType(value,
		WithTypeError) ? Some((cast value : WithTypeError).error) : None;
}
