import Harness.*;
import sys.FileSystem;

using StringTools;

// The math library of hxmc's programs (hxmc/std/hxmc/rt/LibM*.hx) against
// the C library's (glibc on Linux: the reference compiler's):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Libm [--n N] [--seed S]
//     [--targets t,...] [--core-math DIR] [--bench]
// hxmc/test/libm/ref.c (compiled with cc) writes N inputs per function
// (special values, every class of double, the ranges programs use, hard
// regions) with glibc's results; hxmc/test/libm/Probe.hx, built for each
// target (linux-x86_64 natively, linux-arm64 under qemu-aarch64-static,
// windows-x86_64 under wine64, wasm32-wasi under node), recomputes them.
// exp, log, pow, fmod, floor, ceil and fma must match bit for bit (glibc's
// exp, log and pow are ARM's routines in their FMA build, which LibM
// follows: on a processor without FMA, glibc's results may differ by an ulp
// and only that is checked); sin, cos, tan, asin, acos, atan and atan2 are
// CORE-MATH's correctly rounded ones, which may differ from glibc's by one
// ulp (the counts are reported). --core-math DIR (a checkout of
// https://gitlab.inria.fr/core-math/core-math) compares those with
// CORE-MATH's C code itself instead (sin from commit 8ea8ea35, see
// LibMTrig.hx), which must match exactly, and adds its hard cases
// (src/binary64/*/*.wc). --bench times each function (hxmc/test/libm/Bench.hx).
class Libm {
	static final EXACT = ["exp", "log", "pow", "fmod", "floor", "ceil", "fma", "fmahw"];
	static final CR = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2"];

	static function main() {
		var a = parseArgs(Sys.args(), ["--n", "--seed", "--targets", "--core-math"]);
		var n = a.int("--n", 200000);
		var dir = "bin/test/libm";
		mkdirs(dir);
		var tool = Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc";
		var hxmc = [tool];
		var std = ["-cp", "bin/hxmc/std", "--custom-target", "hxmc"];
		if (a.has("--bench")) {
			var r = exec(hxmc.concat(['$dir/bench', "-cp", "hxmc/test/libm", "-main", "Bench"]).concat(std), {merge: true});
			if (r.code != 0) fail(r.out);
			Sys.print(exec(['$dir/bench']).out);
			return;
		}
		// the reference: glibc, or CORE-MATH's C code for the correctly rounded functions
		var cm = a.get("--core-math");
		var cc = ["cc", "-O1", "-fno-builtin", "hxmc/test/libm/ref.c", "-o", '$dir/ref'];
		var wcs = [];
		if (cm != null) {
			var b = '$cm/src/binary64';
			var sinc = '$dir/sin-8ea8ea35.c';
			if (!FileSystem.exists(sinc)) {
				var r = exec(["git", "-C", cm, "show", "8ea8ea35:src/binary64/sin/sin.c"]);
				if (r.code != 0) fail("--core-math: no commit 8ea8ea35 in " + cm + " (a full clone is needed)");
				sys.io.File.saveContent(sinc, r.out);
			}
			var objs = [];
			for (f in CR) {
				var o = '$dir/cr-$f.o';
				var src = f == "sin" ? sinc : '$b/$f/$f.c';
				var r = exec(["cc", "-O2", "-ffp-contract=off", "-I", '$b/$f', "-c", src, "-o", o], {merge: true});
				if (r.code != 0) fail(r.out);
				objs.push(o);
				if (FileSystem.exists('$b/$f/$f.wc')) wcs.push({f: CR.indexOf(f), file: '$b/$f/$f.wc'});
			}
			var h = new StringBuf();
			h.add("#include <math.h>\n");
			for (f in CR) {
				h.add('double cr_$f(${f == "atan2" ? "double, double" : "double"});\n#define $f cr_$f\n');
			}
			sys.io.File.saveContent('$dir/cr.h', h.toString());
			cc = cc.concat(["-include", '$dir/cr.h']).concat(objs);
		}
		var r = exec(cc.concat(["-lm"]), {merge: true});
		if (r.code != 0) fail(r.out);
		var recs = '$dir/rec.bin';
		var args = [Std.string(n)];
		if (a.has("--seed")) args.push(a.get("--seed"));
		r = exec(['$dir/ref'].concat(args), {log: recs});
		if (r.code != 0) fail("ref failed");
		// CORE-MATH's hard cases (records appended)
		if (wcs.length > 0) {
			var out = sys.io.File.append(recs, true);
			for (w in wcs) {
				var x = exec(['$dir/ref', "--wc", Std.string(w.f)], {stdin: w.file, log: '$dir/wc.bin'});
				if (x.code != 0) fail("ref --wc failed");
				out.write(sys.io.File.getBytes('$dir/wc.bin'));
			}
			out.close();
		}
		var fmaCpu = try sys.io.File.getContent("/proc/cpuinfo").split("\n").filter(l -> l.startsWith("flags") && (" " + l + " ").contains(" fma ")).length > 0 catch (_:Dynamic) true;
		var targets = (a.get("--targets") ?? "linux-x86_64,wasm32-wasi,linux-arm64,windows-x86_64").split(",");
		var bad = 0;
		for (t in targets) {
			var runner = switch t {
				case "linux-x86_64": [];
				case "linux-arm64": ["qemu-aarch64-static"];
				case "windows-x86_64": ["/usr/lib/wine/wine64"];
				case "wasm32-wasi": ["node", "--stack-size=65500", "hxmc/bootstrap/wasi.mjs"];
				case _: fail("unknown target " + t);
			};
			if (runner.length > 0 && runner[0].startsWith("/") && !FileSystem.exists(runner[0])) {
				Sys.println('$t: skipped (no ${runner[0]})');
				continue;
			}
			var exe = '$dir/probe-$t' + (t.startsWith("windows") ? ".exe" : "");
			var b = exec(hxmc.concat(['$dir/probe-$t', "-cp", "hxmc/test/libm", "-main", "Probe"]).concat(std).concat(["-D", 'hxmc.target=$t']), {merge: true});
			if (b.code != 0) fail(b.out);
			var p = exec(runner.concat([exe, "--examples", "3", recs]), {merge: true});
			if (p.out.indexOf("probe:") < 0) {
				Sys.println('$t: FAIL (the probe did not finish)\n' + tail(p.out, 2000));
				bad++;
				continue;
			}
			var ok = true;
			var notes = [];
			for (l in p.out.split("\n")) {
				var w = l.split(" ").filter(s -> s != "");
				if (w.length < 10 || w[2] != "/") continue;
				var name = w[0], diff = Std.parseInt(w[1]), far = Std.parseInt(w[7]);
				var exact = EXACT.contains(name) && (fmaCpu || !["exp", "log", "pow"].contains(name));
				if (far > 0 || (diff > 0 && (exact || cm != null))) {
					ok = false;
					notes.push('$name $diff differ, $far by more than one ulp');
				} else if (diff > 0)
					notes.push('$name: $diff of ${w[3]} one ulp from glibc');
			}
			if (!ok) Sys.print(p.out);
			Sys.println('$t: ${ok ? "ok" : "FAIL"}' + (notes.length > 0 ? " (" + notes.join(", ") + ")" : ""));
			if (!ok) bad++;
		}
		Sys.exit(bad > 0 ? 1 : 0);
	}
}
