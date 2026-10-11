// Playground UI. The compiler runs in Web Workers (worker.js): one for Run /
// Compile to HXB, one for the editor's display requests (completion, hover,
// signature help, diagnostics), so typing never waits behind a running program.
const MONACO = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs";
const $ = (id) => document.getElementById(id);
const out = $("out"), state = $("state"), timing = $("timing"), members = $("members");
const runBtn = $("run"), hxbBtn = $("hxb"), example = $("example");

// ---- the program: Main.hx / Test.hx, main class detected from the source

function mainOf(code) {
	// the class declaring `static function main`: the nearest class before it
	const m = /\b(?:static\s+(?:public\s+|private\s+)?|(?:public|private)\s+static\s+)function\s+main\s*\(/.exec(code);
	if (m) {
		let name = null;
		for (const c of code.slice(0, m.index).matchAll(/\bclass\s+([A-Z]\w*)/g)) name = c[1];
		if (name) return name;
	}
	return /^\s*function\s+main\s*\(/m.test(code) ? "Test" : "Main"; // module-level main
}
const program = (code) => { const main = mainOf(code); return {main, file: main + ".hx", code}; };

// ---- editor: Monaco when it loads, a textarea otherwise

let editor = null, textarea = null, early = ""; // `early`: code set before an editor exists
const getCode = () => editor ? editor.getValue() : textarea ? textarea.value : early;
function setCode(c) { if (editor) editor.setValue(c); else if (textarea) textarea.value = c; else early = c; }

let saved = null;
try { saved = localStorage.getItem("hih-code"); } catch (e) {}
const save = () => { try { localStorage.setItem("hih-code", getCode()); } catch (e) {} };

let examples = [];
fetch("examples/index.json").then((r) => r.json()).then((list) => {
	examples = list;
	const groups = {};
	for (const [i, ex] of list.entries()) {
		const label = ex.source === "try.haxe.org" ? "From try.haxe.org" : "haxe-in-haxe";
		if (!groups[label]) groups[label] = example.appendChild(Object.assign(document.createElement("optgroup"), {label}));
		groups[label].appendChild(new Option(ex.title, i));
	}
	if (!saved) loadExample(0);
});
function loadExample(i) {
	fetch("examples/" + examples[i].file).then((r) => r.text()).then((c) => { setCode(c); save(); });
}
example.addEventListener("change", () => loadExample(+example.value));

function fallbackEditor() {
	textarea = document.createElement("textarea");
	textarea.spellcheck = false;
	textarea.wrap = "off";
	textarea.setAttribute("aria-label", "Haxe source");
	textarea.value = saved || early;
	textarea.addEventListener("input", save);
	textarea.addEventListener("keydown", (e) => {
		if (e.key === "Tab") { e.preventDefault(); textarea.setRangeText("\t", textarea.selectionStart, textarea.selectionEnd, "end"); save(); }
		else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); start("run"); }
	});
	$("editor").replaceWith(textarea);
}

const loader = document.createElement("script");
loader.src = MONACO + "/loader.js";
loader.onerror = fallbackEditor;
loader.onload = () => {
	self.MonacoEnvironment = {getWorkerUrl: () => "data:text/javascript;charset=utf-8," + encodeURIComponent(`self.MonacoEnvironment = {baseUrl: "${MONACO}/../"}; importScripts("${MONACO}/base/worker/workerMain.js");`)};
	require.config({paths: {vs: MONACO}});
	require(["vs/editor/editor.main"], setupMonaco, fallbackEditor);
};
document.head.appendChild(loader);

function setupMonaco() {
	defineHaxe();
	const dark = matchMedia("(prefers-color-scheme: dark)");
	editor = monaco.editor.create($("editor"), {
		value: saved || early,
		language: "haxe",
		theme: dark.matches ? "vs-dark" : "vs",
		automaticLayout: true,
		minimap: {enabled: false},
		fontSize: 14,
		tabSize: 4,
		insertSpaces: false,
		scrollBeyondLastLine: false,
		fixedOverflowWidgets: true,
	});
	dark.addEventListener("change", () => monaco.editor.setTheme(dark.matches ? "vs-dark" : "vs"));
	editor.onDidChangeModelContent(() => { save(); scheduleCheck(); });
	editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => start("run"));
	registerProviders();
	scheduleCheck();
}

// ---- running programs

