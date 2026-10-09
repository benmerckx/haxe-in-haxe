package core;

// Port of haxe/src/core/numeric.ml.
class Numeric {
	public static function validFloatLexeme(value:String):String {
		var index = 0;
		while (index < value.length) {
			var code = value.charCodeAt(index);
			if (!((code >= "0".code && code <= "9".code) || code == "-".code)) return value;
			index++;
		}
		return value + ".";
	}

	/** OCaml Stdlib `string_of_float`: `valid_float_lexeme (sprintf "%.12g" f)`. **/
	public static function stringOfFloat(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0.0 ? "-inf" : "inf";
		return validFloatLexeme(core.ds.OcamlPrintf.formatG(12, f));
	}

	/** numeric.ml `float_repres`: shortest of %.12g/%.15g/%.18g that reads back as `f`. **/
	public static function floatRepres(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f < 0.0 ? "neg_infinity" : "infinity";
		var floatVal = {
			var s1 = core.ds.OcamlPrintf.formatG(12, f);
			if (f == Std.parseFloat(s1)) s1
			else {
				var s2 = core.ds.OcamlPrintf.formatG(15, f);
				if (f == Std.parseFloat(s2)) s2
				else core.ds.OcamlPrintf.formatG(18, f);
			}
		}
		return validFloatLexeme(floatVal);
	}

	public static function isWhitespace(code:Int):Bool {
		return code > 8 && code < 14;
	}

	public static function parseFloat(value:String):Float {
		var start = 0;
		var index = 0;
		while (index < value.length) {
			var code = value.charCodeAt(index);
			if (start == index && (code == " ".code || isWhitespace(code))) {
				start++;
				index++;
			} else if ((code >= "0".code && code <= "9".code)
				|| code == "-".code
				|| code == "+".code
				|| code == "e".code
				|| code == "E".code
				|| code == ".".code) {
				index++;
			} else {
				break;
			}
		}
		return parseFloatToken(value.substr(start, index - start));
	}

	public static function parseInt(value:String):Int {
		function loopHex(sp:Int, i:Int):String {
			while (i < value.length) {
				var c = value.charCodeAt(i);
				if ((c >= "0".code && c <= "9".code) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code)) i++
				else break;
			}
			return value.substr(sp, i - sp);
		}
		function loopDec(sp:Int, i:Int):String {
			while (i < value.length) {
				var c = value.charCodeAt(i);
				if (c >= "0".code && c <= "9".code) i++
				else break;
			}
			return value.substr(sp, i - sp);
		}
		function handleDigits(sp:Int, i:Int):String {
			return if (i + 1 < value.length
				&& value.charCodeAt(i) == "0".code
				&& (value.charCodeAt(i + 1) == "x".code || value.charCodeAt(i + 1) == "X".code)) loopHex(sp, i + 2) else loopDec(sp, i);
		}
		function loop(sp:Int):String {
			while (true) {
				if (sp == value.length) return "";
				var c = value.charCodeAt(sp);
				if (c == " ".code) sp++;
				else if (c == "+".code) return handleDigits(sp + 1, sp + 1);
				else if (c == "-".code) return handleDigits(sp, sp + 1);
				else if (isWhitespace(c)) sp++;
				else return handleDigits(sp, sp);
			}
		}
		return core.ds.OcamlInt32.ofString(loop(0));
	}

	static function parseFloatToken(value:String):Float {
		return core.ds.OcamlFloat.ofString(value);
	}
}
