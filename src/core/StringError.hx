package core;

// Port of haxe/src/core/stringError.ml.
class StringError {
	// Same distance as the matrix in stringError.ml, computed with two rows.
	public static function levenshtein(first:String, second:String):Int {
		var n = first.length, m = second.length;
		if (n == 0) return m;
		if (m == 0) return n;
		var prev = new haxe.ds.Vector<Int>(m + 1),
			cur = new haxe.ds.Vector<Int>(m + 1);
		for (column in 0...m + 1) prev[column] = column;
		for (row in 1...n + 1) {
			cur[0] = row;
			var c1 = StringTools.fastCodeAt(first, row - 1);
			for (column in 1...m + 1) {
				var cost = c1 == StringTools.fastCodeAt(second, column - 1) ? 0 : 1;
				cur[column] = minimum(prev[column] + 1, cur[column - 1] + 1, prev[column - 1] + cost);
			}
			var t = prev;
			prev = cur;
			cur = t;
		}
		return prev[m];
	}

	public static function getSimilar(input:String, candidates:Array<String>):Array<String> {
		if (candidates.length == 0) return [];
		var distances = candidates.map(function(candidate) return {candidate: candidate, distance: levenshtein(input, candidate)});
		distances.sort(function(a, b) return a.distance - b.distance);
		var similar:Array<String> = [];
		for (entry in distances) {
			if (entry.distance <= Std.int((input.length < entry.candidate.length ? input.length : entry.candidate.length) / 3))
				similar.push(entry.candidate);
			else break;
		}
		return similar;
	}

	public static function stringError(input:String, candidates:Array<String>, message:String):String {
		if (candidates.length == 0) return message;
		var similar = getSimilar(input, candidates);
		return switch (similar.length) {
			case 0: message;
			case 1: '$message (Suggestion: ${similar[0]})';
			case _: '$message (Suggestions: ${similar.join(", ")})';
		};
	}

	static inline function minimum(first:Int, second:Int, third:Int):Int {
		return first < second ? (first < third ? first : third) : (second < third ? second : third);
	}
}
