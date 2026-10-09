package syntax;

import core.Ast.Binop;
import core.Ast.Keyword;
import core.Ast.StringLiteralKind;
import core.Ast.Token;
import core.Ast.Unop;
import core.Globals.Pos;

// Port of the batch-tokenization portion of haxe/src/syntax/lexer.ml.
// XML lexing and display-specific parser entry points remain with the parser.
enum LexerErrorMsg {
	InvalidCharacter(code:Int);
	UnterminatedString;
	UnterminatedRegexp;
	UnclosedComment;
	InvalidEscape(value:String, ?msg:String);
	UnclosedCode;
	InvalidRegexpOption;
	UnterminatedMarkup;
}

class LexerError {
	public final message:LexerErrorMsg;
	public final pos:Pos;

	public function new(message, pos) {
		this.message = message;
		this.pos = pos;
	}
}

@:structInit class LexedToken {
	public var token:Token;
	public var pos:Pos;

	public inline function new(token:Token, pos:Pos) {
		this.token = token;
		this.pos = pos;
	}

	public inline function clone():LexedToken return new LexedToken(token, pos);
}

// llines is kept in ascending order (upstream's newest-first list, without O(n) prepends).
@:structInit class LexerFile {
	public var lfile:String;
	public var lline:Int;
	public var lmaxline:Int;
	public var llines:Array<{offset:Int, line:Int}>;
	public var lalines:Array<{offset:Int, line:Int}>;
	public var llast:Int;
	public var llastindex:Int;

	public inline function new(lfile:String, lline:Int, lmaxline:Int, llines:Array<{offset:Int, line:Int}>,
			lalines:Array<{offset:Int, line:Int}>, llast:Int, llastindex:Int) {
		this.lfile = lfile;
		this.lline = lline;
		this.lmaxline = lmaxline;
		this.llines = llines;
		this.lalines = lalines;
		this.llast = llast;
		this.llastindex = llastindex;
	}

	public inline function clone():LexerFile return new LexerFile(lfile, lline, lmaxline, llines, lalines, llast, llastindex);
}

@:structInit class LexerContext {
	public var file:LexerFile;
	public var buf:StringBuf;

	public inline function new(file:LexerFile, buf:StringBuf) {
		this.file = file;
		this.buf = buf;
	}

	public inline function clone():LexerContext return new LexerContext(file, buf);
}

class Lexer {
	public static function isWhitespace(value:String):Bool return value == " " || value == "\n" || value == "\r" || value == "\t";

	public static function stringIsWhitespace(value:String):Bool {
		for (i in 0...value.length) if (" \n\r\t".indexOf(value.charAt(i)) < 0) return false;
		return true;
	}

	static var allFiles = new haxe.ds.StringMap<LexerFile>();

	public static function createFileCtx(file:String):LexerContext {
		var ctx = createTempCtx(file);
		allFiles.set(file, ctx.file);
		return ctx;
	}

	public static function resolveFileContentPos(file:String, content:String):LexerFile {
		var f = createTempCtx(file).file;
		// Upstream consumes UTF-8 bytes, but stores character offsets.
		var bytes = haxe.io.Bytes.ofString(content), i = 0, p = 0;
		while (i < bytes.length) {
			var c = bytes.get(i++), inc = 1;
			if (c == 10 || c == 13) {
				if (c == 13) {
					i++;
					inc = 2;
				}
				f.lline++;
				f.llines.push({offset: p + inc, line: f.lline});
			} else if (c >= 0xC0) i += c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
			p += inc;
		}
		return f;
	}

	public static function findFile(file:String):LexerFile {
		var f = allFiles.get(file);
		if (f == null) {
			try f = resolveFileContentPos(file, sys.io.File.getContent(file))
			catch (_:Dynamic) f = createTempCtx(file).file;
			allFiles.set(file, f);
		}
		return f;
	}

	public static function findLine(p:Int, f:LexerFile):{line:Int, column:Int} {
		if (f.lmaxline != f.lline) {
			f.lmaxline = f.lline;
			f.lalines = f.llines.copy();
			f.llast = 0x7FFFFFFF;
			f.llastindex = 0;
		}
		function loop(min:Int, max:Int):{line:Int, column:Int} {
			var med = (min + max) >>> 1, entry = f.lalines[med];
			if (med == min) {
				f.llast = p;
				f.llastindex = med;
				return {line: entry.line, column: p - entry.offset};
			}
			return entry.offset > p ? loop(min, med) : loop(med, max);
		}
		if (p >= f.llast) {
			var entry = f.lalines[f.llastindex],
				next = f.llastindex == f.lalines.length - 1 ? 0x7FFFFFFF : f.lalines[f.llastindex + 1].offset;
			if (p >= entry.offset && p < next) return {line: entry.line, column: p - entry.offset};
		}
		return loop(0, f.lalines.length);
	}

	public static function findPos(p:Pos):{line:Int, column:Int}
		return findLine(p.pmin, findFile(p.pfile));

	public static function getErrorLine(p:Pos):Int return findPos(p).line;

	public static function getPosCoords(p:Pos):{
		lineStart:Int,
		columnStart:Int,
		lineEnd:Int,
		columnEnd:Int
	} {
		var file = findFile(p.pfile),
			a = findLine(p.pmin, file),
			b = findLine(p.pmax, file);
		return {
			lineStart: a.line,
			columnStart: a.column + 1,
			lineEnd: b.line,
			columnEnd: b.column + 1
		};
	}

