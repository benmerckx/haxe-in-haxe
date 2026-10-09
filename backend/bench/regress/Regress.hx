// Regressions found compiling haxe-formatter with hxc (bench/README.md, 2026-10-09):
//   haxe -lib hxc -cp backend/bench/regress -main Regress -dce full --custom-target hxc=bin/regress && bin/regress
// prints "ok" five times.
class Regress {
	static function main() {
		// -dce full removed haxe.Exception.caught/thrown, which only the backend calls
		// (the lowering crashed on the missing field)
		try {
			throw new haxe.Exception("ok");
		} catch (e:haxe.Exception) {
			Sys.println(e.message);
		}
		try {
			throw "ok";
		} catch (e:haxe.Exception) {
			Sys.println(e.message);
		}
		// StringTools.isEof was `false` (the std fallback for unknown targets) while
		// fastCodeAt returns 0 past the end, so EOF loops (hxjsonast's Parser) never ended
		var s = "ab", i = 0, n = 0;
		while (!StringTools.isEof(StringTools.fastCodeAt(s, i++)))
			n++;
		Sys.println(n == 2 ? "ok" : "isEof: " + n);
		Sys.println(StringTools.isEof(StringTools.fastCodeAt("", 0)) ? "ok" : "isEof past the end");
		// String.split read the delimiter's length after allocating its result
		// array: a minor collection there moved a young delimiter, and the length
		// came from the forwarding address (crashed or split wrongly, depending
		// on where the heap was mapped)
		var bad = 0;
		for (i in 0...1000000) {
			var delim = (",;" + i).substr(0, 2); // a young ",;"
			var shift = haxe.io.Bytes.alloc(i % 61); // varies where the nursery fills up
			if ("a,;b,;c".split(delim).length != 3 + shift.length * 0) bad++;
		}
		Sys.println(bad == 0 ? "ok" : "split: " + bad);
	}
}
