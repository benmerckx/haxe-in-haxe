class Main {
	static function main() {
		var data:Dynamic = haxe.Json.parse('{"name": "haxe-in-haxe", "targets": ["hxb", "interp"]}');
		trace(data.name + " supports " + data.targets.join(" and "));
		trace(haxe.Json.stringify({ok: true, list: [1, 2, 3]}));

		var words = ~/[^a-z]+/g.split("Haxe, compiled by Haxe!".toLowerCase());
		trace(words.filter(w -> w != ""));

		trace(Lambda.fold([1, 2, 3, 4], (x, acc) -> x + acc, 0));
		trace(StringTools.hex(48879, 6));
		trace(haxe.crypto.Md5.encode("haxe"));
	}
}
