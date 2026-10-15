import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Tiered checks of hxmc (`make quick|check|full`, which rebuild the tool
// first): one line per lane with its result and time, a summary at the end,
// exit 1 if any lane failed.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Tiers quick|check|full [--port] [case ...]
//   quick  the x64 corpus (64 KB nursery), again with RT_VERIFY=1, and the wasm
//          corpus under node: after every edit
//   check  quick + linux-arm64 (qemu) and windows-x86_64 (wine), x64 with a
//          16 KB nursery, the wasm corpus with legacy exception handling
//          (-D hxmc.wasm-eh=legacy) under node, ThreadNatives x30, the math
//          library against glibc's on four targets (Libm.hx), the tool as
//          a module building three cases for x64, arm64 and wasm32-wasi
//          byte-identical to the native tool; --port adds the native port's
//          self-compile: before commits
//   full   x64, arm64 and wine at 64, 16 and 256 KB, each with RT_VERIFY=1 too;
//          wasm under node and wasmtime at 16, 64 and 256 KB, under node with
//          RT_VERIFY=1 at 64 and 256 KB and with legacy exception handling at
//          16 and 64 KB; ThreadNatives x300 (16 KB) and x100 (64 KB); the
//          port's self-compile natively (64 KB, 256 KB, 256 KB with
//          RT_VERIFY=1) and as a module (node, node with 256 KB, wasmtime, node
//          with legacy exception handling); the tool as a module building
//          every case for every target and itself; the math library (Libm.hx);
//          the fixpoint: before pushing
// Cases named restrict the corpus lanes to them; the port, ThreadNatives and
// fixpoint lanes ignore them. Lanes run one after another (they share the
// cases' output directories); the reference (bin/reference/haxe) is needed
// for the port lanes.
class Tiers {
	static var results:Array<{name:String, ok:Bool}> = [];
	static final SCRIPT = ["bin/hxmc/hxmc", "-cp", "hxmc/test", "-cp", "haxe/test", "--run"];
	static final LEGACY = ["--wasm-eh", "legacy"];

	static function lane(name:String, f:Void->{ok:Bool, detail:String}) {
		var t = now();
		var r = try f() catch (e:Dynamic) {ok: false, detail: Std.string(e)};
		results.push({name: name, ok: r.ok});
		Sys.println(pad(name, 28) + " " + (r.ok ? "ok  " : "FAIL") + " " + fixed(now() - t).lpad(" ", 6) + "s  " + r.detail);
	}

	static function lastLine(s:String):String {
		var lines = [for (l in s.trim().split("\n")) if (l.trim() != "") l];
		return lines.length == 0 ? "" : lines[lines.length - 1];
	}

	static function corpus(?target:String, ?env:Map<String, Null<String>>, cases:Array<String>, ?extra:Array<String>) return () -> {
		var cmd = SCRIPT.concat(["Corpus"]);
		if (extra != null) cmd = cmd.concat(extra);
		if (target != null) cmd = cmd.concat(["--target", target]);
		var r = exec(cmd.concat(cases), {env: env, merge: true});
		var bad = [];
		for (l in r.out.split("\n")) {
			var w = l.split(" ").filter(s -> s != "");
			if (w.length > 1 && !["ok", "excluded"].contains(w[1]) && !l.contains("/")) bad.push(w[0] + " " + w[1]);
		}
		{ok: r.code == 0, detail: lastLine(r.out) + (bad.length == 0 ? "" : "  " + bad.slice(0, 8).join(", "))};
	}

	static function threads(n:Int, kb:Int) return () -> {
		exec(SCRIPT.concat(["Corpus", "ThreadNatives"]));
		var d = "bin/hxmc-t/ThreadNatives";
		var exp = File.getContent("hxmc/test/expected/ThreadNatives.txt");
		var bad = 0;
		for (_ in 0...n) {
			var r = exec([FileSystem.fullPath(d + "/m")], {cwd: d, env: ["RT_MINOR_KB" => Std.string(kb)], timeout: 60});
			if (r.timedOut || 'exit ${r.code}\n' + r.out != exp) bad++;
		}
		{ok: bad == 0, detail: '${n - bad}/$n runs'};
	}

	static function digest(path:String):String {
		var z = readZip(path);
		var names = z.names.copy();
		names.sort(compare);
		var ctx = new haxe.io.BytesBuffer();
		for (n in names) {
			ctx.addString(n);
			ctx.add(z.data[n]);
		}
		return haxe.crypto.Sha256.make(ctx.getBytes()).toHex();
	}

	static function portNative() {
		var r = exec(SCRIPT.concat(["Selfcheck", "--local", "--small"]), {merge: true});
		var lines = [for (l in r.out.split("\n")) if (l.startsWith("self-compile")) l];
		return {ok: r.code == 0, detail: lines.length > 0 ? lines[0] : lastLine(r.out)};
	}

	static function selfCompile(cmd:Array<String>, ?env:Map<String, Null<String>>) return () -> {
		var out = "bin/hxmc-t/self-tier.hxb";
		if (FileSystem.exists(out)) FileSystem.deleteFile(out);
		var r = exec(cmd.concat(["-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output", "--hxb", out]), {env: env, merge: true});
		if (r.code != 0) return {ok: false, detail: tail(r.out, 300)};
		var same = digest(out) == digest("bin/hxmc-t/self-ref.hxb");
		{ok: same, detail: same ? "identical to the reference" : "DIFFERS from the reference"};
	}

	static function wasmPortBuild(legacy = false) return () -> {
		var out = legacy ? "bin/hxmc-t/wport/haxe-legacy.wasm" : "bin/hxmc-t/wport/haxe.wasm";
		var r = exec(["bin/hxmc/hxmc", out, "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "-cp", "bin/hxmc/std",
			"--custom-target", "hxmc", "-D", "hxmc.target=wasm32-wasi"].concat(legacy ? ["-D", "hxmc.wasm-eh=legacy"] : []), {merge: true});
		{ok: r.code == 0, detail: r.code == 0 ? FileSystem.stat(out).size + " bytes" : tail(r.out, 300)};
	}

	static function crosshost(args:Array<String>) return () -> {
		var r = exec(SCRIPT.concat(["Crosshost"]).concat(args), {merge: true});
		var bad = [for (l in r.out.split("\n")) if (l.contains(" FAIL ")) l.split(" ").filter(s -> s != "").slice(0, 2).join(" ")];
		{ok: r.code == 0, detail: lastLine(r.out) + (bad.length == 0 ? "" : "  " + bad.slice(0, 8).join(", "))};
	}

	// the math library against glibc's on every target (Libm.hx)
	static function libm() {
		var r = exec(SCRIPT.concat(["Libm", "--n", "50000"]), {merge: true});
		var lines = [for (l in r.out.split("\n")) if (l.contains(": ok") || l.contains(": FAIL") || l.contains(": skipped")) l.substr(0, l.indexOf(":") + (l.contains(": ok") ? 4 : 6))];
		return {ok: r.code == 0, detail: r.code == 0 || lines.length > 0 ? lines.join(", ") : tail(r.out, 300)};
	}

	static function fixpoint() {
		var r = exec(["make", "--no-print-directory", "fixpoint"], {merge: true});
		var said = [for (l in r.out.split("\n")) if (l.startsWith("fixpoint:")) l];
		return {ok: r.code == 0, detail: said.length > 0 ? said[0] : tail(r.out, 300)};
	}

	static function main() {
		var args = Sys.args();
		if (args.length == 0 || !["quick", "check", "full"].contains(args[0])) fail("usage: Tiers quick|check|full [--port] [case ...]");
		var tier = args[0], port = args.contains("--port");
		var cases = [for (a in args.slice(1)) if (a != "--port") a];
		var t0 = now();
		if (tier != "full") {
			lane("x64", corpus(cases));
			lane("x64 RT_VERIFY", corpus(null, ["RT_VERIFY" => "1"], cases));
			lane("wasm node", corpus("wasm32-wasi", null, cases));
		}
		if (tier == "check") {
			lane("x64 16K", corpus(null, ["RT_MINOR_KB" => "16"], cases));
			lane("arm64 (qemu)", corpus("linux-arm64", null, cases));
			lane("windows (wine)", corpus("windows-x86_64", null, cases));
			lane("wasm node legacy EH", corpus("wasm32-wasi", null, cases, LEGACY));
			lane("ThreadNatives x30", threads(30, 16));
			lane("libm", libm);
			lane("cross-host", crosshost(["--targets", "linux-x86_64,linux-arm64,wasm32-wasi"].concat(cases.length > 0 ? cases : ["Unsafe", "SwitchIndex", "Regress"])));
			if (port) lane("port self-compile", portNative);
		}
		if (tier == "full") {
			for (t in ["linux-x86_64", "linux-arm64", "windows-x86_64"])
				for (kb in ["64", "16", "256"]) {
					lane('$t ${kb}K', corpus(t, ["RT_MINOR_KB" => kb], cases));
					lane('$t ${kb}K RT_VERIFY', corpus(t, ["RT_MINOR_KB" => kb, "RT_VERIFY" => "1"], cases));
				}
			for (kb in ["16", "64", "256"]) {
				lane('wasm node ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb], cases));
				lane('wasm wasmtime ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb, "HXMC_WASM_RUNNER" => "wasmtime"], cases));
			}
			for (kb in ["64", "256"]) lane('wasm node ${kb}K RT_VERIFY', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb, "RT_VERIFY" => "1"], cases));
			for (kb in ["16", "64"]) lane('wasm node legacy EH ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb], cases, LEGACY));
			lane("ThreadNatives x300 16K", threads(300, 16));
			lane("ThreadNatives x100 64K", threads(100, 64));
			lane("port self-compile", portNative);
			lane("port 256K RT_VERIFY", selfCompile(["bin/hxmc-t/port/s"], ["RT_MINOR_KB" => "256", "RT_VERIFY" => "1"]));
			lane("wasm port build", wasmPortBuild());
			var wp = FileSystem.fullPath("bin/hxmc-t/wport") + "/haxe.wasm";
			var node = ["node", "--no-warnings", "--stack-size=8000", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), wp];
			lane("wasm port node", selfCompile(node));
			lane("wasm port node 256K", selfCompile(node, ["RT_MINOR_KB" => "256"]));
			lane("wasm port wasmtime", selfCompile(["wasmtime", "run", "-W", "exceptions=y", "-W", "max-wasm-stack=67108864", "--dir", "/", "--env", "HAXE_STD_PATH",
				"--env", "PWD=" + root, wp]));
			lane("wasm port build legacy EH", wasmPortBuild(true));
			lane("wasm port node legacy EH", selfCompile(["node", "--no-warnings", "--stack-size=8000", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), FileSystem.fullPath("bin/hxmc-t/wport") + "/haxe-legacy.wasm"], ["HXMC_WASM_EXNREF" => "0"]));
			lane("libm", libm);
			lane("cross-host", crosshost(["--tool"].concat(cases)));
			lane("fixpoint", fixpoint);
		}
		var bad = [for (r in results) if (!r.ok) r.name];
		Sys.println('$tier: ${results.length - bad.length}/${results.length} lanes ok, ${Math.round(now() - t0)}s' + (bad.length == 0 ? "" : "; FAILED: " + bad.join(", ")));
		Sys.exit(bad.length > 0 ? 1 : 0);
	}
}