// The compiler is a 10 MB WebAssembly module with 64-bit memory. It is compiled
// once, only when the playground comes into view (or Run is pressed), and the
// compiled module is shared with the workers. Phones and low-memory devices
// skip the background type-checker (diagnostics, completion), the second
// compiler instance: two of them got mobile browsers' tabs killed.
const LOW_MEMORY = (navigator.deviceMemory || 8) <= 4 || matchMedia("(pointer: coarse)").matches;
const MEMORY64 = (() => {
	// a module with one memory64 memory (limits flag 4)
	try { return WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 0])); } catch (err) { return false; }
})();
let wasmModule = null;
function compilerModule() {
	return wasmModule ||= WebAssembly.compileStreaming(fetch("hih.wasm"));
}
function startWorker(onmessage) {
	const w = new Worker("worker.js");
	w.onmessage = onmessage;
	compilerModule().then((module) => w.postMessage({type: "module", module}), (err) => {
		setBusy(true, "The compiler could not be loaded: " + (err && err.message ? err.message : err));
	});
	return w;
}

let runner = null, busy = false, zipUrl = null, runnerReady = false;
function newRunner() {
	runner = startWorker((e) => onRunnerMessage(e.data));
	runner.postMessage({type: "warmup"});
}
function ensureRunner() {
	if (runner || !MEMORY64) return;
	newRunner();
}

function setBusy(b, text) {
	busy = b;
	runBtn.disabled = hxbBtn.disabled = b;
	state.textContent = text || "";
}
if (!MEMORY64) setBusy(true, "This browser cannot run the compiler: it needs WebAssembly with 64-bit memory (Chrome or Edge 133+, Firefox 134+).");
else {
	setBusy(true, "The compiler loads when the playground is in view…");
	const playground = document.getElementById("playground");
	if (playground && "IntersectionObserver" in self) {
		const io = new IntersectionObserver((entries) => {
			if (entries.some((x) => x.isIntersecting)) {
				io.disconnect();
				setBusy(true, "Loading compiler…");
				ensureRunner();
			}
		});
		io.observe(playground);
	} else {
		setBusy(true, "Loading compiler…");
		ensureRunner();
	}
}

function print(text, cls) {
	const span = document.createElement("span");
	if (cls) span.className = cls;
	span.textContent = text + "\n";
	out.appendChild(span);
}

function start(mode) {
	if (busy) return;
	out.textContent = "";
	members.hidden = true;
	members.textContent = "";
	timing.textContent = "";
	setBusy(true, mode === "run" ? "Compiling and running…" : "Compiling to HXB…");
	runner.postMessage({type: "compile", mode, ...program(getCode())});
}
runBtn.onclick = () => start("run");
hxbBtn.onclick = () => start("hxb");

function onRunnerMessage(m) {
	switch (m.type) {
		case "ready":
			runnerReady = true;
			setBusy(false, "Ready. Ctrl+Enter runs.");
			scheduleCheck();
			break;
		case "out": print(m.text); break;
		case "err": print(m.text, "err"); break;
		case "done":
			timing.textContent = `exit ${m.status}, ${m.ms.toFixed(0)} ms`;
			if (m.zip) showZip(m.zip);
			setBusy(false, "");
			break;
		case "failed":
			print(m.message, "err");
			runner.terminate(); // a crashed instance (stack or memory exhausted): start over
			newRunner();
			setBusy(true, "Restarting compiler…");
			break;
	}
}

// the members of the HXB archive, from the ZIP central directory
function showZip(buf) {
	const bytes = new Uint8Array(buf), view = new DataView(buf);
	let eocd = -1;
	for (let i = bytes.length - 22; i >= 0; i--) if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
	if (eocd < 0) return;
	const count = view.getUint16(eocd + 10, true);
	let p = view.getUint32(eocd + 16, true);
	const rows = [];
	let total = 0;
	for (let i = 0; i < count; i++) {
		const size = view.getUint32(p + 24, true), nlen = view.getUint16(p + 28, true);
		const elen = view.getUint16(p + 30, true), clen = view.getUint16(p + 32, true);
		rows.push([new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nlen)), size]);
		total += size;
		p += 46 + nlen + elen + clen;
	}
	if (zipUrl) URL.revokeObjectURL(zipUrl);
	zipUrl = URL.createObjectURL(new Blob([buf], {type: "application/zip"}));
	print(`${count} HXB modules, ${total.toLocaleString()} bytes uncompressed.`);
	const a = Object.assign(document.createElement("a"), {href: zipUrl, download: "out.hxb.zip", textContent: "Download the archive"});
	const table = document.createElement("table");
	table.innerHTML = "<thead><tr><th>module</th><th>bytes</th></tr></thead>";
	const tb = document.createElement("tbody");
	rows.sort((x, y) => x[0].localeCompare(y[0]));
	for (const [n, s] of rows) {
		const tr = document.createElement("tr");
		tr.innerHTML = "<td></td><td></td>";
		tr.children[0].textContent = n;
		tr.children[1].textContent = s.toLocaleString();
		tb.appendChild(tr);
	}
	table.appendChild(tb);
	members.append(a, table);
	members.hidden = false;
}

