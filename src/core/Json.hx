package core;

// Port of haxe/libs/json/json.ml.
enum JsonValue {
	JString(value:String);
	JFloat(value:Float);
	JInt(value:Int);
	JObject(fields:Array<JsonField>);
	JArray(values:Array<JsonValue>);
	JBool(value:Bool);
	JNull;
}

@:structInit class JsonField {
	public var name:String;
	public var value:JsonValue;

	public inline function new(name:String, value:JsonValue) {
		this.name = name;
		this.value = value;
	}

	public inline function clone():JsonField return new JsonField(name, value);
}

class Json {
	public static function stringOfJson(json:JsonValue):String {
		var output = new StringBuf();
		writeJson(output.add, json);
		return output.toString();
	}

	public static function writeJson(write:String->Void, value:JsonValue):Void {
		switch (value) {
			case JNull:
				write("null");
			case JBool(value):
				write(value ? "true" : "false");
			case JString(value):
				writeString(write, value);
			case JFloat(value):
				writeFloat(write, value);
			case JInt(value):
				writeInt(write, value);
			case JObject(value):
				writeObject(write, value);
			case JArray(value):
				writeArray(write, value);
		}
	}

	static function writeString(write:String->Void, value:String):Void {
		write('"');
		var escaped = new StringBuf();
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			switch (code) {
				case 34:
					escaped.add('\\"');
				case 9:
					escaped.add('\\t');
				case 13:
					escaped.add('\\r');
				case 8:
					escaped.add('\\b');
				case 10:
					escaped.add('\\n');
				case 12:
					escaped.add('\\f');
				case 92:
					escaped.add('\\\\');
				case _ if (code <= 31 || code == 127):
					escaped.add('\\u${StringTools.hex(code, 4)}');
				case _:
					escaped.addChar(code);
			}
		}
		write(escaped.toString());
		write('"');
	}

	static function writeInt(write:String->Void, value:Int):Void write(Std.string(value));

	static function writeFloat(write:String->Void, value:Float):Void {
		if (Math.isNaN(value) || !Math.isFinite(value)) throw new core.ds.Failure("NaN and infinity floats are unsupported in JSON");
		// json.ml: Printf "%.16g", or "%.17g" if that does not read back exactly
		var s = core.ds.OcamlPrintf.formatG(16, value);
		var s = Std.parseFloat(s) == value ? s : core.ds.OcamlPrintf.formatG(17, value);
		write(s);
	}

	static function writeArray(write:String->Void, values:Array<JsonValue>):Void {
		write("[");
		for (index in 0...values.length) {
			if (index > 0) write(",");
			writeJson(write, values[index]);
		}
		write("]");
	}

	static function writeObject(write:String->Void, fields:Array<JsonField>):Void {
		write("{");
		for (index in 0...fields.length) {
			if (index > 0) write(",");
			writeString(write, fields[index].name);
			write(":");
			writeJson(write, fields[index].value);
		}
		write("}");
	}
}

class Reader {
	public static function readJson(input:String):JsonValue return new Parser(input).readJson();
}

private class Parser {
	var input:String;
	var position:Int = 0;

	public function new(input:String) this.input = input;

	public function readJson():JsonValue {
		skipSpace();
		if (position == input.length) error("Unexpected end of input");
		return switch (input.charCodeAt(position)) {
			case 116: readKeyword("true", JBool(true));
			case 102: readKeyword("false", JBool(false));
			case 110: readKeyword("null", JNull);
			case 34:
				position++;
				JString(readStringContents());
			case 45, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: readNumber();
			case 123: readObject();
			case 91: readArray();
			case _: error("Invalid token");
		};
	}

	function readKeyword(keyword:String, result:JsonValue):JsonValue {
		if (input.substr(position, keyword.length) != keyword) error("Invalid token");
		position += keyword.length;
		return result;
	}

	function readNumber():JsonValue {
		var start = position;
		if (input.charCodeAt(position) == 45) position++;
		if (position == input.length) error("Invalid token");
		if (input.charCodeAt(position) == 48) position++;
		else {
			if (!isNonzeroDigit(input.charCodeAt(position))) error("Invalid token");
			do position++ while (position < input.length && isDigit(input.charCodeAt(position)));
		}
		var floating = false;
		if (position < input.length && input.charCodeAt(position) == 46) {
			floating = true;
			position++;
			var fractionStart = position;
			while (position < input.length && isDigit(input.charCodeAt(position))) position++;
			if (position == fractionStart) error("Invalid token");
		}
		if (position < input.length && (input.charCodeAt(position) == 69 || input.charCodeAt(position) == 101)) {
			floating = true;
			position++;
			if (position < input.length && (input.charCodeAt(position) == 43 || input.charCodeAt(position) == 45)) position++;
			var exponentStart = position;
			while (position < input.length && isDigit(input.charCodeAt(position))) position++;
			if (position == exponentStart) error("Invalid token");
		}
		var token = input.substr(start, position - start);
		if (floating) return JFloat(parseFloat(token));
		var integer = parseInt(token);
		return integer == null ? JFloat(parseFloat(token)) : JInt(integer);
	}

