package core.ds;

import Type as StdType;

/** Structural comparison for the finite records, tuples and lists used as OCaml map keys. */
class Key {
	public static function compare(a:Dynamic, b:Dynamic):Int {
		// Fast path for the common string keys (before the Dynamic ==, which is a
		// runtime compare); same order as `>` on strings: by UTF-16 code units.
		var sa = asString(a);
		if (sa != null) {
			var sb = asString(b);
			if (sb != null) return compareStrings(sa, sb);
		}
		if (a == b) return 0;
		if (a == null) return -1;
		if (b == null) return 1;
		if ((a is Int) && (b is Int)) return (a : Int) > (b : Int) ? 1 : -1;
		// Type paths compare like the {name, pack} record they replace (fields in name order).
		var pa = asTypePath(a), pb = pa == null ? null : asTypePath(b);
		if (pb != null) {
			var c = compare(pa.name, pb.name);
			return c != 0 ? c : compare(pa.pack, pb.pack);
		}
		if (Std.isOfType(a, Array) && Std.isOfType(b, Array)) {
			var aa:Array<Dynamic> = a,
				bb:Array<Dynamic> = b,
				n = Std.int(Math.min(aa.length, bb.length));
			for (i in 0...n) {
				var c = compare(aa[i], bb[i]);
				if (c != 0) return c;
			}
			return Reflect.compare(aa.length, bb.length);
		}
		return switch [StdType.typeof(a), StdType.typeof(b)] {
			case [TEnum(_), TEnum(_)]:
				var c = Reflect.compare(StdType.enumIndex(a), StdType.enumIndex(b));
				c != 0 ? c : compare(StdType.enumParameters(a), StdType.enumParameters(b));
			case [
				TObject | TClass(core.Globals.GlobalTypePath),
				TObject | TClass(core.Globals.GlobalTypePath)
			]:
				var names = Reflect.fields(a), other = Reflect.fields(b);
				names.sort(Reflect.compare);
				other.sort(Reflect.compare);
				var c = compare(names, other);
				if (c != 0) c; else {
					var result = 0;
					for (name in names) {
						result = compare(Reflect.field(a, name), Reflect.field(b, name));
						if (result != 0) break;
					}
					result;
				}
			case [TFunction, _], [_, TFunction]: throw new haxe.Exception("compare: functional value");
			case _: Reflect.compare(a, b);
		}
	}

	// String and GlobalTypePath have no subclasses: on HashLink an exact
	// type-pointer test, where Std.downcast goes through BaseType.check.
	public static inline function asString(v:Dynamic):Null<String> {
		#if hl
		return hl.Type.getDynamic(v) == hl.Type.get("") ? untyped $unsafecast(v) : null;
		#else
		return Std.downcast(v, String);
		#end
	}

	static inline function asTypePath(v:Dynamic):Null<core.Globals.GlobalTypePath> {
		#if hl
		return hl.Type.getDynamic(v) == hl.Type.get((null : core.Globals.GlobalTypePath)) ? untyped $unsafecast(v) : null;
		#else
		return Std.downcast(v, core.Globals.GlobalTypePath);
		#end
	}

	public static function compareStrings(a:String, b:String):Int {
		var la = a.length, lb = b.length, n = la < lb ? la : lb;
		for (i in 0...n) {
			var ca = StringTools.fastCodeAt(a, i),
				cb = StringTools.fastCodeAt(b, i);
			if (ca != cb) return ca < cb ? -1 : 1;
		}
		return la == lb ? 0 : la < lb ? -1 : 1;
	}

	/**
		A string that is equal for two keys exactly when `compare` returns 0, used to
		index hash tables. Returns null for keys outside the plain-data subset
		(class instances, functions, large values): tables then fall back to a
		linear scan with `compare`.
	**/
	public static function canonical(value:Dynamic):Null<String> {
		var s0 = asString(value);
		if (s0 != null) return "s" + s0;
		// Type paths (module and type tables) get their own encoding: the parts
		// joined by control characters, which identifiers cannot contain. Cheaper
		// than visit() below (no closure, StringBuf or number formatting). The
		// part count keeps [] and [""] (a macro-defined empty package) apart.
		// GlobalTypePath is a class, so these keys never meet the structural
		// {name, pack} encoding in the same table.
		var tp0 = asTypePath(value);
		if (tp0 != null && tp0.name != null && tp0.pack != null) return "\x01"
			+ tp0.pack.length
			+ "\x02"
			+ tp0.pack.join("\x02")
			+ "\x03"
			+ tp0.name;
		return canonicalSlow(value);
	}

	static function canonicalSlow(value:Dynamic):Null<String> {
		var buf = new StringBuf(), budget = 64;
		function visit(v:Dynamic):Bool {
			if (--budget < 0) return false;
			if (v == null) {
				buf.add("n");
				return true;
			}
			var s = asString(v);
			if (s != null) {
				buf.add("s");
				buf.add(s.length);
				buf.add(":");
				buf.add(s);
				return true;
			}
			if (v is Int) {
				buf.add("i");
				buf.add((v : Int));
				buf.add(";");
				return true;
			}
			if (Std.isOfType(v, Array)) {
				var a:Array<Dynamic> = v;
				buf.add("a");
				buf.add(a.length);
				buf.add("[");
				for (x in a) if (!visit(x)) return false;
				return true;
			}
			var tp = asTypePath(v);
			if (tp != null) {
				buf.add("o24:name");
				if (!visit(tp.name)) return false;
				buf.add("4:pack");
				return visit(tp.pack);
			}
			return switch StdType.typeof(v) {
				case TBool:
					buf.add((v : Bool) ? "T" : "F");
					true;
				case TEnum(_):
					var params = StdType.enumParameters(v);
					buf.add("e");
					buf.add(StdType.enumIndex(v));
					buf.add("(");
					buf.add(params.length);
					for (x in params) if (!visit(x)) return false;
					true;
				case TObject:
					var names = Reflect.fields(v);
					names.sort(Reflect.compare);
					buf.add("o");
					buf.add(names.length);
					for (name in names) {
						buf.add(name.length);
						buf.add(":");
						buf.add(name);
						if (!visit(Reflect.field(v, name))) return false;
					}
					true;
				case _: false; // floats, class instances and functions keep the linear path
			}
		}
		return visit(value) ? buf.toString() : null;
	}
}
