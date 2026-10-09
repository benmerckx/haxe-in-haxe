package core;

// Port of haxe/src/core/stringHelper.ml.
class StringHelper {
	public static function uppercase(value:String):String {
		var result = new StringBuf();
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			result.addChar(code >= 97 && code <= 122 ? code - 32 : code);
		}
		return result.toString();
	}

	public static function capitalize(value:String):String {
		if (value.length == 0) return "";
		var code = value.charCodeAt(0);
		return String.fromCharCode(code >= 97 && code <= 122 ? code - 32 : code) + value.substr(1);
	}

	public static function startsUppercaseIdentifier(value:String):Bool {
		if (value.length == 0) throw "Identifier name must not be empty";
		var index = 0;
		while (value.charAt(index) == "_") {
			index++;
			if (index == value.length) return false;
		}
		var code = value.charCodeAt(index);
		return code >= "A".code && code <= "Z".code;
	}

	public static function checkUppercase(value:String):Void {
		if (value.length == 0) throw "empty part";
		if (!startsUppercaseIdentifier(value)) throw "Class name must start with an uppercase letter";
	}

	public static function sEscape(value:String, ?hex:Bool = true):String {
		var result = new StringBuf();
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			switch (code) {
				case 10:
					result.add("\\n");
				case 9:
					result.add("\\t");
				case 13:
					result.add("\\r");
				case 34:
					result.add('\\"');
				case 92:
					result.add("\\\\");
				case _ if (code < 32 && hex):
					result.add('\\x${StringTools.hex(code, 2)}');
				case _:
					result.addChar(code);
			}
		}
		return result.toString();
	}

	public static function escapeResName(name:String, allowed:Array<String>):String {
		var result = new StringBuf();
		for (index in 0...name.length) {
			var character = name.charAt(index);
			var code = name.charCodeAt(index);
			if ((code >= "a".code && code <= "z".code)
				|| (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code)
				|| character == "_"
				|| character == "."
				|| allowed.indexOf(character) >= 0) result.add(character);
			else result.add('-x$code');
		}
		return result.toString();
	}

	public static function removeExtension(file:String):String {
		var dot = file.lastIndexOf(".");
		return dot < 0 ? file : file.substr(0, dot);
	}

	public static function extension(file:String):String {
		var dot = file.lastIndexOf(".");
		return dot < 0 ? file : file.substr(dot);
	}

	public static function toUtf8(value:String, position:core.Globals.Pos):{value:String, utf16Length:Int} {
		var length = 0;
		for (code in new haxe.iterators.StringIteratorUnicode(value)) {
			if ((code >= 0xD800 && code <= 0xDFFF) || code >= 0x110000) throw "Invalid unicode char";
			length++;
			if (code > 0x10000) length++;
		}
		return {value: value, utf16Length: length};
	}

	public static function utf16Add(output:StringBuf, code:Int):Void {
		if (code >= 0 && code < 0x10000) {
			if (code >= 0xD800 && code <= 0xDFFF) throw 'Invalid unicode char $code';
			addUtf16Unit(output, code);
		} else if (code < 0x110000) {
			var value = code - 0x10000;
			addUtf16Unit(output, (value >> 10) + 0xD800);
			addUtf16Unit(output, (value & 1023) + 0xDC00);
		} else {
			throw 'Invalid unicode char $code';
		}
	}

	public static function utf8ToUtf16(value:String, zeroTerminated:Bool):String {
		var result = new StringBuf();
		for (code in new haxe.iterators.StringIteratorUnicode(value)) utf16Add(result, code);
		if (zeroTerminated) utf16Add(result, 0);
		return result.toString();
	}

	public static function utf16ToUtf8(value:String):String {
		var result = new StringBuf();
		var index = 0;
		while (index + 1 < value.length) {
			var code = value.charCodeAt(index) | (value.charCodeAt(index + 1) << 8);
			index += 2;
			if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
				var low = value.charCodeAt(index) | (value.charCodeAt(index + 1) << 8);
				if (low >= 0xDC00 && low <= 0xDFFF) {
					code = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00;
					index += 2;
				}
			}
			result.add(String.fromCharCode(code));
		}
		return result.toString();
	}

	public static function urlEncode(value:String, addCharacter:String->Void):Void {
		var bytes = haxe.io.Bytes.ofString(value);
		var hex = "0123456789ABCDEF";
		for (index in 0...bytes.length) {
			var code = bytes.get(index);
			if ((code >= "A".code && code <= "Z".code)
				|| (code >= "a".code && code <= "z".code)
				|| (code >= "0".code && code <= "9".code)
				|| code == "_".code
				|| code == "-".code
				|| code == ".".code) addCharacter(String.fromCharCode(code));
			else {
				addCharacter("%");
				addCharacter(hex.charAt(code >> 4));
				addCharacter(hex.charAt(code & 0xF));
			}
		}
	}

	public static function urlEncodeString(value:String):String {
		var result = new StringBuf();
		urlEncode(value, result.add);
		return result.toString();
	}

	static function addUtf16Unit(output:StringBuf, code:Int):Void {
		output.addChar(code & 0xFF);
		output.addChar(code >> 8);
	}
}