	function readObject():JsonValue {
		position++;
		skipSpace();
		var fields:Array<JsonField> = [];
		if (consume(125)) return JObject(fields);
		while (true) {
			if (!consume(34)) error("Expected string");
			var name = readStringContents();
			skipSpace();
			if (!consume(58)) error("Expected ':'");
			var value = readJson();
			fields.push({name: name, value: value});
			skipSpace();
			if (consume(125)) return JObject(fields);
			if (!consume(44)) error("Expected ',' or '}'");
			skipSpace();
		}
	}

	function readArray():JsonValue {
		position++;
		skipSpace();
		var values:Array<JsonValue> = [];
		if (consume(93)) return JArray(values);
		while (true) {
			values.push(readJson());
			skipSpace();
			if (consume(93)) return JArray(values);
			if (!consume(44)) error("Expected ',' or ']'");
			skipSpace();
		}
	}

	function readStringContents():String {
		var output = new StringBuf();
		while (position < input.length) {
			var code = input.charCodeAt(position++);
			if (code == 34) return output.toString();
			if (code != 92) {
				output.addChar(code);
				continue;
			}
			if (position == input.length) error("Invalid escape sequence");
			switch (input.charCodeAt(position++)) {
				case 34, 92, 47:
					output.addChar(input.charCodeAt(position - 1));
				case 98:
					output.addChar(8);
				case 102:
					output.addChar(12);
				case 110:
					output.addChar(10);
				case 114:
					output.addChar(13);
				case 116:
					output.addChar(9);
				case 117:
					var high = readUnicodeEscape();
					if (high >= 0xD800 && high <= 0xDBFF) {
						if (input.substr(position,
							2) != "\\u") error("Missing escape sequence representing low surrogate for code point beyond U+FFFF");
						position += 2;
						var low = readUnicodeEscape();
						if (low < 0xDC00 || low > 0xDFFF) error("Invalid low surrogate for code point beyond U+FFFF");
						var scalar = 0x10000 + ((high - 0xD800) << 10) + low - 0xDC00;
						output.add(String.fromCharCode(scalar));
					} else output.addChar(high);
				case _:
					error("Invalid escape sequence");
			}
		}
		return error("Unexpected end of input");
	}

	function readUnicodeEscape():Int {
		if (position + 4 > input.length) error("Invalid escape sequence");
		var value = 0;
		for (_ in 0...4) {
			var code = input.charCodeAt(position++);
			var digit = code >= 48
				&& code <= 57 ? code - 48 : code >= 65 && code <= 70 ? code - 65 + 10 : code >= 97 && code <= 102 ? code - 97 + 10 : -1;
			if (digit < 0) error("Invalid escape sequence");
			value = (value << 4) | digit;
		}
		return value;
	}

	function skipSpace():Void while (position < input.length && switch (input.charCodeAt(position)) {
			case 32, 9, 13, 10: true;
			case _: false;
		}) position++;

	function consume(code:Int):Bool {
		if (position < input.length && input.charCodeAt(position) == code) {
			position++;
			return true;
		}
		return false;
	}

	static inline function isDigit(code:Int):Bool return code >= 48 && code <= 57;

	static inline function isNonzeroDigit(code:Int):Bool return code >= 49 && code <= 57;

	static function parseFloat(token:String):Float {
		var value = Std.parseFloat(token);
		if (Math.isNaN(value)) error("Invalid token");
		return value;
	}

	static function parseInt(token:String):Null<Int> {
		var index = 0;
		var negative = token.charCodeAt(0) == 45;
		if (negative) index++;
		var value = 0;
		var limit = negative ? -2147483648 : 2147483647;
		while (index < token.length) {
			var digit = token.charCodeAt(index++) - 48;
			if (negative) {
				if (value < Std.int((limit + digit) / 10.0)) return null;
				value = value * 10 - digit;
			} else {
				if (value > Std.int((limit - digit) / 10.0)) return null;
				value = value * 10 + digit;
			}
		}
		return value;
	}

	static function error<T>(message:String):T throw message;
}