	public static function getErrorPos(printer:String->Int->String, p:Pos):String {
		if (p.pmin == -1) return "(unknown)";
		var c = getPosCoords(p), prefix = printer(p.pfile, c.lineStart);
		return c.lineStart == c.lineEnd ? prefix
			+ " character"
			+ (c.columnStart == c.columnEnd ? " " + c.columnStart : "s " + c.columnStart + "-" + c.columnEnd) : prefix
			+ " lines "
			+ c.lineStart
			+ "-"
			+ c.lineEnd;
	}

	public static function isValidIdentifier(value:String):Bool {
		if (value.length == 0) return false;
		for (i in 0...value.length) {
			var c = StringTools.fastCodeAt(value, i);
			if (!((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code)
				&& !(i > 0 && isDigitC(c))) return false;
		}
		return switch keyword(value) {
			case Const(Ident(_)): true;
			case _: false;
		};
	}

	public static function createTempCtx(file:String):LexerContext return {
		file: {
			lfile: file,
			lline: 1,
			lmaxline: 1,
			llines: [{offset: 0, line: 1}],
			lalines: [{offset: 0, line: 1}],
			llast: 0x7FFFFFFF,
			llastindex: 0
		},
		buf: new StringBuf()
	};

	public static function lexbufFromUtf8String(source:String):Lexer return new Lexer(source);

	public static function reset(ctx:LexerContext):Void ctx.buf = new StringBuf();

	public static function contents(ctx:LexerContext):String return ctx.buf.toString();

	public static function skipHeader(code:Lexer):Void {
		while (true) {
			if (code.current() == String.fromCharCode(0xFEFF)) code.index++;
			else if (code.starts("#!")) while (!code.eof() && code.current() != "\n" && code.current() != "\r") code.index++;
			else return;
		}
	}

	static function updateLines(ctx:LexerContext, code:Lexer, start:Int):Void {
		var i = start;
		var src = code.source, n = src.length;
		while (i < code.index) {
			var c = StringTools.fastCodeAt(src, i++);
			if (c == "\r".code && i < n && StringTools.fastCodeAt(src, i) == "\n".code) i++;
			if (c == "\r".code || c == "\n".code) {
				ctx.file.lline++;
				ctx.file.llines.push({offset: code.cp(i), line: ctx.file.lline});
			}
		}
	}

	public static function readToken(ctx:LexerContext, code:Lexer):LexedToken {
		code.file = ctx.file.lfile;
		var start = code.index;
		// upstream records each newline as it is lexed, so a lexer error sees the lines before it
		var result = try code.token() catch (e:LexerError) {
			updateLines(ctx, code, start);
			throw e;
		};
		updateLines(ctx, code, start);
		return result;
	}

	public static function sharpToken(ctx:LexerContext, code:Lexer):LexedToken {
		code.file = ctx.file.lfile;
		var start = code.index;
		var result = code.sharpTokenRaw();
		updateLines(ctx, code, start);
		return result;
	}

	static function xmlNameStart(code:Int):Bool return code == 36 || code == 58 || code == 95 || (code >= 65 && code <= 90)
		|| (code >= 97 && code <= 122) || (code >= 0xC0 && code <= 0xD6) || (code >= 0xD8 && code <= 0xF6)
		|| (code >= 0xF8 && code <= 0x2FF) || (code >= 0x370 && code <= 0x37D) || (code >= 0x37F && code <= 0x1FFF)
		|| (code >= 0x200C && code <= 0x200D) || (code >= 0x2070 && code <= 0x218F) || (code >= 0x2C00 && code <= 0x2FEF)
		|| (code >= 0x3001 && code <= 0xD7FF) || (code >= 0xF900 && code <= 0xFDCF) || (code >= 0xFDF0 && code <= 0xFFFD)
		|| (code >= 0x10000 && code <= 0xEFFFF);

	function xmlName():String {
		var start = index;
		if (!eof() && xmlNameStart(current().charCodeAt(0))) {
			index++;
			while (!eof()) {
				var c = current().charCodeAt(0);
				if (!(xmlNameStart(c) || c == 45 || c == 46 || (c >= 48 && c <= 57) || c == 0xB7 || (c >= 0x300 && c <= 0x36F)
					|| (c >= 0x203F && c <= 0x2040))) break;
				index++;
			}
		}
		return source.substr(start, index - start);
	}

	public static function lexXml(ctx:LexerContext, p:Int, code:Lexer):Int {
		code.file = ctx.file.lfile;
		if (p + 1 != code.cp(code.index)) code.fail(InvalidCharacter(code.current().charCodeAt(0)), code.index);
		var start = code.index, name = code.xmlName();
		ctx.buf.add("<" + name);
		var open = "<" + name, close = "</" + name + ">", depth = 0, inOpen = name != "";
		while (!code.eof()) {
			var offset = code.index;
			if (code.starts("</")) {
				code.index += 2;
				code.xmlName();
				if (code.current() == ">") {
					code.index++;
					var tag = code.source.substr(offset, code.index - offset);
					ctx.buf.add(tag);
					if (tag == close) {
						if (depth == 0) {
							updateLines(ctx, code, start);
							return code.cp(code.index);
						}
						depth--;
					}
					inOpen = false;
					continue;
				}
				code.index = offset;
			}
			if (code.current() == "<") {
				code.index++;
				code.xmlName();
				var tag = code.source.substr(offset, code.index - offset);
				ctx.buf.add(tag);
				if (tag == open) {
					depth++;
					inOpen = true;
				} else inOpen = false;
			} else if (code.starts("/>")) {
				code.index += 2;
				ctx.buf.add("/>");
				if (inOpen) depth--;
				if (depth < 0) {
					updateLines(ctx, code, start);
					return code.cp(code.index);
				}
				inOpen = false;
			} else {
				ctx.buf.add(code.current());
				code.index++;
			}
		}
		code.failPos(UnterminatedMarkup, p);
		return 0;
	}

	public static function errorMsg(error:LexerErrorMsg):String return switch error {
		case InvalidCharacter(c): c > 32 && c < 128 ? "Invalid character '" + String.fromCharCode(c) + "'" : "Invalid character 0x" + StringTools.hex(c,
				2);
		case UnterminatedString: "Unterminated string";
		case UnterminatedRegexp: "Unterminated regular expression";
		case UnclosedComment: "Unclosed comment";
		case InvalidEscape(value, null): "Invalid escape sequence \\" + value;
		case InvalidEscape(value, msg): "Invalid escape sequence \\" + value + ". " + msg;
		case UnclosedCode: "Unclosed code string";
		case InvalidRegexpOption: "Invalid regular expression option";
		case UnterminatedMarkup: "Unterminated markup literal";
	};

	// Tokenizer: translation of `token`, `sharp_token`, `comment`, `string`,
	// `string2`, `code_string` and `regexp` from haxe/src/syntax/lexer.ml.
	// Sedlex longest-match semantics are reproduced by hand: where several
	// rules apply at the current position, the longest lexeme wins and ties go
	// to the earlier rule. Positions are character offsets, as in sedlex.
	var source:String;
	var file:String;
	var index:Int;
	// Deviation from upstream (memory only): identifiers are interned per file,
	// so the AST holds one string per name instead of one per occurrence. The
	// identity of identifier strings is never observed (only position file
	// names are compared physically, core.ds.StrTools.physNeq).
	var idents:Map<String, String>;

	// UTF-16 indices of the surrogate pairs of `source` (null without any): sedlex
	// positions count code points, so a pair is one position (see `cp`).
	var pairs:Null<Array<Int>>;

	public function new(source:String, ?file = "?") {
		this.source = source;
		this.file = file;
		index = 0;
		for (i in 0...source.length) {
			var c = StringTools.fastCodeAt(source, i);
			if (c >= 0xD800 && c < 0xDC00) {
				if (pairs == null) pairs = [];
				pairs.push(i);
			}
		}
		idents = new Map();
	}

	/** The position (code point offset) of the UTF-16 index `i`. **/
	inline function cp(i:Int):Int return pairs == null ? i : cpPairs(i);

	function cpPairs(i:Int):Int {
		var lo = 0, hi = pairs.length;
		while (lo < hi) {
			var mid = (lo + hi) >>> 1;
			if (pairs[mid] < i) lo = mid + 1
			else hi = mid;
		}
		return i - lo;
	}

	function ident(s:String):String {
		var r = idents.get(s);
		if (r != null) return r;
		idents.set(s, s);
		return s;
	}

	public static function lex(source:String, ?file = "?"):Array<LexedToken> {
		var lexer = new Lexer(source, file);
		skipHeader(lexer);
		var result = [];
		while (true) {
			var value = lexer.token();
			result.push(value);
			if (value.token.match(Eof)) return result;
		}
	}

	inline function eof():Bool return index >= source.length;

	inline function current():String return eof() ? "" : source.charAt(index);

	inline function peek(offset:Int):String return index + offset >= source.length ? "" : source.charAt(index + offset);

	inline function codeAt(i:Int):Int return i < source.length ? StringTools.fastCodeAt(source, i) : -1;

	// Compares in place: called for every operator candidate of every token.
	function starts(value:String):Bool {
		var n = value.length;
		if (index + n > source.length) return false;
		for (i in 0...n) if (StringTools.fastCodeAt(source, index + i) != StringTools.fastCodeAt(value, i)) return false;
		return true;
	}

	function make(token:Token, start:Int):LexedToken return {token: token, pos: {pfile: file, pmin: cp(start), pmax: cp(index)}};

	function fail(message:LexerErrorMsg, at:Int):Dynamic return failPos(message, cp(at));

	function failPos(message:LexerErrorMsg, pos:Int):Dynamic throw new LexerError(message, {pfile: file, pmin: pos, pmax: pos});

	function skipWhitespace():Void {
		while (!eof()) {
			var c = StringTools.fastCodeAt(source, index);
			if (c != " ".code && c != "\t".code && c != "\n".code && c != "\r".code) break;
			index++;
		}
	}

	static inline function isDigitC(c:Int):Bool return c >= "0".code && c <= "9".code;

	static inline function isHexC(c:Int):Bool return isDigitC(c) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code);

