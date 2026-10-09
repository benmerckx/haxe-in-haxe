package syntax;

import core.Ast.Binop;
import core.Ast.Constant;
import core.Ast.Keyword;
import core.Ast.Token;
import core.Ast.Unop;
import core.Define;
import core.Define.DefineContext;
import core.Globals.Pos;
import syntax.Lexer.LexedToken;
import syntax.SemVer.SemVer;
import syntax.SemVer.SemVerTools;

// Port of the batch conditional-compilation path in
// haxe/src/syntax/parserEntry.ml.  It deliberately produces parser-ready
// tokens; parsing ordinary Haxe declarations remains Grammar's responsibility.
enum PreprocessorErrorMsg {
	InvalidEnd;
	InvalidElse;
	InvalidElseif;
	UnclosedConditional;
	UnsupportedOperation;
	InvalidCondition;
	Comparison(value:String);
	ErrorDirective(value:String);
	UnknownDirective(value:String);
}

class PreprocessorError {
	public final message:PreprocessorErrorMsg;
	public final pos:Pos;

	public function new(message, pos) {
		this.message = message;
		this.pos = pos;
	}
}

private enum Value {
	VNull;
	VBool(value:Bool);
	VFloat(value:Float);
	VString(value:String);
	VVersion(value:SemVer);
}

private typedef Frame = {
	var parentActive:Bool;
	var branchTaken:Bool;
	var active:Bool;
	var seenElse:Bool;
	var pos:Pos;
}

class Preprocessor {
	public static function process(source:String, defines:DefineContext, ?file = "?"):Array<LexedToken> {
		return processTokens(LegacyLexer.lex(source, file), defines);
	}

	public static function processTokens(tokens:Array<LexedToken>, defines:DefineContext):Array<LexedToken> {
		var output:Array<LexedToken> = [];
		var frames:Array<Frame> = [];
		var index = 0;
		while (index < tokens.length) {
			var item = tokens[index++];
			switch item.token {
				case Sharp("if"):
					var parentActive = isActive(frames);
					var expression = new ConditionParser(tokens, index, defines, parentActive);
					var value = expression.parse();
					index = expression.index;
					var enabled = parentActive && truthy(value);
					frames.push({
						parentActive: parentActive,
						branchTaken: enabled,
						active: enabled,
						seenElse: false,
						pos: item.pos
					});
				case Sharp("elseif"):
					var frame = last(frames, item.pos, InvalidElseif);
					if (frame.seenElse) fail(InvalidElseif, item.pos);
					var expression = new ConditionParser(tokens, index, defines, frame.parentActive && !frame.branchTaken);
					var value = expression.parse();
					index = expression.index;
					var enabled = frame.parentActive && !frame.branchTaken && truthy(value);
					frame.active = enabled;
					if (enabled) frame.branchTaken = true;
				case Sharp("else"):
					var frame = last(frames, item.pos, InvalidElse);
					if (frame.seenElse) fail(InvalidElse, item.pos);
					frame.seenElse = true;
					frame.active = frame.parentActive && !frame.branchTaken;
					frame.branchTaken = true;
				case Sharp("end"):
					if (frames.length == 0) fail(InvalidEnd, item.pos);
					frames.pop();
				case Sharp("error"):
					if (isActive(frames)) {
						if (index >= tokens.length) fail(InvalidCondition, item.pos);
						switch tokens[index++].token {
							case Const(String(value, _)): fail(ErrorDirective(value), tokens[index - 1].pos);
							case _: fail(InvalidCondition, tokens[index - 1].pos);
						}
					}
				case Sharp("line"):
					// parserEntry updates lexer line metadata here. Batch parsing only needs
					// source offsets, so consume the argument and leave positions untouched.
					if (isActive(frames) && index < tokens.length) index++;
				case Sharp(name):
					fail(UnknownDirective(name), item.pos);
				case Comment(value):
					// Preserve documentation comments for Grammar.documentation(). Other
					// comments are trivia and would otherwise appear inside expressions.
					if (isActive(frames) && StringTools.startsWith(value, "*")) output.push(item);
				case CommentLine(_):
					// Line comments are trivia.
				case Eof:
					if (frames.length != 0) fail(UnclosedConditional, frames[frames.length - 1].pos);
					output.push(item);
				case _:
					if (isActive(frames)) output.push(item);
			}
		}
		return output;
	}

	static inline function isActive(frames:Array<Frame>):Bool return frames.length == 0 || frames[frames.length - 1].active;

	static function last(frames:Array<Frame>, pos:Pos, error:PreprocessorErrorMsg):Frame {
		if (frames.length == 0) fail(error, pos);
		return frames[frames.length - 1];
	}

	public static inline function fail(message:PreprocessorErrorMsg, pos:Pos):Void throw new PreprocessorError(message, pos);

	public static function truthy(value:Value):Bool return switch value {
		case VNull | VBool(false) | VFloat(0): false;
		case _: true;
	}
}

private class ConditionParser {
	public var index:Int;

	final tokens:Array<LexedToken>;
	final defines:DefineContext;
	final shouldEvaluate:Bool;

	public function new(tokens, index, defines, shouldEvaluate) {
		this.tokens = tokens;
		this.index = index;
		this.defines = defines;
		this.shouldEvaluate = shouldEvaluate;
	}

	public function parse():Value return binary(0);

	function binary(minPrecedence:Int):Value {
		var left = unary();
		while (true) {
			var operation = binop(peek());
			if (operation == null || precedence(operation) < minPrecedence) return left;
			index++;
			var right = binary(precedence(operation) + 1);
			left = shouldEvaluate ? evaluate(operation, left, right, tokens[index - 1].pos) : VNull;
		}
	}