// ---- display requests (JSON-RPC, as an IDE sends them), on their own worker

let lsp = null, lspSeq = 0;
const pending = new Map();
function newLsp() {
	lsp = startWorker((e) => {
		const m = e.data, p = pending.get(m.id);
		if (!p) return;
		pending.delete(m.id);
		if (m.type === "failed") { lsp.terminate(); newLsp(); p(null); } else p(m);
	});
}

// one request at a time; a newer request of the same kind replaces a queued one
const queue = new Map();
let inflight = false;
function request(kind, msg) {
	// the type-checker starts once the compiler has loaded, and not on small devices
	if (LOW_MEMORY || !MEMORY64 || !runnerReady) return Promise.resolve(null);
	if (!lsp) newLsp();
	return new Promise((resolve) => {
		const prev = queue.get(kind);
		if (prev) prev.resolve(null);
		queue.set(kind, {msg, resolve});
		pump();
	});
}
function pump() {
	if (inflight || queue.size === 0) return;
	const [kind, {msg, resolve}] = queue.entries().next().value;
	queue.delete(kind);
	inflight = true;
	const id = ++lspSeq;
	pending.set(id, (m) => { inflight = false; resolve(m); pump(); });
	lsp.postMessage({...msg, id});
}

const encoder = new TextEncoder();
function byteOffset(model, position) {
	return encoder.encode(model.getValue().slice(0, model.getOffsetAt(position))).length;
}

async function display(method, model, position, extra) {
	const p = program(model.getValue());
	const params = {file: "/work/" + p.file, offset: byteOffset(model, position), ...extra};
	const m = await request(method, {type: "display", ...p, request: {jsonrpc: "2.0", id: 1, method, params}});
	if (!m) return null;
	const line = m.output.split("\n").find((l) => l.startsWith('{"jsonrpc"'));
	if (!line) return null;
	try {
		const r = JSON.parse(line);
		return r.result ? r.result.result : null;
	} catch (e) {
		return null;
	}
}

// Haxe's JSON types (haxe.display.JsonModuleTypes) as Haxe source
function typeStr(t) {
	if (!t) return "?";
	const a = t.args;
	const path = (p) => p.typeName;
	const params = (ps) => ps && ps.length ? "<" + ps.map(typeStr).join(", ") + ">" : "";
	switch (t.kind) {
		case "TMono": return "Unknown";
		case "TInst": case "TEnum": case "TType": case "TAbstract": return path(a.path) + params(a.params);
		case "TFun": return "(" + a.args.map((x) => (x.opt ? "?" : "") + (x.name ? x.name + ":" : "") + typeStr(x.t)).join(", ") + ") -> " + typeStr(a.ret);
		case "TAnonymous": return "{ " + (a.fields || []).map((f) => f.name + ":" + typeStr(f.type)).join(", ") + " }";
		case "TDynamic": return a ? "Dynamic<" + typeStr(a) + ">" : "Dynamic";
		default: return t.kind;
	}
}

