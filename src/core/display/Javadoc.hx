package core.display;

// haxe/src/core/display/javadoc.ml
private enum DocTag {
	Returns(value:String);
	Deprecated(value:String);
	Since(value:String);
	Default(value:String);
	See(value:String);
	Param(name:String, value:String);
	Throws(name:String, value:String);
	Event(name:String, value:String);
	Custom(name:String, value:String);
}

class Javadoc {
	final doc:String;
	var actualDoc:String;
	var tags:Array<DocTag> = [];
	var parsedTags = false;

	public function new(doc:String) {
		this.doc = doc;
		actualDoc = doc;
	}

	public static function stringOfTag(tag:DocTag):String return switch tag {
		case Returns(s): "returns " + s;
		case Deprecated(s): "deprecated " + s;
		case Since(s): "since " + s;
		case Default(s): "default " + s;
		case See(s): "see " + s;
		case Param(n, s): "param " + n + " " + s;
		case Throws(n, s): "throws " + n + " " + s;
		case Event(n, s): "event " + n + " " + s;
		case Custom(n, s): n + " " + s;
	};

	public function getParamInfo(name:String):Null<String> {
		if (!parsedTags) parseTags();
		for (tag in tags) switch tag {
			case Param(n, value) if (n == name):
				return value;
			case _:
		}
		return null;
	}

	public function parseTags():Void {
		parsedTags = true;
		var length = doc.length;
		function commitTag(name:String, value:String):Void {
			var split = value.indexOf(" "),
				first = split < 0 ? value : value.substr(0, split),
				second = split < 0 ? "" : value.substr(split + 1);
			var tag = switch name {
				case "param": Param(first, second);
				case "exception" | "throws": Throws(first, second);
				case "event": Event(first, second);
				case "deprecated": Deprecated(value);
				case "return" | "returns": Returns(value);
				case "since": Since(value);
				case "default": Default(value);
				case "see": See(value);
				case _: Custom(name, value);
			};
			tags.unshift(tag);
		}
		function newline(p:Int):Null<{char:String, pos:Int, indent:Int}> {
			var hadStar = false, indent = 0;
			while (p < length) {
				var c = doc.charAt(p++);
				switch c {
					case " " | "\t":
						indent++;
					case "*" if (!hadStar):
						hadStar = true;
						indent = 0;
					case "\r" | "\n":
						hadStar = false;
						indent = 0;
					case _:
						return {char: c, pos: p, indent: indent};
				}
			}
			return null;
		}
		function lastCharPosOnLine(p:Int):{last:Int, next:Int} {
			var last = p, next = p;
			while (next < length) switch doc.charAt(next) {
				case " " | "\r" | "\t":
					next++;
				case "\n":
					return {last: last, next: next + 1};
				case _:
					last = next;
					next++;
			}
			return {last: last, next: next};
		}
		var docBuf = new StringBuf(), p = 0;
		while (true) {
			var line = newline(p);
			if (line == null) break;
			p = line.pos;
			if (line.char == "@") {
				var split = doc.indexOf(" ", p);
				if (split < 0) {
					docBuf.add(doc.substr(p));
					break;
				}
				var name = doc.substring(p, split),
					valueBuf = new StringBuf(),
					start = split + 1;
				while (true) {
					var end = lastCharPosOnLine(start);
					valueBuf.add(doc.substr(start, end.last - start + 1));
					var nextLine = newline(end.next);
					if (nextLine != null && nextLine.indent > line.indent) {
						valueBuf.add("\n");
						valueBuf.add(nextLine.char);
						start = nextLine.pos;
					} else {
						p = end.next;
						break;
					}
				}
				commitTag(name, valueBuf.toString());
			} else {
				docBuf.add(line.char);
				var end = lastCharPosOnLine(p);
				docBuf.add(doc.substr(p, end.last - p + 1));
				p = end.next;
			}
		}
		tags.reverse();
	}
}
