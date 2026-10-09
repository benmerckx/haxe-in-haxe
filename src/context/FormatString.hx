package context;

import core.Globals;
import core.Globals.Pos;
import core.Ast;
import syntax.Parser;
import syntax.ParserEntry;
import syntax.Lexer;
import core.Error as CompilerError;

// Draft mechanical translation of haxe/src/context/formatString.ml; unvalidated.
class FormatString {
	// OCaml strings are bytes: offsets, lengths and positions count UTF-8 bytes, not characters.
	static function subBytes(b:haxe.io.Bytes, start:Int, len:Int):String {
		// HashLink's Bytes.getString stops at a NUL byte
		var out = new StringBuf();
		var i = start, end = start + len;
		while (i < end) {
			var j = i;
			while (j < end && b.get(j) != 0) j++;
			if (j > i) out.add(b.getString(i, j - i));
			if (j < end) out.addChar(0);
			i = j + 1;
		}
		return out.toString();
	}

	public static function formatString(config:syntax.Parser.ParserConfiguration, str:String, p:Pos, processExpr:ExprDef->Pos->Expr):Expr {
		var s = haxe.io.Bytes.ofString(str);
		var result:Null<Expr> = null;
		var pmin = p.pmin;
		var min = p.pmin + 1;
		inline function positioned(a:Int, b:Int):Pos return {pfile: p.pfile, pmin: a, pmax: b};
		inline function addExpr(next:Expr, len:Int):Void {
			min += len;
			var processed = processExpr(next.expr, next.pos);
			if (result == null) result = processed;
			else result = {expr: EBinop(OpAdd, result, processed), pos: Ast.punion(result.pos, next.pos)};
		}
		inline function add(next:ExprDef, len:Int):Void addExpr({expr: next, pos: positioned(min, min + len)}, len);
		inline function addSub(start:Int, pos:Int):Void {
			var len = pos - start;
			if (len > 0 || result == null) add(EConst(String(subBytes(s, start, len), SDoubleQuotes)), len);
		}
		var len = s.length;
		inline function identStart(c:Int):Bool return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code;
		var parse:Int->Int->Void = null;
		inline function parseGroup(start:Int, pos:Int, gopen:Int, gclose:Int, gname:String):Void {
			addSub(start, pos - 1);
			var groups = [pos];
			var send = pos + 1;
			while (true) {
				if (send == len) {
					if (groups.length == 0) throw "formatString: impossible empty group stack";
					var g = groups[0];
					CompilerError.raiseTypingError("Unclosed " + gname, positioned(pmin + g + 1, pmin + g + 2));
				}
				var c = s.get(send);
				if (c == gopen) groups.unshift(send);
				else if (c == gclose) {
					groups.shift();
					if (groups.length == 0) break;
				}
				send++;
			}
			var slen = send - pos - 1;
			var scode = subBytes(s, pos + 1, slen);
			min += 2;
			var ep = positioned(pmin + pos + 2, pmin + send + 1);
			function error(msg:String, pos:Pos):Dynamic {
				return Lexer.stringIsWhitespace(scode) ? CompilerError.raiseTypingError("Expression cannot be empty",
					ep) : CompilerError.raiseTypingError(msg, pos);
			}
			var expr = switch ParserEntry.parseExprString(config, scode, ep, error, true) {
				case ParseSuccess(data, _): data;
				case ParseError(_, err, _): error(Parser.errorMsg(err.message), err.pos);
			};
			addExpr(expr, slen);
			min++;
			parse(send + 1, send + 1);
		}
		parse = function(start:Int, pos:Int):Void {
			if (pos == len) {
				addSub(start, pos);
				return;
			}
			var c = s.get(pos++);
			if (c == "'".code) {
				pmin++;
				min++;
			}
			if (c != "$".code || pos == len) {
				parse(start, pos);
				return;
			}
			var next = s.get(pos);
			if (next == "$".code) {
				addSub(start, pos);
				parse(pos + 1, pos + 1);
			} else if (next == "{".code) {
				parseGroup(start, pos, "{".code, "}".code, "brace");
			} else if (identStart(next)) {
				addSub(start, pos - 1);
				min++;
				var end = pos + 1;
				while (end < len) {
					var c = s.get(end);
					if (!identStart(c) && !(c >= "0".code && c <= "9".code)) break;
					end++;
				}
				var length = end - pos;
				add(EConst(Ident(subBytes(s, pos, length))), length);
				parse(pos + length, pos + length);
			} else parse(start, pos);
		};
		parse(0, 0);
		if (result == null) throw "formatString: missing expression";
		return result;
	}
}