function itemInfo(item) {
	const a = item.args || {};
	const f = a.field;
	const K = monaco.languages.CompletionItemKind;
	switch (item.kind) {
		case "ClassField": case "EnumAbstractField": case "AnonField":
			return {label: f.name, kind: f.kind && f.kind.kind === "FMethod" ? K.Method : K.Field, detail: typeStr(f.type), doc: f.doc};
		case "EnumField": return {label: a.field.name, kind: K.EnumMember, detail: typeStr(a.field.type), doc: a.field.doc};
		case "Local": return {label: a.name, kind: K.Variable, detail: typeStr(a.type)};
		case "Type": return {label: a.path.typeName, kind: a.kind === "Interface" ? K.Interface : a.kind === "Enum" ? K.Enum : K.Class, detail: (a.path.pack || []).concat(a.path.typeName).join("."), doc: a.doc};
		case "Package": return {label: a.path && a.path.pack ? a.path.pack[a.path.pack.length - 1] : String(a), kind: K.Module};
		case "Module": return {label: a.path ? a.path.moduleName : String(a), kind: K.Module};
		case "Keyword": return {label: a.name, kind: K.Keyword};
		case "Literal": return {label: a.name, kind: K.Value, detail: typeStr(a.type)};
		case "Metadata": return {label: a.name, kind: K.Property, doc: a.doc};
		case "TypeParameter": return {label: a.name, kind: K.TypeParameter};
		default: return {label: (f && f.name) || a.name || item.kind, kind: K.Text};
	}
}

function registerProviders() {
	monaco.languages.registerCompletionItemProvider("haxe", {
		triggerCharacters: [".", ":", " "],
		async provideCompletionItems(model, position, context) {
			const ch = context.triggerCharacter;
			if (ch === " ") { // only after `new`, `extends`, `implements`, `import`, `using`, `case`
				const before = model.getLineContent(position.lineNumber).slice(0, position.column - 1);
				if (!/\b(new|extends|implements|import|using|case|cast)\s$/.test(before)) return {suggestions: []};
			}
			const r = await display("display/completion", model, position, {wasAutoTriggered: !!ch});
			if (!r || !r.items) return {suggestions: []};
			const word = model.getWordUntilPosition(position);
			const range = new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn);
			const seen = new Set();
			const suggestions = [];
			for (const item of r.items) {
				const i = itemInfo(item);
				if (!i.label || seen.has(i.label + i.kind)) continue;
				seen.add(i.label + i.kind);
				suggestions.push({label: i.label, kind: i.kind, detail: i.detail, documentation: i.doc ? {value: i.doc.trim()} : undefined, insertText: i.label, range, sortText: String(suggestions.length).padStart(5, "0")});
			}
			return {suggestions};
		},
	});
	monaco.languages.registerHoverProvider("haxe", {
		async provideHover(model, position) {
			const r = await display("display/hover", model, position);
			if (!r || !r.item) return null;
			const t = r.item.type ? typeStr(r.item.type) : itemInfo(r.item).detail;
			const doc = (r.item.args && (r.item.args.doc || (r.item.args.field && r.item.args.field.doc))) || "";
			const contents = [{value: "```haxe\n" + (t || r.item.kind) + "\n```"}];
			if (doc) contents.push({value: doc.trim()});
			return {contents};
		},
	});
	monaco.languages.registerSignatureHelpProvider("haxe", {
		signatureHelpTriggerCharacters: ["(", ","],
		async provideSignatureHelp(model, position) {
			const r = await display("display/signatureHelp", model, position, {wasAutoTriggered: true});
			if (!r || !r.signatures || !r.signatures.length) return null;
			return {
				value: {
					activeSignature: r.activeSignature || 0,
					activeParameter: r.activeParameter || 0,
					signatures: r.signatures.map((s) => {
						const ps = s.args.map((x) => (x.opt ? "?" : "") + x.name + ":" + typeStr(x.t));
						return {label: "(" + ps.join(", ") + ") -> " + typeStr(s.ret), documentation: s.documentation || "", parameters: ps.map((label) => ({label}))};
					}),
				},
				dispose() {},
			};
		},
	});
	monaco.languages.registerDefinitionProvider("haxe", {
		async provideDefinition(model, position) {
			const r = await display("display/definition", model, position);
			if (!r || !r.length) return null;
			return r.filter((d) => d.file.startsWith("/work/")).map((d) => ({
				uri: model.uri,
				range: new monaco.Range(d.range.start.line + 1, d.range.start.character + 1, d.range.end.line + 1, d.range.end.character + 1),
			}));
		},
	});
}

