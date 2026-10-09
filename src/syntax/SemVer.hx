package syntax;

// Port of haxe/src/syntax/semver.ml.
enum SemVerPart {
	SVNum(value:Int);
	SVStr(value:String);
}

@:structInit class SemVer {
	public var release:Array<SemVerPart>;
	public var pre:Null<Array<SemVerPart>>;

	public inline function new(release:Array<SemVerPart>, pre:Null<Array<SemVerPart>>) {
		this.release = release;
		this.pre = pre;
	}

	public inline function clone():SemVer return new SemVer(release, pre);
}

class SemVerTools {
	public static function stringOfVersion(version:SemVerPart):String {
		return switch (version) {
			case SVNum(value): 'SVNum $value';
			case SVStr(value): 'SVStr $value';
		};
	}

	public static function toString(version:SemVer):String {
		var release = version.release.map(stringPart).join(".");
		return release + (version.pre == null ? "" : "-" + version.pre.map(stringPart).join("."));
	}

	public static function parseVersion(input:String):SemVer {
		var dash = input.indexOf("-");
		if (dash < 0) return {release: parseRelease(input, input), pre: null};
		if (dash + 1 == input.length) invalid(input);

		var pre = input.substr(dash + 1);
		var plus = pre.indexOf("+");
		if (plus >= 0) pre = pre.substr(0, plus);
		return {release: parseRelease(input.substr(0, dash), input), pre: parse(pre)};
	}

	public static function compareVersion(a:SemVer, b:SemVer):Int {
		var release = compareLists(a.release, b.release);
		if (release != 0) return release;
		if (a.pre == null) return b.pre == null ? 0 : 1;
		if (b.pre == null) return -1;
		return compareLists(a.pre, b.pre);
	}

	static function parseRelease(input:String, original:String):Array<SemVerPart> {
		var release = parse(input);
		if (release.length != 3) invalid(original);
		for (part in release) switch (part) {
			case SVNum(_):
			case SVStr(_):
				invalid(original);
		}
		return release;
	}

	static function parse(input:String):Array<SemVerPart> {
		return input.split(".").map(function(part) {
			return ~/^-?[0-9]+$/.match(part) ? SVNum(Std.parseInt(part)) : SVStr(part);
		});
	}

	static function compareLists(a:Array<SemVerPart>, b:Array<SemVerPart>):Int {
		var length = a.length < b.length ? a.length : b.length;
		for (index in 0...length) {
			var comparison = comparePart(a[index], b[index]);
			if (comparison != 0) return comparison;
		}
		return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
	}

	static function comparePart(a:SemVerPart, b:SemVerPart):Int {
		return switch [a, b] {
			case [SVNum(a), SVNum(b)]: a < b ? -1 : a > b ? 1 : 0;
			case [SVStr(a), SVStr(b)]: a < b ? -1 : a > b ? 1 : 0;
			case [SVStr(_), SVNum(_)]: 1;
			case [SVNum(_), SVStr(_)]: -1;
		};
	}

	static function stringPart(part:SemVerPart):String {
		return switch (part) {
			case SVNum(value): Std.string(value);
			case SVStr(value): value;
		};
	}

	static function invalid(input:String):Dynamic {
		throw 'Invalid version string "$input". Should follow SemVer.';
	}
}
