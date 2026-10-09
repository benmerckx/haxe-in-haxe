// Playground UI: the compiler runs in worker.js (one fresh instance per run).
const EXAMPLES = {
	"Hello": `class Main {
	static function main() {
		trace("Hello from Haxe, compiled by Haxe, running in WebAssembly!");
	}
}
`,
	"Enums and pattern matching": `enum Expr {
	Num(v:Float);
	Add(a:Expr, b:Expr);
	Mul(a:Expr, b:Expr);
	Neg(e:Expr);
}

class Main {
	static function eval(e:Expr):Float
		return switch e {
			case Num(v): v;
			case Add(a, b): eval(a) + eval(b);
			case Mul(a, b): eval(a) * eval(b);
			case Neg(e): -eval(e);
		}

	static function show(e:Expr):String
		return switch e {
			case Num(v): '$v';
			case Add(a, b): '(\${show(a)} + \${show(b)})';
			case Mul(a, b): '\${show(a)} * \${show(b)}';
			case Neg(e): '-\${show(e)}';
		}

	static function main() {
		var e = Mul(Add(Num(1), Num(2)), Neg(Num(4)));
		trace(show(e) + " = " + eval(e));
	}
}
`,
	"Macros": `import haxe.macro.Expr;

class Main {
	// runs inside the compiler, in the port's Eval interpreter
	static macro function fib(n:Int):ExprOf<Int> {
		function f(n:Int):Int return n < 2 ? n : f(n - 1) + f(n - 2);
		return macro $v{f(n)};
	}

	static macro function compiledAt():ExprOf<String>
		return macro $v{Date.now().toString()};

	static function main() {
		trace('fib(24) = \${fib(24)}, computed at compile time');
		trace('compiled at \${compiledAt()}');
	}
}
`,
	"Generics and abstracts": `abstract Celsius(Float) from Float {
	public inline function toFahrenheit():Float
		return this * 9 / 5 + 32;
}

class Stack<T> {
	var items:Array<T> = [];
	public var length(get, never):Int;

	public function new() {}

	public function push(x:T)
		items.push(x);

	public function pop():Null<T>
		return items.pop();

	function get_length()
		return items.length;
}

class Main {
	static function main() {
		var s = new Stack<String>();
		for (w in "the quick brown fox".split(" "))
			s.push(w);
		var out = [];
		while (s.length > 0)
			out.push(s.pop());
		trace(out.join(" "));

		var t:Celsius = 21.5;
		trace('21.5 C = \${t.toFahrenheit()} F');

		var squares = [for (i in 1...6) i * i];
		trace('squares: $squares');
	}
}
`,
	"Standard library": `class Main {
	static function main() {
		var data:Dynamic = haxe.Json.parse('{"name": "haxe-in-haxe", "targets": ["hxb", "interp"]}');
		trace(data.name + " supports " + data.targets.join(" and "));
		trace(haxe.Json.stringify({ok: true, list: [1, 2, 3]}));

		var words = ~/[^a-z]+/g.split("Haxe, compiled by Haxe!".toLowerCase());
		trace(words.filter(w -> w != ""));

		trace(Lambda.fold([1, 2, 3, 4], (x, acc) -> x + acc, 0));
		trace(StringTools.hex(48879, 6));
		trace(haxe.crypto.Md5.encode("haxe"));
	}
}
`,
};

const $ = (id) => document.getElementById(id);
const code = $("code"), out = $("out"), state = $("state"), timing = $("timing"), members = $("members");
const runBtn = $("run"), hxbBtn = $("hxb"), example = $("example");

for (const name of Object.keys(EXAMPLES)) example.add(new Option(name, name));
let saved = null;
try { saved = localStorage.getItem("hih-code"); } catch (e) {}
code.value = saved || EXAMPLES.Hello;
example.addEventListener("change", () => { code.value = EXAMPLES[example.value]; save(); });
function save() { try { localStorage.setItem("hih-code", code.value); } catch (e) {} }
code.addEventListener("input", save);
code.addEventListener("keydown", (e) => {
	if (e.key === "Tab") {
		e.preventDefault();
		code.setRangeText("\t", code.selectionStart, code.selectionEnd, "end");
		save();
	} else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
		e.preventDefault();
		start("run");
	}
});

let worker = null, busy = false, zipUrl = null;
function newWorker() {
	worker = new Worker("worker.js");
	worker.onmessage = (e) => onMessage(e.data);
	worker.postMessage({type: "warmup"});
}
newWorker();

function setBusy(b, text) {
	busy = b;
	runBtn.disabled = hxbBtn.disabled = b;
	state.textContent = text || "";
}
setBusy(true, "Loading compiler…");

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
	worker.postMessage({type: "compile", mode, code: code.value});
}
runBtn.onclick = () => start("run");
hxbBtn.onclick = () => start("hxb");

function onMessage(m) {
	switch (m.type) {
		case "ready":
			setBusy(false, "Ready. Ctrl+Enter runs.");
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
			// a crashed instance (stack or memory exhausted): start over
			worker.terminate();
			newWorker();
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
		const name = new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nlen));
		rows.push([name, size]);
		total += size;
		p += 46 + nlen + elen + clen;
	}
	if (zipUrl) URL.revokeObjectURL(zipUrl);
	zipUrl = URL.createObjectURL(new Blob([buf], {type: "application/zip"}));
	print(`${count} HXB modules, ${total.toLocaleString()} bytes uncompressed.`);
	const a = document.createElement("a");
	a.href = zipUrl;
	a.download = "out.hxb.zip";
	a.textContent = "Download the archive";
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

// build facts (sizes, date, commit) from build-info.json, written by site/build.sh
fetch("build-info.json").then((r) => r.ok ? r.json() : null).then((info) => {
	if (!info) return;
	for (const el of document.querySelectorAll("[data-info]")) {
		const v = info[el.dataset.info];
		if (v != null) el.textContent = v;
	}
}).catch(() => {});