// diagnostics: type-check after typing stops, errors as editor markers
let checkTimer = 0;
function scheduleCheck() {
	clearTimeout(checkTimer);
	// right after a `.` (completion territory) the line is usually incomplete:
	// wait longer before reporting it as an error
	let delay = 700;
	const pos = editor && editor.getPosition();
	if (pos) {
		const before = editor.getModel().getLineContent(pos.lineNumber).slice(0, pos.column - 1);
		if (/\.\w*$/.test(before)) delay = 2500;
	}
	checkTimer = setTimeout(check, delay);
}
async function check() {
	if (!editor) return;
	const model = editor.getModel();
	const p = program(model.getValue());
	const m = await request("check", {type: "check", ...p});
	if (!m || model.getValue() !== p.code) return;
	const markers = [];
	// classic message format: File.hx:LINE: characters A-B : message (or lines A-B)
	const re = /^(?:\/work\/)?([\w.]+\.hx):(\d+): (characters|lines) (\d+)-(\d+) : (.*)$/;
	for (const l of m.output.split("\n")) {
		const x = re.exec(l);
		if (!x || x[1] !== p.file) continue;
		const line = +x[2], a = +x[4], b = +x[5];
		const warning = /^Warning ?:/.test(x[6]);
		markers.push(x[3] === "characters"
			? {startLineNumber: line, startColumn: a + 1, endLineNumber: line, endColumn: Math.max(b + 1, a + 2), message: x[6], severity: warning ? monaco.MarkerSeverity.Warning : monaco.MarkerSeverity.Error}
			: {startLineNumber: a, startColumn: 1, endLineNumber: b, endColumn: 1000, message: x[6], severity: monaco.MarkerSeverity.Error});
	}
	monaco.editor.setModelMarkers(model, "haxe", markers);
}

// Monarch tokenizer for Haxe
function defineHaxe() {
	monaco.languages.register({id: "haxe", extensions: [".hx"]});
	monaco.languages.setLanguageConfiguration("haxe", {
		comments: {lineComment: "//", blockComment: ["/*", "*/"]},
		brackets: [["{", "}"], ["[", "]"], ["(", ")"]],
		autoClosingPairs: [{open: "{", close: "}"}, {open: "[", close: "]"}, {open: "(", close: ")"}, {open: '"', close: '"'}, {open: "'", close: "'"}],
	});
	monaco.languages.setMonarchTokensProvider("haxe", {
		keywords: ["abstract", "break", "case", "cast", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern", "false", "final", "for", "function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "null", "operator", "overload", "override", "package", "private", "public", "return", "static", "switch", "this", "throw", "true", "try", "typedef", "untyped", "using", "var", "while", "from", "to", "is"],
		tokenizer: {
			root: [
				[/@:?[\w.]+/, "annotation"],
				[/#(if|elseif|else|end|error)\b.*$/, "keyword.directive"],
				[/[A-Z][\w]*/, "type.identifier"],
				[/[a-z_$][\w$]*/, {cases: {"@keywords": "keyword", "@default": "identifier"}}],
				{include: "@whitespace"},
				[/[{}()\[\]]/, "@brackets"],
				[/0x[0-9a-fA-F_]+/, "number.hex"],
				[/\d[\d_]*(\.\d+)?([eE][-+]?\d+)?/, "number"],
				[/"/, "string", "@dstring"],
				[/'/, "string", "@sstring"],
				[/~\/(\\.|[^\/\\])+\/[gimsu]*/, "regexp"],
				[/[;,.]/, "delimiter"],
				[/[=><!~?:&|+\-*\/^%]+/, "operator"],
			],
			whitespace: [[/[ \t\r\n]+/, ""], [/\/\*/, "comment", "@comment"], [/\/\/.*$/, "comment"]],
			comment: [[/[^\/*]+/, "comment"], [/\*\//, "comment", "@pop"], [/[\/*]/, "comment"]],
			dstring: [[/[^\\"]+/, "string"], [/\\./, "string.escape"], [/"/, "string", "@pop"]],
			sstring: [[/\$\{/, "delimiter.bracket", "@interp"], [/\$\w+/, "variable"], [/[^\\'$]+/, "string"], [/\\./, "string.escape"], [/\$/, "string"], [/'/, "string", "@pop"]],
			interp: [[/\}/, "delimiter.bracket", "@pop"], {include: "root"}],
		},
	});
}

// build facts (sizes, date, commit) from build-info.json, written by site/build.sh
fetch("build-info.json").then((r) => r.ok ? r.json() : null).then((info) => {
	if (!info) return;
	for (const el of document.querySelectorAll("[data-info]")) {
		const v = info[el.dataset.info];
		if (v != null) el.textContent = v;
	}
}).catch(() => {});
