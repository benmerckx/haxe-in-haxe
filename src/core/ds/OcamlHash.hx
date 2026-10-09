package core.ds;

/**
	OCaml's polymorphic `Hashtbl.hash` (caml_hash with count 10, limit 100,
	seed 0) for the value shapes the display services use as hash table keys:
	strings, ints, lists, tuples and records. The value is described with
	`OcamlValue`, mirroring the runtime representation (immediates and blocks
	with a tag), and traversed breadth first exactly like runtime/hash.c.
	Combined with `OcamlHashtbl`, this reproduces upstream iteration order.
**/
enum OcamlValue {
	OInt(i:Int);
	OString(s:String);
	OBlock(tag:Int, fields:Array<OcamlValue>);
}

class OcamlHash {
	public static function hash(v:OcamlValue):Int {
		var queue:Array<OcamlValue> = [v];
		var rd = 0;
		var sz = 100;
		var num = 10;
		var h = 0;
		while (rd < queue.length && num > 0) {
			var v = queue[rd++];
			switch v {
				case OInt(i):
					// Val_long(i) = 2i+1; the 32-bit fold of the tagged value
					h = mix(h, (i << 1) | 1);
					num--;
				case OString(s):
					h = mixString(h, s);
					num--;
				case OBlock(tag, fields):
					// Cleanhd_hd: wosize << 10 | tag
					h = mix(h, (fields.length << 10) | tag);
					for (f in fields) {
						if (queue.length >= sz) break;
						queue.push(f);
					}
			}
		}
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	public static function ofString(s:String):OcamlValue return OString(s);

	public static function ofList(l:Array<OcamlValue>):OcamlValue {
		var v = OInt(0);
		var i = l.length;
		while (i-- > 0) v = OBlock(0, [l[i], v]);
		return v;
	}

	/** `Globals.path`: `(string list * string)`. **/
	public static function ofPath(pack:Array<String>,
			name:String):OcamlValue return OBlock(0, [ofList([for (s in pack) OString(s)]), OString(name)]);

	/** `Globals.pos`: `{pfile; pmin; pmax}`. **/
	public static function ofPos(p:core.Globals.Pos):OcamlValue return OBlock(0, [OString(p.pfile), OInt(p.pmin), OInt(p.pmax)]);

	public static function hashString(s:String):Int return hash(OString(s));

	public static function hashPath(p:core.Globals.GlobalTypePath):Int return hash(ofPath(p.pack, p.name));

	public static function hashPos(p:core.Globals.Pos):Int return hash(ofPos(p));

	static function mixString(h:Int, s:String):Int {
		var b = haxe.io.Bytes.ofString(s);
		var len = b.length;
		var i = 0;
		while (i + 4 <= len) {
			var w = b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24);
			h = mix(h, w);
			i += 4;
		}
		var w = 0;
		switch len & 3 {
			case 3:
				w = b.get(i + 2) << 16;
				w |= b.get(i + 1) << 8;
				w |= b.get(i);
				h = mix(h, w);
			case 2:
				w |= b.get(i + 1) << 8;
				w |= b.get(i);
				h = mix(h, w);
			case 1:
				w |= b.get(i);
				h = mix(h, w);
			case _:
		}
		h ^= len;
		return h;
	}

	static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	static inline function rotl32(x:Int, n:Int):Int return (x << n) | (x >>> (32 - n));

	static inline function mix(h:Int, d:Int):Int {
		d = mul32(d, 0xcc9e2d51);
		d = rotl32(d, 15);
		d = mul32(d, 0x1b873593);
		h ^= d;
		h = rotl32(h, 13);
		return (mul32(h, 5) + 0xe6546b64) | 0;
	}
}