	static inline function isLowerC(c:Int):Bool return c >= "a".code && c <= "z".code;

	static inline function isUpperC(c:Int):Bool return c >= "A".code && c <= "Z".code;

	static inline function isIdentPartC(c:Int):Bool return c == "_".code || isLowerC(c) || isUpperC(c) || isDigitC(c);

	static inline function isDigit(c:String):Bool return c >= "0" && c <= "9";

	static inline function isIdentStart(c:String):Bool return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_";

	static inline function isIdentPart(c:String):Bool return isIdentStart(c) || isDigit(c);

	// Regexp fragments: each returns the end index of a match starting at i, or -1.
	// integer = ('1'..'9', Star sep_digit) | '0'
	function mInteger(i:Int):Int {
		var c = codeAt(i);
		if (c == "0".code) return i + 1;
		if (c >= "1".code && c <= "9".code) return mSepDigits(i + 1, isDigitC);
		return -1;
	}

	// Star (Opt '_', digit-class)
	function mSepDigits(i:Int, cls:Int->Bool):Int {
		while (true) {
			var c = codeAt(i);
			if (cls(c)) i++;
			else if (c == "_".code && cls(codeAt(i + 1))) i += 2;
			else return i;
		}
	}

	// Plus (digit-class, Star sep_digit-class), which is digit-class (Opt '_' digit-class)*
	function mPlusDigits(i:Int, cls:Int->Bool):Int {
		if (!cls(codeAt(i))) return -1;
		return mSepDigits(i + 1, cls);
	}