	function unary():Value {
		return switch peek() {
			case Unop(Not):
				index++;
				VBool(!Preprocessor.truthy(unary()));
			case POpen:
				index++;
				var value = binary(0);
				if (!matches(PClose)) invalid();
				value;
			case Const(String(value, _)):
				index++;
				VString(value);
			case Const(Int(value, _)) | Const(Float(value, _)):
				index++;
				var parsed = Std.parseFloat(value);
				if (shouldEvaluate && Math.isNaN(parsed)) invalid();
				VFloat(parsed);
			case Const(Ident(name)): identifier(name);
			case Kwd(keyword): identifier(keywordName(keyword));
			case _:
				invalid();
				VNull;
		}
	}

	function identifier(name:String):Value {
		index++;
		if (name == "version" && matches(POpen)) {
			var version = switch peek() {
				case Const(String(value, _)):
					index++;
					value;
				case _:
					invalid();
					"";
			};
			if (!matches(PClose)) invalid();
			if (!shouldEvaluate) return VString(version);
			try return VVersion(SemVerTools.parseVersion(version))
			catch (_:Dynamic) invalid();
		}
		while (matches(Dot)) {
			switch peek() {
				case Const(Ident(part)):
					index++;
					name += "." + part;
				case Kwd(keyword):
					index++;
					name += "." + keywordName(keyword);
				case _:
					invalid();
			}
		}
		return !shouldEvaluate ? VNull : Define.rawDefined(defines, name) ? VString(Define.rawDefinedValue(defines, name)) : VNull;
	}

	function matches(expected:Token):Bool {
		if (Type.enumEq(peek(), expected)) {
			index++;
			return true;
		}
		return false;
	}

	function peek():Token {
		while (index < tokens.length) switch tokens[index].token {
			case Comment(_) | CommentLine(_):
				index++;
			case _:
				break;
		}
		return index < tokens.length ? tokens[index].token : Eof;
	}

	function invalid():Void Preprocessor.fail(InvalidCondition, index < tokens.length ? tokens[index].pos : tokens[tokens.length - 1].pos);

	static function binop(token:Token):Null<Binop> return switch token {
		case Binop(op): op;
		case _: null;
	}

	static function precedence(op:Binop):Int return switch op {
		case OpBoolOr: 1;
		case OpBoolAnd: 2;
		case OpEq | OpNotEq: 3;
		case OpGt | OpGte | OpLt | OpLte: 4;
		case _: -1;
	}

	static function evaluate(op:Binop, left:Value, right:Value, pos:Pos):Value {
		return switch op {
			case OpBoolAnd: VBool(Preprocessor.truthy(left) && Preprocessor.truthy(right));
			case OpBoolOr: VBool(Preprocessor.truthy(left) || Preprocessor.truthy(right));
			case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte:
				if (left.match(VNull) || right.match(VNull)) VBool(false) else {
					var comparison = compare(left, right, pos);
					VBool(switch op {
						case OpEq: comparison == 0;
						case OpNotEq: comparison != 0;
						case OpGt: comparison > 0;
						case OpGte: comparison >= 0;
						case OpLt: comparison < 0;
						case OpLte: comparison <= 0;
						case _: false;
					});
				}
			case _:
				Preprocessor.fail(UnsupportedOperation, pos);
				VNull;
		}
	}

	static function compare(left:Value, right:Value, pos:Pos):Int {
		var pair = castValues(left, right, pos);
		return switch pair.left {
			case VBool(a): switch pair.right {
					case VBool(b): a == b ? 0 : a ? 1 : -1;
					case _: 0;
				}
			case VFloat(a): switch pair.right {
					case VFloat(b): a < b ? -1 : a > b ? 1 : 0;
					case _: 0;
				}
			case VString(a): switch pair.right {
					case VString(b): a < b ? -1 : a > b ? 1 : 0;
					case _: 0;
				}
			case VVersion(a): switch pair.right {
					case VVersion(b): SemVerTools.compareVersion(a, b);
					case _: 0;
				}
			case VNull: 1;
		};
	}

	static function castValues(left:Value, right:Value, pos:Pos):{left:Value, right:Value} {
		switch [left, right] {
			case [VString(a), VFloat(_)]:
				var n = Std.parseFloat(a);
				return Math.isNaN(n) ? {left: left, right: right} : {left: VFloat(n), right: right};
			case [VFloat(_), VString(b)]:
				var n = Std.parseFloat(b);
				return Math.isNaN(n) ? {left: left, right: right} : {left: left, right: VFloat(n)};
			case [VVersion(_), VString(b)]:
				try return {left: left, right: VVersion(SemVerTools.parseVersion(b))} catch (_:Dynamic)
					Preprocessor.fail(Comparison("Invalid version"), pos);
			case [VString(a), VVersion(_)]:
				try return {left: VVersion(SemVerTools.parseVersion(a)), right: right} catch (_:Dynamic)
					Preprocessor.fail(Comparison("Invalid version"), pos);
			case [VBool(_), VBool(_)] | [VFloat(_), VFloat(_)] | [VString(_), VString(_)] | [VVersion(_), VVersion(_)]:
				return {left: left, right: right};
			case _:
				Preprocessor.fail(Comparison("Cannot compare condition values"), pos);
		}
		return {left: left, right: right};
	}

	static function keywordName(keyword:Keyword):String return core.Ast.Ast.sKeyword(keyword);
}
