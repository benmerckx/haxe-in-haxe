// Runs the compiler (hih.js + hih.wasm + hih.data, from site/build.sh).
// Each request gets a fresh instance: the program's static state starts
// clean; the compiled wasm module is reused between instances.
//
// Messages in:
//   {type: "warmup"}
//   {type: "compile", mode: "run" | "hxb", file, main, code}
//   {type: "display", id, file, main, code, request}   (a JSON-RPC display request)
//   {type: "check", id, file, main, code}              (type-check only, for diagnostics)
importScripts("hih.js");

let wasmModule = null;

let moduleReady = null;
const modulePromise = new Promise((resolve) => (moduleReady = resolve));

function instantiateWasm(imports, done) {
	const ready = wasmModule ? Promise.resolve(wasmModule) : modulePromise;
	ready.then((m) => WebAssembly.instantiate(m, imports)).then((inst) => done(inst, wasmModule));
	return {};
}

async function instance(file, code, print, printErr) {
	return createHih({
		noInitialRun: true,
		instantiateWasm,
		print,
		printErr,
		preRun: [(m) => {
			m.ENV.HAXE_STD_PATH = "/lib/haxe/std/";
			m.FS.mkdir("/work");
			m.FS.writeFile("/work/" + file, code);
			m.FS.chdir("/work");
		}],
	});
}

function run(mod, args) {
	try {
		return mod.callMain(args);
	} catch (err) {
		if (err && err.name === "ExitStatus") return err.status;
		throw err;
	}
}

onmessage = async (e) => {
	const m = e.data;
	if (m.type === "module") {
		// the module compiled once by the page (playground.js)
		wasmModule = m.module;
		if (moduleReady) moduleReady(m.module);
		return;
	}
	try {
		if (m.type === "warmup") {
			await instance("Main.hx", "", () => {}, () => {});
			postMessage({type: "ready"});
			return;
		}
		if (m.type === "display" || m.type === "check") {
			const lines = [];
			const mod = await instance(m.file, m.code, (t) => lines.push(t), (t) => lines.push(t));
			const args = ["-cp", ".", "--main", m.main, "--no-output", "-D", "disable-parallelism", "-D", "message.reporting=classic"];
			if (m.type === "display") args.push("--display", JSON.stringify(m.request));
			const t0 = performance.now();
			const status = run(mod, args);
			postMessage({type: m.type, id: m.id, status, output: lines.join("\n"), ms: performance.now() - t0});
			return;
		}
		const mod = await instance(m.file, m.code, (text) => postMessage({type: "out", text}), (text) => postMessage({type: "err", text}));
		const args = ["-cp", ".", "--main", m.main, "-D", "disable-parallelism"];
		if (m.mode === "run") args.push("--interp");
		else args.push("--hxb", "/out.zip", "--no-output");
		const t0 = performance.now();
		const status = run(mod, args);
		const ms = performance.now() - t0;
		let zip = null;
		if (m.mode === "hxb" && status === 0) {
			try { zip = mod.FS.readFile("/out.zip").buffer; } catch (err) {}
		}
		postMessage({type: "done", status, ms, zip}, zip ? [zip] : []);
	} catch (err) {
		postMessage({type: "failed", id: m.id, message: "The compiler instance failed: " + (err && err.message ? err.message : err)});
	}
};
