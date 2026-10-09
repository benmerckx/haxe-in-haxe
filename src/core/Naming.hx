package core;

import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TType.TVarOrigin;
import context.Common;
import syntax.Lexer;

// Mechanical translation of haxe/src/core/naming.ml. Draft; not compiled or tested.
class Naming {
	public static function displayIdentifierError(com:CommonContext, msg:String, p:Pos, ?prependMsg:String):Void {
		Common.displayError(com, (prependMsg == null ? "" : prependMsg + " ") + msg, p);
	}

	public static function checkIdentifierName(com:CommonContext, name:String, kind:String, p:Pos, ?prependMsg:String):Void {
		if (StringTools.startsWith(name, "$"))
			displayIdentifierError(com, StringHelper.capitalize(kind) + ' names starting with a dollar are not allowed: "' + name + '"',
				p, prependMsg);
		else if (!Lexer.isValidIdentifier(name))
			displayIdentifierError(com, '"' + StringHelper.sEscape(name) + '" is not a valid ' + kind + ' name.', p, prependMsg);
	}

	public static function checkFieldName(com:CommonContext, name:String, p:Pos):Void {
		if (name != "new") checkIdentifierName(com, name, "field", p);
	}

	public static function checkUppercaseIdentifierName(com:CommonContext, name:String, kind:String, p:Pos, ?prependMsg:String):Void {
		if (name.length == 0) displayIdentifierError(com, StringHelper.capitalize(kind) + " name must not be empty.", p, prependMsg);
		else if (Ast.isLowerIdent(name)) displayIdentifierError(com,
			StringHelper.capitalize(kind) + ' name should start with an uppercase letter: "' + name + '"', p, prependMsg);
		else checkIdentifierName(com, name, kind, p, prependMsg);
	}

	public static function checkModulePath(com:CommonContext, path:GlobalTypePath, p:Pos):Void {
		var fullPath = StringHelper.sEscape(path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name);
		checkUppercaseIdentifierName(com, path.name, "module", p, 'Module "' + fullPath + '" does not have a valid name.');
		try {
			for (part in path.pack) Path.checkPackageName(part);
		} catch (msg:String) {
			Common.displayErrorExt(com,
				Error.makeError(Custom('"' + StringHelper.sEscape(path.pack.join(".")) + '" is not a valid package name:'), p,
					[Error.makeError(Custom(msg), p)]));
		}
	}

	public static function checkLocalVariableName(com:CommonContext, name:String, origin:TVarOrigin, p:Pos):Void {
		if (name == "this") return;
		var kind = switch origin {
			case TVOLocalVariable: "variable";
			case TVOArgument: "function argument";
			case TVOForVariable: "for variable";
			case TVOPatternVariable: "pattern variable";
			case TVOCatchVariable: "catch variable";
			case TVOLocalFunction: "function";
		};
		checkIdentifierName(com, name, kind, p);
	}
}
