// Runs the compiler (hih.js + hih.wasm + hih.data, from site/build.sh).
// Each compile gets a fresh instance: the program's static state starts
// clean, and the compiled wasm module is reused between instances.
importScripts("hih.js");

let wasmModule = null;

function instantiateWasm(imports, done) {
	const ready = wasmModule
		? Promise.resolve(wasmModule)
		: WebAssembly.compileStreaming(fetch("hih.wasm")).then((m) => (wasmModule = m));
	ready.then((m) => WebAssembly.instantiate(m, imports)).then((inst) => done(inst, wasmModule));
	return {};
}

async function instance(code) {
	return createHih({
		noInitialRun: true,
		instantiateWasm,
		print: (text) => postMessage({type: "out", text}),
		printErr: (text) => postMessage({type: "err", text}),
		preRun: [(m) => {
			m.ENV.HAXE_STD_PATH = "/lib/haxe/std/";
			m.FS.mkdir("/work");
			m.FS.writeFile("/work/Main.hx", code);
			m.FS.chdir("/work");
		}],
	});
}

onmessage = async (e) => {
	const m = e.data;
	try {
		if (m.type === "warmup") {
			await instance("");
			postMessage({type: "ready"});
			return;
		}
		const mod = await instance(m.code);
		const args = ["-cp", ".", "--main", "Main", "-D", "disable-parallelism"];
		if (m.mode === "run") args.push("--interp");
		else args.push("--hxb", "/out.zip", "--no-output");
		const t0 = performance.now();
		let status = 0;
		try {
			status = mod.callMain(args);
		} catch (err) {
			if (err && err.name === "ExitStatus") status = err.status;
			else throw err;
		}
		const ms = performance.now() - t0;
		let zip = null;
		if (m.mode === "hxb" && status === 0) {
			try { zip = mod.FS.readFile("/out.zip").buffer; } catch (err) {}
		}
		postMessage({type: "done", status, ms, zip}, zip ? [zip] : []);
	} catch (err) {
		postMessage({type: "failed", message: "The compiler instance failed: " + (err && err.message ? err.message : err)});
	}
};
