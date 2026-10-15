package hxmc;

// The hxmc tool (README.md, "hxmc"): runs the port's compiler pipeline on the
// program (from an HXB archive with --hxb-lib, or from source), lowers the
// filtered program to hxmc's IR (hxmc.ir.Lower) and compiles it to machine
// code:
//   hxmc <out> <haxe arguments...> -cp bin/hxmc/std --custom-target hxmc
// With a first argument that starts with `-` it is the compiler's command
// line (HaxeMain), e.g. for scripts: `hxmc -cp hxmc/src --run hxmc.MkStd`.
// Options (defines, or the environment for development):
//   -D hxmc.target=linux-x86_64     the target (Target.hx, Abi.hx: six of them)
//   -D hxmc.wasm-eh=legacy          wasm32-wasi: legacy exception handling (default: exnref)
//   HXMC_RT_OBJ                     the runtime object (default: <tool dir>/rt/<target>/rt.o)
//   HXMC_STATS=1                    print what the build did and how long it took
class Main {
	static var start = haxe.Timer.stamp();
	static var lowerCache = new LowerCache();

	static function main() {
		var args = Sys.args();
		if (args[0] == "--mkrt-macho") {
			args.shift();
			MkRt.macho(args);
			return;
		}
		if (args[0] == "--mkrt") {
			args.shift();
			MkRt.main(args);
			return;
		}
		// resident: the port's compilation server (`hxmc --server --wait <port>`;
		// builds come with `--connect <port>` and name their output with
		// -D hxmc.out=<path>)
		if (args[0] == "--server") {
			args.shift();
			if (Sys.getEnv("RT_OLD_MB") == null && Sys.getEnv("HXMC_GC_DEFAULTS") != "0" && Sys.systemName() != "Wasi") {
				Sys.putEnv("RT_OLD_MB", "4096");
				if (Sys.getEnv("RT_MINOR_KB") == null) Sys.putEnv("RT_MINOR_KB", "32768");
				Sys.exit(Sys.command(Sys.programPath(), ["--server"].concat(args)));
			}
			Driver.resident = true;
			compiler.Compiler.generateHook = function(com) {
				try {
					start = haxe.Timer.stamp();
					var o = core.Define.rawDefined(com.defines, "hxmc.out") ? core.Define.rawDefinedValue(com.defines, "hxmc.out") : null;
					if (o == null) throw "-D hxmc.out=<path> names the output of a server build";
					generate(com, o);
				} catch (e:Dynamic) {
					Sys.stderr().writeString("hxmc: " + Std.string(e) + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack()) + "\n");
				}
			}
			Sys.exit(haxe.Main.run(args));
		}
		if (args.length == 0 || StringTools.startsWith(args[0], "-"))
			Sys.exit(HaxeMain.run(args));
		var out = args.shift();
		var failed = null;
		var key = UpToDate.key(args, out);
		if (UpToDate.check(key, out)) {
			if (Sys.getEnv("HXMC_STATS") == "1") Sys.println("hxmc: up to date (" + Std.int((haxe.Timer.stamp() - start) * 1000) + " ms)");
			Sys.exit(0);
		}
		if (key != null) UpToDate.forget(out);
		// a whole-program build keeps most of what it makes (the typed program,
		// then every module's code until the link): a large nursery and a large
		// first old-space limit spare it most collections (half the GC time of
		// a cold build of the port). The runtime reads them at startup, so the
		// tool runs itself again with them set (not under WASI: no processes).
		if (Sys.getEnv("RT_OLD_MB") == null && Sys.getEnv("HXMC_GC_DEFAULTS") != "0" && Sys.systemName() != "Wasi") {
			Sys.putEnv("RT_OLD_MB", "2048");
			if (Sys.getEnv("RT_MINOR_KB") == null) Sys.putEnv("RT_MINOR_KB", "32768");
			Sys.exit(Sys.command(Sys.programPath(), [out].concat(args)));
		}
		compiler.Compiler.generateHook = function(com) {
			try {
				generate(com, out);
			} catch (e:Dynamic) {
				failed = Std.string(e) + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			}
		}
		var code = haxe.Main.run(args.concat(["--no-output"]));
		if (failed != null) {
			Sys.stderr().writeString("hxmc: " + failed + "\n");
			Sys.exit(1);
		}
		if (code == 0) UpToDate.record(key, out);
		Sys.exit(code);
	}

	static function generate(com:context.Common.CommonContext, out:String) {
		var path = com.main.mainPath;
		var mainClass = null;
		for (t in com.types)
			switch t {
				case TClassDecl(c) if (c.clPath.name == path.name && c.clPath.pack.join(".") == path.pack.join(".")):
					mainClass = c;
				case _:
			}
		var opts = Options.read(com);
		var abi = Abi.get(opts.target);
		hxmc.ir.Lower.targetOs = abi.osCode();
		// WebAssembly's runtime is typed with the program only for that target
		if (abi.wasm && !Lambda.exists(com.types, t -> switch t {
			case TClassDecl(c): c.clPath.pack.join(".") == "hxmc.rt.wasm" && c.clPath.name == "Gc";
			case _: false;
		}))
			throw "hxmc: a program for " + abi.name + " must be typed for it: -D hxmc.target=" + abi.name + " (also when writing its HXB)";
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		var t0 = haxe.Timer.stamp();
		// resident: bodies of the fields the server kept are reused (LowerCache)
		var useCache = Driver.resident && Sys.getEnv("HXMC_LOWER_CACHE") != "0";
		var prog = useCache ? lowerCache.lower(mainClass, com.types, com.basic) : hxmc.ir.Lower.program(mainClass, com.types, com.basic);
		if (opts.stats) {
			Sys.println('hxmc: lowering ${Std.int((haxe.Timer.stamp() - t0) * 1000)} ms (since start ${Std.int((t0 - start) * 1000)} ms)');
			if (useCache)
				Sys.println('hxmc: bodies ${lowerCache.hits} reused, ${lowerCache.misses} lowered' + (lowerCache.why != null ? ' (lowered again: ${lowerCache.why})' : ''));
		}
		if (Sys.getEnv("HXMC_LOWER_ONLY") == "1") return; // (profiling the lowering)
		Driver.run(prog, out, opts);
		// HXMC_LOWER_CHECK=1: the same program lowered from scratch must give the same executable
		if (useCache && Sys.getEnv("HXMC_LOWER_CHECK") == "1") {
			var fresh = hxmc.ir.Lower.program(mainClass, com.types, com.basic);
			Driver.run(fresh, out + ".check", opts);
			var same = sys.io.File.getBytes(out).compare(sys.io.File.getBytes(out + ".check")) == 0;
			Sys.println("hxmc: lowering check: " + (same ? "same executable" : "DIFFERENT executable"));
		}
	}
}
