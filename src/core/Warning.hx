package core;

import core.Ast;
import core.Globals.Pos;
import core.Message.WarningCode;
import core.WarningList.WarningParseFailure;
import core.Message.WarningMode;
import core.Message.WarningOption;
import syntax.Lexer;

// Mechanical translation of haxe/src/core/warning.ml. Draft; not compiled or tested.
class Warning {
	public static function parseOptionsFromLexer(lexer:Lexer, ps:Pos):Array<WarningOption> {
		inline function fail(msg:String,
				p:Pos):Dynamic return Error.raiseTypingError(msg, {pfile: p.pfile, pmin: ps.pmin + p.pmin, pmax: ps.pmin + p.pmax});
		inline function parseWarning():WarningCode {
			var token = lexer.token();
			return switch token.token {
				case Const(Ident(s)):
					try WarningList.fromString(s) catch (_:WarningParseFailure) fail('Unknown warning: $s', token.pos);
				case _: fail("Expected identifier", token.pos);
			};
		}
		var acc:Array<WarningOption> = [];
		while (true) {
			var token = lexer.token();
			switch token.token {
				case Binop(OpAdd):
					acc.push({woWarning: parseWarning(), woMode: WMEnable});
				case Binop(OpSub):
					acc.push({woWarning: parseWarning(), woMode: WMDisable});
				case Eof:
					return acc;
				case _:
					fail("Expected + or -", token.pos);
			}
		}
	}

	public static function parseOptions(s:String, ps:Pos):Array<WarningOption> return parseOptionsFromLexer(new Lexer(s, ps.pfile), ps);

	public static function fromMeta(ml:Metadata):Array<Array<WarningOption>> {
		var acc = [];
		for (entry in ml) if (entry.meta == Meta.HaxeWarning) for (arg in entry.exprs) {
			switch arg.expr {
				case EConst(String(s, _)):
					var p = arg.pos;
					acc.push(parseOptions(s, {pfile: p.pfile, pmin: p.pmin + 1, pmax: p.pmax - 1}));
				case _:
					Error.raiseTypingError("String expected", arg.pos);
			}
		}
		return acc;
	}

	public static function getMode(w:WarningCode, lists:Array<Array<WarningOption>>):WarningMode {
		function matches(w:WarningCode, id:WarningCode):Bool {
			if (id == w) return true;
			var parent = WarningList.warningObj(w).wParent;
			return parent != null && matches(parent, id);
		}
		for (list in lists) for (opt in list) if (matches(w, opt.woWarning)) return opt.woMode;
		return WMEnable;
	}
}
