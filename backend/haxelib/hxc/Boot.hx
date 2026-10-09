package hxc;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;

using StringTools;

// `-lib hxc` (extraParams.hxml) with `--custom-target hxc=<out>`: the user's
// Haxe types the program and writes it as HXB; after generation, the bundled
// compiler lowers that archive to <out>.c and a C compiler builds <out>.
//
//   -D hxc.cc=<command>   C compiler (default: $HXC_CC, else cc, gcc, clang, tcc)
//   -D hxc.static         fully static, portable binary with cosmocc
//   -D hxc.debug          -O0 -g
//   -D hxc.c-only         stop after writing <out>.c
//   -D hxc.ssl, hxc.uv    link mbedtls / libuv (the system's; with cosmocc, the package's cosmo/)
//   -D hxc.keep-hxb       keep the intermediate archive (<out>.hxb.zip)
//   -D hxc.verbose        print the commands
class Boot {
	public static function init() {
		if (Context.definedValue("target.name") != "hxc" || Context.defined("display")) return;
		var out = Compiler.getOutput();
		if (out == null || out == "") Context.fatalError("hxc: set the output with --custom-target hxc=<path>", Context.currentPos());
		var config = Compiler.getHxbWriterConfiguration();
		var archive, keep;
		if (config != null) { // the user's own --hxb: reuse it
			archive = config.archivePath.replace("$target", "hxc");
			keep = true;
		} else {
			archive = out + ".hxb.zip";
			keep = Context.defined("hxc.keep-hxb");
			// macro modules are not part of the program
			Compiler.setHxbWriterConfiguration({archivePath: archive, macroConfig: {generate: false}});
		}
		Build.verbose = Context.defined("hxc.verbose");
		Context.onAfterGenerate(function() {
			var main = Compiler.getConfiguration().mainClass;
			if (main == null) Context.fatalError("hxc: needs a main class (-main)", Context.currentPos());
			if (Compiler.getConfiguration().args.contains("--no-output") || !FileSystem.exists(archive)) {
				if (!keep && FileSystem.exists(archive)) FileSystem.deleteFile(archive);
				return;
			}
			var dir = haxe.io.Path.directory(out);
			if (dir != "" && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			var code = Build.toC(archive, out, main.pack.concat([main.name]).join("."), defines(), Compiler.getConfiguration().stdPath);
			if (!keep) FileSystem.deleteFile(archive);
			if (code != 0) {
				// HXB is tied to the compiler that writes it: the archive must come from the Haxe hxc.com was built from
				var built = try haxe.Json.parse(sys.io.File.getContent(Build.lib + "hxc.json")) catch (_:Dynamic) null;
				var hint = built == null ? "" : ' (hxc reads the HXB of Haxe ${built.haxe}, commit ${built.commit}; a different Haxe build may write an incompatible archive)';
				Context.fatalError("hxc: lowering to C failed" + hint, Context.currentPos());
			}
			if (Context.defined("hxc.c-only")) return;
			var cc = Context.definedValue("hxc.cc");
			code = Build.toBinary(out, {
				cc: cc != null && cc != "1" ? cc : Sys.getEnv("HXC_CC"),
				isStatic: Context.defined("hxc.static"),
				debug: Context.defined("hxc.debug"),
				ssl: Context.defined("hxc.ssl"),
				uv: Context.defined("hxc.uv")
			});
			if (code != 0) Context.fatalError("hxc: C compilation failed", Context.currentPos());
		});
	}

	// the user's defines the backend may read (filters rerun on the loaded
	// modules); the ones the compiler sets itself are left out
	static function defines():Array<String> {
		var r = [];
		var d = Context.getDefines();
		var keys = [for (k in d.keys()) k];
		keys.sort(Reflect.compare);
		for (k in keys) {
			// haxe, haxe3..haxe5, haxe_ver/haxe-ver are the compiler's; user defines such as haxe-next are passed on
			if (k.startsWith("target.") || ~/^haxe([0-9]*|[_-]ver)$/.match(k) || k.startsWith("hxc.") || k == "true" || k == "sys" || k == "static" || k == "utf16"
				|| k == "hxc" || k == "hxb" || k.startsWith("hxb."))
				continue;
			r.push(k + "=" + d[k]);
		}
		return r;
	}
}
#end