	// Plus integer
	function mPlusInteger(i:Int):Int {
		var e = mInteger(i);
		if (e < 0) return -1;
		while (true) {
			var e2 = mInteger(e);
			if (e2 < 0) return e;
			e = e2;
		}
	}

	// Opt '_', (chars), Plus integer   (returns i when absent)
	function mOptSuffix(i:Int, chars:String):Int {
		var j = i;
		if (codeAt(j) == "_".code) j++;
		var c = codeAt(j);
		if (c < 0 || chars.indexOf(String.fromCharCode(c)) < 0) return i;
		var e = mPlusInteger(j + 1);
		return e < 0 ? i : e;
	}

	function mReqSuffix(i:Int, chars:String):Int {
		var e = mOptSuffix(i, chars);
		return e == i ? -1 : e;
	}

	// ('e'|'E'), Opt ('+'|'-'), Plus integer_digits, Opt float_suffix
	function mExponent(i:Int):Int {
		var c = codeAt(i);
		if (c != "e".code && c != "E".code) return -1;
		var j = i + 1;
		c = codeAt(j);
		if (c == "+".code || c == "-".code) j++;
		var e = mPlusDigits(j, isDigitC);
		if (e < 0) return -1;
		return mOptSuffix(e, "f");
	}

	function numberToken(start:Int):Null<LexedToken> {
		// candidates in rule order; kind 0 = int, 1 = float, 2 = interval
		var bestEnd = -1, bestKind = 0;
		inline function cand(end:Int, kind:Int) {
			if (end > bestEnd) {
				bestEnd = end;
				bestKind = kind;
			}
		}
		// "0x", Plus hex_digits, Opt integer_suffix
		if (starts("0x")) {
			var e = mPlusDigits(start + 2, isHexC);
			if (e >= 0) cand(mOptSuffix(e, "iu"), 0);
		}
		// "0b", Plus bin_digits, Opt integer_suffix
		if (starts("0b")) {
			var e = mPlusDigits(start + 2, function(c) return c == "0".code || c == "1".code);
			if (e >= 0) cand(mOptSuffix(e, "iu"), 0);
		}
		var ei = mInteger(start);
		if (ei >= 0) {
			// integer, Opt integer_suffix
			cand(mOptSuffix(ei, "iu"), 0);
			// integer, float_suffix
			var e = mReqSuffix(ei, "f");
			if (e >= 0) cand(e, 1);
			// integer, '.', Plus integer_digits, Opt float_suffix
			if (codeAt(ei) == ".".code) {
				var e = mPlusDigits(ei + 1, isDigitC);
				if (e >= 0) cand(mOptSuffix(e, "f"), 1);
			}
		}
		// '.', Plus integer_digits, Opt float_suffix
		if (codeAt(start) == ".".code) {
			var e = mPlusDigits(start + 1, isDigitC);
			if (e >= 0) cand(mOptSuffix(e, "f"), 1);
		}
		if (ei >= 0) {
			// integer, ('e'|'E'), Opt ('+'|'-'), Plus integer_digits, Opt float_suffix
			var e = mExponent(ei);
			if (e >= 0) cand(e, 1);
			// integer, '.', Star digit, ('e'|'E'), ...
			if (codeAt(ei) == ".".code) {
				var j = ei + 1;
				while (isDigitC(codeAt(j))) j++;
				var e = mExponent(j);
				if (e >= 0) cand(e, 1);
			}
			// integer, "..."
			if (source.substr(ei, 3) == "...") cand(ei + 3, 2);
		}
		if (bestEnd < 0) return null;
		// "." and "..." can only compete with the '.'-led float rule
		if (codeAt(start) == ".".code && source.substr(start, 3) == "..." && 3 > bestEnd - start) return null;
		index = bestEnd;
		var s = core.ds.StrTools.sub(source, start, bestEnd);
		return switch bestKind {
			case 0: make(splitIntSuffix(s), start);
			case 1: make(splitFloatSuffix(s), start);
			case _: make(IntInterval(s.substr(0, s.length - 3)), start);
		}
	}

	static function splitSuffix(s:String, isInt:Bool):{literal:String, suffix:Null<String>} {
		var pivot = -1;
		for (i in 0...s.length) {
			switch s.charAt(i) {
				case "i" | "u":
					pivot = i;
				case "f" if (!isInt):
					pivot = i;
				case _:
			}
		}
		if (pivot < 0) return {literal: s, suffix: null};
		// There might be a _ at the end of the literal because we allow _f64 and such
		var literalLength = s.charAt(pivot - 1) == "_" ? pivot - 1 : pivot;
		return {literal: s.substr(0, literalLength), suffix: s.substr(pivot)};
	}

	static function splitIntSuffix(s:String):Token {
		var r = splitSuffix(s, true);
		return Const(core.Ast.Constant.Int(r.literal, r.suffix));
	}

	static function splitFloatSuffix(s:String):Token {
		var r = splitSuffix(s, false);
		return Const(core.Ast.Constant.Float(r.literal, r.suffix));
	}

