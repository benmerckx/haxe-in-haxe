package haxe;

// hxc target (backend/): like runtime/hl/haxe/Exception.hx without native
// stack traces. The compiler throws exceptions for control flow.
class Exception {
	public var message(get, never):String;
	public var stack(get, never):CallStack;
	public var previous(get, never):Null<Exception>;
	public var native(get, never):Any;

	@:noCompletion var __exceptionMessage:String;
	@:noCompletion var __previousException:Null<Exception>;
	@:noCompletion var __nativeException:Any;

	// caught/thrown are called by the backend for each catch and throw of a
	// haxe.Exception (FnLower.tryStmt, TThrow), not by typed code: keep them
	// under -dce full
	@:keep static function caught(value:Any):Exception {
		var e:Null<Exception> = Std.downcast(cast value, Exception);
		return e != null ? e : new ValueException(value, null, value);
	}

	@:keep static function thrown(value:Any):Any {
		var ex:Null<Exception> = Std.downcast(cast value, Exception);
		return ex != null ? ex.native : new ValueException(value);
	}

	public function new(message:String, ?previous:Exception, ?native:Any) {
		__exceptionMessage = message;
		__previousException = previous;
		__nativeException = native != null ? native : this;
	}

	function unwrap():Any
		return __nativeException;

	public function toString():String
		return message;

	public function details():String
		return inline CallStack.exceptionToString(this);

	function get_message():String
		return __exceptionMessage;

	function get_previous():Null<Exception>
		return __previousException;

	final function get_native():Any
		return __nativeException;

	function get_stack():CallStack
		return [];
}
