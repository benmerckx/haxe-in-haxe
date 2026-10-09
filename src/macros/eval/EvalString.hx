package macros.eval;

import macros.eval.EvalValue;

/**
	haxe/src/macro/eval/evalString.ml.

	Upstream strings are UTF-8 with character (code point) indices and cached
	byte offsets. Here a string is native; "byte offsets" are native string
	indices, and character indices are code points. Strings without surrogate
	pairs (`sbmp`) need no offset computation.
**/
class EvalString {
	public static inline function vstring(s:Vstring):Value return VString(s);

	public static function createAscii(s:String):Vstring return new Vstring(s, s.length, true);

	public static function createWithLength(s:String, length:Int):Vstring return new Vstring(s, length, length == s.length);

	public static final emptyString:Vstring = createAscii("");

	public static final vEmptyString:Value = VString(emptyString);

	public static function codePointLength(s:String):Int {
		var n = s.length;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c >= 0xDC00 && c <= 0xDFFF && i > 0) {
				var p = StringTools.fastCodeAt(s, i - 1);
				if (p >= 0xD800 && p <= 0xDBFF) n--;
			}
		}
		return n;
	}

	public static function createUnknownVstring(s:String):Vstring return createWithLength(s, codePointLength(s));

	public static function createUnknown(s:String):Value return VString(createUnknownVstring(s));

	public static function concat(s1:Vstring,
			s2:Vstring):Vstring return new Vstring(s1.sstring + s2.sstring, s1.slength +
			s2.slength, s1.sbmp && s2.sbmp && !joinsSurrogates(s1.sstring, s2.sstring));

	static function joinsSurrogates(a:String, b:String):Bool {
		if (a.length == 0 || b.length == 0) return false;
		var x = StringTools.fastCodeAt(a, a.length - 1),
			y = StringTools.fastCodeAt(b, 0);
		return x >= 0xD800 && x <= 0xDBFF && y >= 0xDC00 && y <= 0xDFFF;
	}

	public static function join(sep:Vstring, sl:Array<Vstring>):Vstring {
		var buf = new StringBuf();
		var first = true;
		for (s in sl) {
			if (!first) buf.add(sep.sstring);
			buf.add(s.sstring);
			first = false;
		}
		return createUnknownVstring(buf.toString());
	}

	/** Native index of the character (code point) at `cIndex`. **/
	public static function getOffset(s:Vstring, cIndex:Int):Int {
		if (s.sbmp) return cIndex;
		var str = s.sstring;
		var b = 0;
		var c = 0;
		while (c < cIndex && b < str.length) {
			b += isHighSurrogateAt(str, b) ? 2 : 1;
			c++;
		}
		return b;
	}

	static inline function isHighSurrogateAt(s:String, i:Int):Bool {
		var x = StringTools.fastCodeAt(s, i);
		return x >= 0xD800 && x <= 0xDBFF && i + 1 < s.length && {
			var y = StringTools.fastCodeAt(s, i + 1);
			y >= 0xDC00 && y <= 0xDFFF;
		};
	}

	/** Native index `b` moved by `cLength` characters (UTF8.move). **/
	public static function move(s:Vstring, b:Int, cLength:Int):Int {
		if (s.sbmp) return b + cLength;
		var str = s.sstring;
		while (cLength > 0 && b < str.length) {
			b += isHighSurrogateAt(str, b) ? 2 : 1;
			cLength--;
		}
		return b;
	}

	/** The code point at character index `cIndex`. **/
	public static function charAt(s:Vstring, cIndex:Int):Int {
		var str = s.sstring;
		var b = getOffset(s, cIndex);
		var x = StringTools.fastCodeAt(str, b);
		if (!s.sbmp && isHighSurrogateAt(str, b)) return ((x - 0xD800) << 10) + (StringTools.fastCodeAt(str, b + 1) - 0xDC00) + 0x10000;
		return x;
	}

	public static function stringOfCharCode(i:Int):String {
		if (i < 0x10000) return String.fromCharCode(i);
		var u = new StringBuf();
		u.addChar(i);
		return u.toString();
	}

	public static function fromCharCode(i:Int):Vstring return new Vstring(stringOfCharCode(i), 1, i < 0x10000);

	/**
		Upstream returns a function searching from (cIndex, bIndex); this returns
		that search (character index, start and end native index) or throws NotFound.
	**/
	public static function findSubstring(self:Vstring, sub:Vstring, reverse:Bool):(cIndex:Int, bIndex:Int) -> {c: Int, b: Int, e: Int} {
		var clThis = self.slength;
		var clSub = sub.slength;
		var sThis = self.sstring;
		var sSub = sub.sstring;
		var blThis = sThis.length;
		var blSub = sSub.length;
		function hit(b:Int):Bool {
			if (b < 0 || b + blSub > blThis) return false;
			for (k in 0...blSub) if (StringTools.fastCodeAt(sThis, b + k) != StringTools.fastCodeAt(sSub, k)) return false;
			return true;
		}
		if (!reverse) {
			return function(cIndex, bIndex) {
				while (true) {
					if (cIndex > clThis - clSub || bIndex >= blThis) {
						// an empty needle matches at the end
						if (blSub == 0 && cIndex <= clThis && bIndex <= blThis) return {c: cIndex, b: bIndex, e: bIndex};
						throw core.ds.NotFound.raise();
					}
					if (hit(bIndex)) return {c: cIndex, b: bIndex, e: bIndex + blSub};
					bIndex += !self.sbmp && isHighSurrogateAt(sThis, bIndex) ? 2 : 1;
					cIndex++;
				}
			}
		} else {
			return function(cIndex, bIndex) {
				while (true) {
					if (cIndex > clThis - clSub || bIndex < 0) throw core.ds.NotFound.raise();
					if (hit(bIndex)) return {c: cIndex, b: bIndex, e: bIndex + blSub};
					cIndex--;
					bIndex -= (!self.sbmp && bIndex >= 2 && isHighSurrogateAt(sThis, bIndex - 2)) ? 2 : 1;
				}
			}
		}
	}

	public static function caseMap(self:Vstring, upper:Bool):Vstring {
		var buf = new StringBuf();
		var a = upper ? EvalBytesUnicase._UPPER : EvalBytesUnicase._LOWER;
		var m = upper ? 1022 : 1021;
		var s = self.sstring;
		var i = 0;
		while (i < s.length) {
			var c = StringTools.fastCodeAt(s, i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var d = StringTools.fastCodeAt(s, i);
				if (d >= 0xDC00 && d <= 0xDFFF) {
					c = ((c - 0xD800) << 10) + (d - 0xDC00) + 0x10000;
					i++;
				}
			}
			var up = c >>> 6;
			if (up < m) {
				var c2 = a[up][c & ((1 << 6) - 1)];
				if (c2 != 0) c = c2;
			}
			buf.addChar(c);
		}
		return createWithLength(buf.toString(), self.slength);
	}

	public static function substr(self:Vstring, cIndex:Int, cLength:Int):Vstring {
		if (cLength < 0) return createWithLength("", 0);
		var b1 = getOffset(self, cIndex);
		var b2 = move(self, b1, cLength);
		return new Vstring(self.sstring.substring(b1, b2), cLength, self.sbmp);
	}

	/** OCaml's String.compare on the UTF-8 encodings: code point order. **/
	public static function compareCodePoints(a:String, b:String):Int {
		var n = a.length < b.length ? a.length : b.length;
		for (i in 0...n) {
			var x = StringTools.fastCodeAt(a, i),
				y = StringTools.fastCodeAt(b, i);
			if (x != y) {
				// surrogates encode code points above every other UTF-16 unit
				var sx = x >= 0xD800 && x <= 0xDFFF,
					sy = y >= 0xD800 && y <= 0xDFFF;
				if (sx != sy) return sx ? 1 : -1;
				return x < y ? -1 : 1;
			}
		}
		return a.length == b.length ? 0 : a.length < b.length ? -1 : 1;
	}

	// VStringBuffer

	public static function bufferCreate():VstringBuffer return new VstringBuffer();

	public static function bufferAddString(self:VstringBuffer, s:Vstring):Void {
		self.bbuffer.add(s.sstring);
		self.blength += s.slength;
	}

	public static function bufferAddSubstring(self:VstringBuffer, s:Vstring, bPos:Int, bLen:Int, cLen:Int):Void {
		self.bbuffer.add(s.sstring.substr(bPos, bLen));
		self.blength += cLen;
	}

	// Buffer.clear: a fresh host buffer
	public static function bufferClear(self:VstringBuffer):Void {
		self.bbuffer = new StringBuf();
		self.blength = 0;
	}

	public static function bufferContents(self:VstringBuffer):Vstring return createUnknownVstring(self.bbuffer.toString());
}