	// ident | idtype (end index or -1)
	function mIdent(i:Int):Int {
		var j = i;
		while (codeAt(j) == "_".code) j++;
		var c = codeAt(j);
		if (isLowerC(c) || isUpperC(c)) {
			j++;
			while (isIdentPartC(codeAt(j))) j++;
			return j;
		}
		if (j > i) {
			// Plus '_' | Plus '_', '0'..'9', Star (...)
			if (isDigitC(c)) {
				j++;
				while (isIdentPartC(codeAt(j))) j++;
			}
			return j;
		}
		return -1;
	}

	// `ident` only (used by '#', ident): lowercase start after underscores, or underscores.
	function mLowerIdent(i:Int):Int {
		var j = i;
		while (codeAt(j) == "_".code) j++;
		var c = codeAt(j);
		if (isLowerC(c)) {
			j++;
			while (isIdentPartC(codeAt(j))) j++;
			return j;
		}
		if (j > i) {
			if (isDigitC(c)) {
				j++;
				while (isIdentPartC(codeAt(j))) j++;
			}
			return j;
		}
		return -1;
	}

	// "??=" is spelled as a join: gencpp emits string literals unescaped and
	// "??=" is the C++ trigraph for "#".
	static final operators:Array<{text:String, token:Token}> = [
		{text: "++", token: Unop(Increment)},
		{text: "--", token: Unop(Decrement)},
		{text: "~", token: Unop(NegBits)},
		{text: "%=", token: Binop(OpAssignOp(OpMod))},
		{text: "&=", token: Binop(OpAssignOp(OpAnd))},
		{text: "|=", token: Binop(OpAssignOp(OpOr))},
		{text: "^=", token: Binop(OpAssignOp(OpXor))},
		{text: "+=", token: Binop(OpAssignOp(OpAdd))},
		{text: "-=", token: Binop(OpAssignOp(OpSub))},
		{text: "*=", token: Binop(OpAssignOp(OpMult))},
		{text: "/=", token: Binop(OpAssignOp(OpDiv))},
		{text: "<<=", token: Binop(OpAssignOp(OpShl))},
		{text: "||=", token: Binop(OpAssignOp(OpBoolOr))},
		{text: "&&=", token: Binop(OpAssignOp(OpBoolAnd))},
		{text: ["??", "="].join(""), token: Binop(OpAssignOp(OpNullCoal))},
		{text: "==", token: Binop(OpEq)},
		{text: "!=", token: Binop(OpNotEq)},
		{text: "<=", token: Binop(OpLte)},
		{text: "&&", token: Binop(OpBoolAnd)},
		{text: "||", token: Binop(OpBoolOr)},
		{text: "<<", token: Binop(OpShl)},
		{text: "->", token: Arrow},
		{text: "...", token: Spread},
		{text: "=>", token: Binop(OpArrow)},
		{text: "!", token: Unop(Not)},
		{text: "<", token: Binop(OpLt)},
		{text: ">", token: Binop(OpGt)},
		{text: ";", token: Semicolon},
		{text: ":", token: DblDot},
		{text: ",", token: Comma},
		{text: ".", token: Dot},
		{text: "?.", token: QuestionDot},
		{text: "%", token: Binop(OpMod)},
		{text: "&", token: Binop(OpAnd)},
		{text: "|", token: Binop(OpOr)},
		{text: "^", token: Binop(OpXor)},
		{text: "+", token: Binop(OpAdd)},
		{text: "*", token: Binop(OpMult)},
		{text: "/", token: Binop(OpDiv)},
		{text: "-", token: Binop(OpSub)},
		{text: "=", token: Binop(OpAssign)},
		{text: "[", token: BkOpen},
		{text: "]", token: BkClose},
		{text: "{", token: BrOpen},
		{text: "}", token: BrClose},
		{text: "(", token: POpen},
		{text: ")", token: PClose},
		{text: "??", token: Binop(OpNullCoal)},
		{text: "?", token: Question},
		{text: "@", token: At}
	];

	// Typed views of `operators`, so the per-token scan reads no structures.
	static final opTexts:Array<String> = [for (o in operators) o.text];
	static final opTokens:Array<Token> = [for (o in operators) o.token];
	static final opFirst:Array<Int> = [for (text in opTexts) StringTools.fastCodeAt(text, 0)];
	// Operator indices grouped by first character (in table order), so a token
	// only tries the operators that can match it: opByFirst[opFirstStart[c]] ...
	// opByFirst[opFirstStart[c + 1] - 1]. Flat Int arrays (an Array<Array<Int>>
	// would be read through a dynamic cast on HashLink).
	static final opFirstStart:Array<Int> = {
		var t = [0];
		for (c in 0...128) t.push(t[c] + [for (f in opFirst) if (f == c) f].length);
		t;
	};
	static final opByFirst:Array<Int> = [for (c in 0...128) for (i in 0...opFirst.length) if (opFirst[i] == c) i];

