// Untimed reproduction: no filesystem or non-ASCII input required.
class JsonEofAudit {
	static function main() {
		var input = "{}";
		var eof = StringTools.fastCodeAt(input, input.length);
		Sys.println('eof=$eof isEof=${StringTools.isEof(eof)}');
		try {
			haxe.Json.parse(input);
			Sys.println("parse=success");
		} catch (e:Dynamic) {
			Sys.println('parse=failed: $e');
			Sys.exit(1);
		}
	}
}
