package compiler;

// Port of haxe/src/compiler/helper.ml.
class HelpMessage {
	public final message:String;

	public function new(message:String) {
		this.message = message;
	}
}

class Helper {
	public static final isDebugRun:Bool = Sys.getEnv("HAXEDEBUG") == "1";
	public static var prompt:Bool = false;

	public static function expandEnv(path:String, ?environment:Map<String, String>):String {
		var expression = ~/%([A-Za-z0-9_]+)%/g;
		return expression.map(path, function(match) {
			var key = match.matched(1);
			var value = Sys.getEnv(key);
			if (value != null) return value;
			if (environment != null && environment.exists(key)) return environment.get(key);
			return '%$key%';
		});
	}

	public static function unquote(value:String):String {
		if (value.length > 1) {
			var first = value.charAt(0);
			var last = value.charAt(value.length - 1);
			if ((first == '"' && last == '"') || (first == "'" && last == "'")) return value.substr(1, value.length - 2);
		}
		return value;
	}

	public static function parseHxmlData(data:String):Array<String> {
		var arguments:Array<String> = [];
		for (line in ~/[\r\n]+/g.split(data)) {
			var line = unquote(StringTools.trim(line));
			if (line == "" || line.charAt(0) == "#") continue;
			if (line.charAt(0) == "-") {
				var space = line.indexOf(" ");
				if (space >= 0) {
					arguments.push(unquote(line.substr(0, space)));
					arguments.push(unquote(StringTools.trim(line.substr(space + 1))));
				} else {
					arguments.push(line);
				}
			} else {
				arguments.push(line);
			}
		}
		return arguments;
	}

	public static function parseHxml(file:String):Array<String> {
		try return parseHxmlData(sys.io.File.getContent(file))
		catch (_:Dynamic) throw "Not_found";
	}
}