	public function token():LexedToken {
		core.ds.GcPolicy.tick();
		while (true) {
			var start = index;
			if (eof()) return make(Eof, start);
			var c = codeAt(index);
			if (c == " ".code || c == "\t".code) {
				while (codeAt(index) == " ".code || codeAt(index) == "\t".code) index++;
				continue;
			}
			if (c == "\r".code) {
				index++;
				if (codeAt(index) == "\n".code) index++;
				continue;
			}
			if (c == "\n".code) {
				index++;
				continue;
			}
			// Find the longest fixed-text operator.
			var opLen = 0, opTok:Token = null;
			if (c >= 0 && c < 128) for (k in opFirstStart[c]...opFirstStart[c + 1]) {
				var i = opByFirst[k];
				var text = opTexts[i];
				if (text.length > opLen && starts(text)) {
					opLen = text.length;
					opTok = opTokens[i];
				}
			}
			if (isDigitC(c) || c == ".".code) {
				var save = index;
				var r = numberToken(start);
				if (r != null && r.pos.pmax - cp(start) >= opLen) return r;
				index = save;
			}
			if (starts("//")) {
				var content = index + 2;
				index = content;
				while (!eof() && codeAt(index) != "\n".code && codeAt(index) != "\r".code) index++;
				return make(CommentLine(core.ds.StrTools.sub(source, content, index)), start);
			}
			if (starts("/*")) {
				var buf = new StringBuf();
				var pmax = comment(buf, start);
				return {token: Comment(buf.toString()), pos: {pfile: file, pmin: cp(start), pmax: cp(pmax)}};
			}
			if (starts("~/")) {
				index += 2;
				var buf = new StringBuf();
				var r = regexp(buf, start);
				return {
					token: Const(core.Ast.Constant.Regexp(buf.toString(), r.options)),
					pos: {pfile: file, pmin: cp(start), pmax: cp(r.pmax)}
				};
			}
			if (c == '"'.code) {
				index++;
				var buf = new StringBuf();
				var pmax = string(buf, start);
				var str = try unescape(buf.toString()) catch (e:InvalidEscapeSequence) fail(InvalidEscape(e.c, e.msg), start + e.i);
				return {token: Const(core.Ast.Constant.String(str, SDoubleQuotes)), pos: {pfile: file, pmin: cp(start), pmax: cp(pmax)}};
			}
			if (c == "'".code) {
				index++;
				var fmt:FormatContext = {buffer: new StringBuf(), quoteOpen: false, quotePmin: start};
				var buf = new StringBuf();
				var pmax = try string2(buf, fmt) catch (_:LexExit) fail(UnterminatedString, start);
				return {
					token: Const(core.Ast.Constant.String(fmt.buffer.toString(), SSingleQuotes)),
					pos: {pfile: file, pmin: cp(start), pmax: cp(pmax)}
				};
			}
			if (c == "#".code) {
				var e = mLowerIdent(index + 1);
				if (e >= 0) {
					index = e;
					return make(Sharp(core.ds.StrTools.sub(source, start + 1, e)), start);
				}
			}
			if (c == "$".code) {
				index++;
				while (isIdentPartC(codeAt(index))) index++;
				return make(Dollar(core.ds.StrTools.sub(source, start + 1, index)), start);
			}
			var ie = mIdent(index);
			if (ie >= 0 && ie - start >= opLen) {
				index = ie;
				return make(keyword(ident(core.ds.StrTools.sub(source, start, ie))), start);
			}
			if (opTok != null) {
				index += opLen;
				return make(opTok, start);
			}
			return fail(InvalidCharacter(c), start);
		}
	}

	// sharp_token (without the file context handled by the static wrapper).
	function sharpTokenRaw():LexedToken {
		while (true) {
			var start = index;
			var c = codeAt(index);
			// sharp_ident
			if (isLowerC(c) || isUpperC(c) || c == "_".code) {
				var j = index + 1;
				while (true) {
					while (isIdentPartC(codeAt(j))) j++;
					var d = codeAt(j + 1);
					if (codeAt(j) == ".".code && (isLowerC(d) || isUpperC(d) || d == "_".code)) j += 2
					else break;
				}
				index = j;
				return make(Const(core.Ast.Constant.Ident(core.ds.StrTools.sub(source, start, j))), start);
			}
			if (c == " ".code || c == "\t".code) {
				while (codeAt(index) == " ".code || codeAt(index) == "\t".code) index++;
				continue;
			}
			if (c == "\r".code) {
				index++;
				if (codeAt(index) == "\n".code) index++;
				continue;
			}
			if (c == "\n".code) {
				index++;
				continue;
			}
			if (starts("/*")) {
				comment(new StringBuf(), start);
				continue;
			}
			return token();
		}
	}

	// comment: stores the content, returns the end of "*/".
	function comment(buf:StringBuf, pmin:Int):Int {
		index += 2;
		// The text up to "*/" in one piece (not a one-character string per character).
		var end = index > source.length ? -1 : source.indexOf("*/", index);
		if (end < 0) {
			if (index < source.length) {
				buf.addSub(source, index, source.length - index);
				index = source.length;
			}
			return fail(UnclosedComment, pmin);
		}
		buf.addSub(source, index, end - index);
		index = end + 2;
		return index;
	}

	// string: stores the raw content of a double-quoted string, returns the end of the closing quote.
	function string(buf:StringBuf, pmin:Int):Int {
		while (true) {
			if (eof()) return fail(UnterminatedString, pmin);
			var c = codeAt(index);
			if (c == "\\".code) {
				var d = codeAt(index + 1);
				if (d == '"'.code || d == "\\".code) {
					buf.add(source.substr(index, 2));
					index += 2;
				} else {
					buf.add("\\");
					index++;
				}
				continue;
			}
			if (c == '"'.code) {
				index++;
				return index;
			}
			buf.add(current());
			index++;
		}
	}

	function consumeBuffer(buf:StringBuf, fmt:FormatContext, f:String->String):StringBuf {
		var s = buf.toString();
		fmt.buffer.add(f(s));
		return new StringBuf();
	}

	function unescapeFormat(fmt:FormatContext, s:String):String {
		return try unescape(s) catch (e:InvalidEscapeSequence) fail(InvalidEscape(e.c, e.msg), fmt.quotePmin + e.i);
	}

