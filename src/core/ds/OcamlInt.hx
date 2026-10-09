package core.ds;

import haxe.Int64;

class IntParseFailure extends haxe.Exception {
	public function new() super("int_of_string");
}

// Runtime compatibility for upstream int_of_string (64-bit OCaml host).
// Parsing follows OCaml runtime/ints.c: signed decimal, unsigned base prefixes,
// optional sign, underscores after the first digit, and a 63-bit tagged value.
class OcamlInt {
	public static inline var maxInt:Int = 0x7fffffff;

	static function digit(c:Int):Int return c >= 48 && c <= 57 ? c - 48 : c >= 65 && c <= 70 ? c - 55 : c >= 97 && c <= 102 ? c - 87 : -1;

	public static function parse(value:String):Int64 {
		var i = 0, sign = 1, base = 10, signed = true;
		if (value.charAt(i) == "-") {
			sign = -1;
			i++;
		} else if (value.charAt(i) == "+") i++;
		if (value.charAt(i) == "0") switch value.charAt(i + 1) {
			case "x", "X":
				base = 16;
				signed = false;
				i += 2;
			case "o", "O":
				base = 8;
				signed = false;
				i += 2;
			case "b", "B":
				base = 2;
				signed = false;
				i += 2;
			case "u", "U":
				signed = false;
				i += 2;
			case _:
		}
		if (i >= value.length) throw new IntParseFailure();
		var d = digit(value.charCodeAt(i++));
		if (d < 0 || d >= base) throw new IntParseFailure();
		var limit = signed ? (sign < 0 ? Int64.make(0x40000000, 0) : Int64.make(0x3fffffff, -1)) : Int64.make(0x7fffffff, -1);
		var threshold = limit / base, remainder = (limit % base).low;
		var result:Int64 = d;
		while (i < value.length) {
			var c = value.charCodeAt(i++);
			if (c == 95) continue;
			d = digit(c);
			if (d < 0 || d >= base || result > threshold || result == threshold && d > remainder) throw new IntParseFailure();
			result = result * base + d;
		}
		if (sign < 0) result = -result;
		return (result << 1) >> 1;
	}

	// Haxe model fields use 32-bit Int. Keep narrowing explicit and checked;
	// callers needing the complete OCaml range (e.g. index validation) use parse.
	public static function ofString(value:String):Int {
		var result = parse(value);
		if (result < Int64.ofInt(-2147483647 - 1) || result > Int64.ofInt(2147483647)) throw new IntParseFailure();
		return result.low;
	}
}
