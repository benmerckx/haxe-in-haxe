import formatter.Formatter;
import formatter.config.Config;
import tokentree.TokenTreeBuilder.TokenTreeEntryPoint;
import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;

// Untimed correctness audit: unlike the upstream NoIO workload, inspect results.
class FormatterAudit {
	static function main() {
		var paths:Array<String> = [];
		function collect(dir:String) {
			for (f in FileSystem.readDirectory(dir)) {
				var p = Path.join([dir, f]);
				if (FileSystem.isDirectory(p)) collect(p); else paths.push(p);
			}
		}
		collect(Sys.args()[0]);
		paths.sort(Reflect.compare);
		var config = new Config();
		var config2 = new Config();
		config2.lineEnds.leftCurly = Both;
		var success = 0;
		var failed = 0;
		var disabled = 0;
		var checksums:Array<String> = [];
		for (p in paths) {
			var src = File.getContent(p);
			for (c in [config, config2]) {
				switch (Formatter.format(Code(src), c, null, TokenTreeEntryPoint.TYPE_LEVEL)) {
					case Success(code):
						success++;
						checksums.push(haxe.crypto.Sha256.encode(code));
					case Failure(error): failed++;
					case Disabled: disabled++;
				}
			}
		}
		Sys.println(haxe.Json.stringify({files: paths.length, success: success, failed: failed,
			disabled: disabled, checksum: haxe.crypto.Sha256.encode(checksums.join("\n"))}));
	}
}