	// string2: single-quoted (format) string. Throws LexExit on eof.
	function string2(buf:StringBuf, fmt:FormatContext):Int {
		while (true) {
			if (eof()) throw new LexExit();
			var c = codeAt(index);
			if (c == "\\".code) {
				var d = codeAt(index + 1);
				if (d == "\\".code || d == "'".code || d == "$".code) {
					buf.add(source.substr(index, 2));
					index += 2;
				} else {
					buf.add("\\");
					index++;
				}
				continue;
			}
			if (c == "'".code) {
				index++;
				buf = consumeBuffer(buf, fmt, function(s) return fmt.quoteOpen ? s : unescapeFormat(fmt, s));
				if (fmt.quoteOpen) fmt.buffer.add("'");
				return index;
			}
			if (c == "$".code) {
				var d = codeAt(index + 1);
				if (d == "{".code) {
					var pmin = index;
					index += 2;
					buf = consumeBuffer(buf, fmt, function(s) return fmt.quoteOpen ? s : unescapeFormat(fmt, s));
					fmt.buffer.add("${");
					buf = try codeString(buf, fmt) catch (_:LexExit) fail(UnclosedCode, pmin);
					continue;
				}
				if (d == "$".code) {
					buf.add("$$");
					index += 2;
					continue;
				}
				buf.add("$");
				index++;
				continue;
			}
			buf.add(current());
			index++;
		}
	}

	// code_string: the `${...}` part of a format string. Returns the (reset) store buffer.
	function codeString(buf:StringBuf, fmt:FormatContext):StringBuf {
		var openBraces = 0;
		while (true) {
			if (eof()) throw new LexExit();
			var c = codeAt(index);
			if (c == "{".code) {
				buf.add("{");
				index++;
				openBraces++;
				continue;
			}
			if (c == "}".code) {
				index++;
				if (openBraces > 0) {
					buf.add("}");
					openBraces--;
					continue;
				}
				buf = consumeBuffer(buf, fmt, function(s) return s);
				fmt.buffer.add("}");
				return buf;
			}
			if (c == '"'.code) {
				var pmin = index;
				index++;
				buf.add('"');
				var inner = new StringBuf();
				try string(inner, pmin)
				catch (e:LexerError) fail(UnterminatedString, pmin);
				buf.add(inner.toString());
				buf.add('"');
				continue;
			}
			if (c == "'".code) {
				var pmin = index;
				index++;
				buf = consumeBuffer(buf, fmt, function(s) return s);
				fmt.buffer.add("'");
				var oldQuote = fmt.quoteOpen, oldPmin = fmt.quotePmin;
				fmt.quoteOpen = true;
				fmt.quotePmin = pmin;
				try string2(buf, fmt)
				catch (_:LexExit) fail(UnterminatedString, pmin);
				buf = new StringBuf();
				fmt.quoteOpen = oldQuote;
				fmt.quotePmin = oldPmin;
				continue;
			}
			if (starts("/*")) {
				var pmin = index;
				// comments are dropped from the code part
				comment(new StringBuf(), pmin);
				continue;
			}
			if (starts("//")) {
				var s = index;
				while (!eof() && codeAt(index) != "\n".code && codeAt(index) != "\r".code) index++;
				buf.add(core.ds.StrTools.sub(source, s, index));
				continue;
			}
			buf.add(current());
			index++;
		}
	}

	// regexp: stores the processed pattern; pmax is the end of the closing '/'
	// (upstream evaluates `lexeme_end` before parsing the options).
	function regexp(buf:StringBuf, pmin:Int):{options:String, pmax:Int} {
		while (true) {
			if (eof()) return fail(UnterminatedRegexp, pmin);
			var c = codeAt(index);
			if (c == "\n".code || c == "\r".code) return fail(UnterminatedRegexp, pmin);
			if (c == "\\".code) {
				var d = codeAt(index + 1);
				if (d == "/".code) {
					buf.add("/");
					index += 2;
				} else if (d == "r".code) {
					buf.add("\r");
					index += 2;
				} else if (d == "n".code) {
					buf.add("\n");
					index += 2;
				} else if (d == "t".code) {
					buf.add("\t");
					index += 2;
				} else if (d >= 0 && "\\$.*+^|{}[]()?-0123456789wWbBsSdDx".indexOf(String.fromCharCode(d)) >= 0) {
					buf.add(source.substr(index, 2));
					index += 2;
				} else if ((d == "u".code || d == "U".code) && isHexC(codeAt(index + 2)) && isHexC(codeAt(index + 3))
					&& isHexC(codeAt(index + 4)) && isHexC(codeAt(index + 5))) {
					buf.add(source.substr(index, 6));
					index += 6;
				} else if (d < 0 || d == "\n".code || d == "\r".code) {
					// '\\' followed by eof/newline: the backslash alone is stored by the Plus(Compl ..) rule? No:
					// Plus (Compl ('\\' | ...)) cannot match '\\', so this is `'\\', Compl '\\'` (newline) or die.
					return fail(InvalidCharacter("\\".code), index + 1);
				} else {
					return fail(InvalidCharacter("\\".code), index + 1);
				}
				continue;
			}
			if (c == "/".code) {
				index++;
				var pmax = index;
				var options = regexpOptions();
				return {options: options, pmax: pmax};
			}
			buf.add(current());
			index++;
		}
	}

	function regexpOptions():String {
		var options = "";
		while (true) {
			var c = codeAt(index);
			if (c == "g".code || c == "i".code || c == "m".code || c == "s".code || c == "u".code) {
				options += String.fromCharCode(c);
				index++;
			} else if (isLowerC(c)) {
				return fail(InvalidRegexpOption, index);
			} else return options;
		}
	}

