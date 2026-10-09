package core.ds;

import haxe.Int64;
import core.ds.OcamlInt.IntParseFailure;

// Fixed-width integer literal parsing corresponding to OCaml runtime/ints.c.
class OcamlInt64 {
	public static function ofString(value:String):Int64 return parse(value, 64);

	public static function parse(value:String, bits:Int):Int64 {
		var i = 0, negative = false, base = 10, signed = true;
		if (value.charAt(i) == "-") {
			negative = true;
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
		var signBit = Int64.ofInt(1) << (bits - 1);
		var limit = signed ? (negative ? signBit : signBit - 1) : (bits == 64 ? Int64.make(-1, -1) : (signBit << 1) - 1);
		// Divide the unsigned limit by a small base without signed Int64 overflow.
		var half = limit >>> 1, rem = (half % base).low * 2 + (limit.low & 1);
		var threshold = (half / base) * 2 + Std.int(rem / base);
		rem %= base;
		var result:Int64 = 0, hasDigit = false;
		while (i < value.length) {
			var c = value.charCodeAt(i++);
			if (c == 95 && hasDigit) continue;
			var d = c >= 48 && c <= 57 ? c - 48 : c >= 65 && c <= 70 ? c - 55 : c >= 97 && c <= 102 ? c - 87 : -1;
			if (d < 0
				|| d >= base
				|| Int64.ucompare(result, threshold) > 0
				|| (result == threshold && d > rem)) throw new IntParseFailure();
			result = result * base + d;
			hasDigit = true;
		}
		if (!hasDigit) throw new IntParseFailure();
		return negative ? -result : result;
	}
}