	// haxe/src/core/ast.ml: unescape
	public static function unescape(s:String):String {
		var b = new StringBuf();
		var i = 0;
		var n = s.length;
		while (i < n) {
			var c = s.charAt(i);
			if (c != "\\") {
				b.add(c);
				i++;
				continue;
			}
			i++;
			if (i >= n) break;
			c = s.charAt(i);
			var fail = function(msg:Null<String>):Dynamic throw new InvalidEscapeSequence(c, i, msg);
			var inext = i + 1;
			switch c {
				case "n":
					b.add("\n");
				case "r":
					b.add("\r");
				case "t":
					b.add("\t");
				case '"' | "'" | "\\":
					b.add(c);
				case "0" | "1" | "2" | "3":
					var oct = s.substr(i, 3);
					var u = 0;
					if (oct.length != 3) fail(null);
					for (k in 0...3) {
						var d = oct.charCodeAt(k) - "0".code;
						if (d < 0 || d > 7) fail(null);
						u = u * 8 + d;
					}
					if (u > 127) fail("Values greater than \\177 are not allowed. Use \\u00"
						+ StringTools.hex(u, 2).toLowerCase()
						+ " instead.");
					b.addChar(u);
					inext += 2;
				case "x":
					var hex = s.substr(i + 1, 2);
					if (hex.length != 2 || !isHexC(hex.charCodeAt(0)) || !isHexC(hex.charCodeAt(1)))
						fail("Must be followed by a hexadecimal sequence.");
					var u = Std.parseInt("0x" + hex);
					if (u > 127) fail("Values greater than \\x7f are not allowed. Use \\u00" + hex + " instead.");
					b.addChar(u);
					inext += 2;
				case "u":
					var failNoHex = function():Dynamic return
						fail("Must be followed by a hexadecimal sequence enclosed in curly brackets.");
					var u:Int, a:Int;
					var h4 = s.substr(i + 1, 4);
					if (h4.length == 4 && isHexC(h4.charCodeAt(0)) && isHexC(h4.charCodeAt(1)) && isHexC(h4.charCodeAt(2))
						&& isHexC(h4.charCodeAt(3))) {
						u = Std.parseInt("0x" + h4);
						a = 4;
					} else {
						if (s.charAt(i + 1) != "{") failNoHex();
						var close = s.indexOf("}", i + 3);
						if (close < 0) failNoHex();
						var l = close - (i + 2);
						var hex = s.substr(i + 2, l);
						for (k in 0...hex.length) if (!isHexC(hex.charCodeAt(k))) failNoHex();
						if (hex.length == 0) failNoHex();
						u = Std.parseInt("0x" + hex);
						if (u > 0x10FFFF) fail("Maximum allowed value for unicode escape sequence is \\u{10FFFF}");
						a = l + 2;
					}
					if (u >= 0xD800 && u < 0xE000) fail("UTF-16 surrogates are not allowed in strings.");
					b.addChar(u);
					inext += a;
				case _:
					fail(null);
			}
			i = inext;
		}
		return b.toString();
	}

	static function keyword(value:String):Token return switch value {
		case "function": Kwd(Function);
		case "class": Kwd(Class);
		case "var": Kwd(Var);
		case "if": Kwd(If);
		case "else": Kwd(Else);
		case "while": Kwd(While);
		case "do": Kwd(Do);
		case "for": Kwd(For);
		case "break": Kwd(Break);
		case "continue": Kwd(Continue);
		case "return": Kwd(Return);
		case "extends": Kwd(Extends);
		case "implements": Kwd(Implements);
		case "import": Kwd(Import);
		case "switch": Kwd(Switch);
		case "case": Kwd(Case);
		case "default": Kwd(Default);
		case "static": Kwd(Static);
		case "public": Kwd(Public);
		case "private": Kwd(Private);
		case "try": Kwd(Try);
		case "catch": Kwd(Catch);
		case "new": Kwd(New);
		case "this": Kwd(This);
		case "throw": Kwd(Throw);
		case "extern": Kwd(Extern);
		case "enum": Kwd(Enum);
		case "in": Kwd(In);
		case "interface": Kwd(Interface);
		case "untyped": Kwd(Untyped);
		case "cast": Kwd(Cast);
		case "override": Kwd(Override);
		case "typedef": Kwd(Typedef);
		case "dynamic": Kwd(Dynamic);
		case "package": Kwd(Package);
		case "inline": Kwd(Inline);
		case "using": Kwd(Using);
		case "null": Kwd(Null);
		case "true": Kwd(True);
		case "false": Kwd(False);
		case "abstract": Kwd(Abstract);
		case "macro": Kwd(Macro);
		case "final": Kwd(Final);
		case "operator": Kwd(Operator);
		case "overload": Kwd(Overload);
		case _: Const(core.Ast.Constant.Ident(value));
	}
}

@:structInit class FormatContext {
	public var buffer:StringBuf;
	public var quoteOpen:Bool;
	public var quotePmin:Int;

	public inline function new(buffer:StringBuf, quoteOpen:Bool, quotePmin:Int) {
		this.buffer = buffer;
		this.quoteOpen = quoteOpen;
		this.quotePmin = quotePmin;
	}

	public inline function clone():FormatContext return new FormatContext(buffer, quoteOpen, quotePmin);
}

private class LexExit extends haxe.Exception {
	public function new() super("Exit");
}

class InvalidEscapeSequence extends haxe.Exception {
	public final c:String;
	public final i:Int;
	public final msg:Null<String>;

	public function new(c:String, i:Int, msg:Null<String>) {
		super("Invalid_escape_sequence");
		this.c = c;
		this.i = i;
		this.msg = msg;
	}
}
