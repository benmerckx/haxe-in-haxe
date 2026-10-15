import Ui.el;
import Ui.fixed;
import haxe.DynamicAccess;
import js.Browser.document;
import js.Browser.window;
import js.html.Element;
import js.html.TableCellElement;

// The Benchmarks and Target generators sections: tables of bench.json,
// programs.json and targets.json (measured results, hxmc/web/data), copied
// by `make site` (Makefile).
typedef BenchRun = {
	workload:String,
	runner:String,
	status:String,
	?runs:Int,
	?verified:Bool,
	?cpu_min:Float,
	?wall_min:Float,
	?maxrss_mb:Float,
}

typedef BuildFacts = {
	wall:Float,
	cpu:Float,
	size:Float,
	gzip:Float,
}

typedef BenchData = {
	results:Array<BenchRun>,
	?builds:DynamicAccess<BuildFacts>,
	?notes:DynamicAccess<String>,
	?meta:{
		?cpu:String,
		?cores:Int,
		?memory_gb:Float,
		?date:String,
		?commit:String,
		?versions:DynamicAccess<String>,
	},
}

typedef ProgramRun = {
	?build:Float,
	?run:Float,
	?size:Float,
	?gzip:Float,
	?error:String,
}

typedef ProgramData = {
	results:DynamicAccess<ProgramRun>,
	?meta:{
		?cpu:String,
		?cores:Int,
		?date:String,
		?commit:String,
		?versions:DynamicAccess<String>,
	},
}

typedef TargetSide = {
	status:String,
	cpu:Float,
	rss_mb:Float,
	members:Int,
	bytes:Float,
}

typedef TargetRun = {
	project:String,
	target:String,
	reference:TargetSide,
	?port:TargetSide,
	identical:Bool,
}

typedef TargetData = {
	results:Array<TargetRun>,
	?meta:{
		?cpu:String,
		?cores:Int,
		?date:String,
		?commit:String,
		?reference:String,
	},
}

class Tables {
	static final RUNNERS = [
		["reference", "OCaml reference"],
		["hxmc", "hxmc, x86-64"],
		["hxmc-wasm-node", "hxmc, wasm (Node)"],
		["hxmc-wasm-wasmtime", "hxmc, wasm (wasmtime)"],
	];
	static final PROGRAMS = [
		["alloc", "allocation"], ["bcrypt", "bcrypt"], ["binarytrees", "binary trees"], ["json", "JSON"], ["mandelbrot", "Mandelbrot"],
		["mandelbrot_anon", "Mandelbrot, anonymous objects"], ["nbody", "n-body"], ["sha256", "SHA-256"], ["sha512", "SHA-512"],
		["formatter_noio", "haxe-formatter"],
	];
	static final WORKLOADS = [
		["self", "The port's own source: 52k lines in 382 modules, with std macros run by the Eval interpreter."],
		["stdlib", "32 standard library modules (JSON, XML, zip, crypto, data structures) as roots."],
		["hello", "Hello world: mostly start-up time and the core standard library."],
	];
	static final TARGETS = [
		["hxb", "HXB"], ["js", "JavaScript"], ["lua", "Lua"], ["python", "Python"], ["php", "PHP"], ["neko", "Neko"],
		["hl", "HashLink"], ["hlc", "HL/C (sources)"], ["cpp", "C++ (sources)"], ["jvm", "JVM"], ["swf", "Flash (SWF)"],
	];
	static final PROJECTS = [
		["formatter", "haxe-formatter 1.9.1 with its six libraries (tokentree, haxeparser, hxparse, json2object, hxargs, hxjsonast): the HaxeBenchmarks formatter case."],
		["self", "The port's own source, about 1,000 modules. Targets without threads or a file system reject it, in both compilers."],
	];

	static function main() {
		load("bench.json", "bench-results", renderBench);
		load("programs.json", "programs-results", renderPrograms);
		load("targets.json", "targets-results", renderTargets);
	}

	static function load<T>(url:String, id:String, render:(Element, T) -> Void) {
		final root = document.getElementById(id);
		if (root == null) return;
		window.fetch(Version.url(url)).then((r) -> r.ok ? r.json() : null).then((d) -> if (d != null) render(root, d)).catchError((_) -> {});
	}

	static function secs(s:Null<Float>):String {
		return s == null ? "–" : s < 10 ? fixed(s, 2) + " s" : s < 100 ? fixed(s, 1) + " s" : Math.round(s) + " s";
	}

	static function ratio(r:Float):String {
		return r < 10 ? fixed(r, 2) + "×" : r < 100 ? fixed(r, 1) + "×" : Math.round(r) + "×";
	}

	static function mb(m:Null<Float>):String {
		return m == null ? "–" : m >= 1024 ? fixed(m / 1024, 1) + " GB" : Math.round(m) + " MB";
	}

	static function size(b:Float):String {
		return b >= 1 << 20 ? fixed(b / (1 << 20), 1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB";
	}

	/** the last line of a failed run's log ("exit 1: <log tail, | for newlines>"), without the exit code */
	static function lastLine(status:String):String {
		final lines = [for (s in status.split(" | ")) if (StringTools.trim(s) != "") StringTools.trim(s)];
		return ~/^exit \d+: /.replace(lines.length > 0 ? lines[lines.length - 1] : "", "");
	}

	/** a cell with a bar for each ratio to the reference, on a log scale shared by the table */
	static function scale(ratios:Array<Float>):(x:Float, ?base:Bool) -> Element {
		var lo = 0.5, hi = 2.0;
		for (r in ratios) {
			lo = Math.min(lo, r);
			hi = Math.max(hi, r);
		}
		final pos = (r:Float) -> 100 * (Math.log(r) - Math.log(lo)) / (Math.log(hi) - Math.log(lo));
		return (x, base = false) -> {
			final bar = el("td", "barcol");
			final track = el("div", "track");
			final fill = el("div", "fill" + (base ? " base" : x < 0.995 ? " fast" : ""));
			fill.style.width = Math.max(1.5, pos(x)) + "%";
			final mark = el("div", "mark");
			mark.style.left = pos(1) + "%";
			track.append(fill, mark, el("span", "lbl", ratio(x)));
			bar.append(track);
			return bar;
		}
	}

	static function failure(text:String, cls:String, span:Int):Element {
		final td:TableCellElement = cast el("td", cls, text);
		td.colSpan = span;
		return td;
	}

	/** one tab and pane per entry, the first one shown */
	static function tabs(root:Element, entries:Array<{label:String, pane:Element}>) {
		root.textContent = "";
		final tabs = el("div", "tabs");
		tabs.setAttribute("role", "tablist");
		for (i => e in entries) {
			final b = el("button", "", e.label);
			b.setAttribute("role", "tab");
			b.setAttribute("aria-selected", i == 0 ? "true" : "false");
			b.onclick = () -> for (j => f in entries) {
				tabs.children[j].setAttribute("aria-selected", j == i ? "true" : "false");
				f.pane.hidden = j != i;
			};
			tabs.append(b);
			e.pane.hidden = i != 0;
		}
		root.append(tabs);
		for (e in entries) root.append(e.pane);
	}

	static function pane(intro:String, table:Element, outro:String):Element {
		final pane = el("div", "pane");
		pane.append(el("p", "note", intro));
		final scroll = el("div", "scroll");
		scroll.append(table);
		pane.append(scroll);
		pane.append(el("p", "note", outro));
		return pane;
	}

	/** a version string without build details ("(…)", "version", quotes, dates) */
	static function version(v:String):String {
		return ~/ \d{4}-\d\d-\d\d$/.replace(~/"/g.replace(~/ version /.replace(~/\s*\([^)]*\)/g.replace(v, ""), " "), ""), "");
	}

	// ---- bench.json

	static function benchTable(rows:Array<{label:String, run:BenchRun}>, ref:BenchRun):Element {
		final t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Runner</th><th class=\"num\">CPU</th><th class=\"barcol\">CPU vs. reference <span class=\"muted\">(log scale)</span></th><th class=\"num wall\">Wall</th><th class=\"num\">Peak RSS</th><th class=\"out\">Output</th></tr></thead>";
		final body = el("tbody");
		final bar = scale([for (r in rows) if (r.run.cpu_min != null) r.run.cpu_min / ref.cpu_min]);
		for (row in rows) {
			final r = row.run, isRef = r.runner == "reference";
			final tr = el("tr", isRef ? "ref" : "");
			final name = el("td", "runner", row.label);
			// on narrow screens the Output column is hidden: a check mark marks verified runs
			if (r.verified) name.append(el("span", "chk", " ✓"));
			if (r.runs != null && r.runs >= 1) name.title = '${r.runs} run${r.runs > 1 ? "s" : ""}';
			tr.append(name);
			if (r.cpu_min == null) {
				tr.append(failure(StringTools.startsWith(r.status, "exit") ? "failed: " + lastLine(r.status).substring(0, 120) : r.status, "fail", 5));
			} else {
				tr.append(el("td", "num", secs(r.cpu_min) + (r.runs == 1 ? "¹" : "")));
				tr.append(bar(r.cpu_min / ref.cpu_min, isRef));
				tr.append(el("td", "num wall", secs(r.wall_min)));
				tr.append(el("td", "num", mb(r.maxrss_mb)));
				tr.append(el("td", "out " + (r.verified ? "ok" : "muted"), isRef ? "baseline" : r.verified ? "identical" : "–"));
			}
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	static function renderBench(root:Element, data:BenchData) {
		final byWorkload = new Map<String, Map<String, BenchRun>>();
		for (r in data.results) {
			if (!byWorkload.exists(r.workload)) byWorkload[r.workload] = new Map();
			byWorkload[r.workload][r.runner] = r;
		}
		final entries = [];
		for (w in WORKLOADS) {
			final runs = byWorkload[w[0]];
			if (runs == null || !runs.exists("reference")) continue;
			final ref = runs["reference"];
			final rows = [for (r in RUNNERS) if (runs.exists(r[0])) {label: r[1], run: runs[r[0]]}];
			final single = Lambda.exists(rows, (r) -> r.run.runs == 1);
			entries.push({
				label: w[0],
				pane: pane(w[1] + ' Reference: ${secs(ref.cpu_min)} CPU, ${mb(ref.maxrss_mb)}.', benchTable(rows, ref),
					"Identical (✓): every .hxb member byte-identical to the reference's. The dashed line marks the reference." + (single ? " ¹ Single run (slow runner)." : ""))
			});
		}
		if (entries.length == 0) return;
		tabs(root, entries);
		final facts = document.getElementById("bench-machine");
		final m = data.meta;
		if (facts == null || m == null) return;
		final parts = [];
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores${m.memory_gb != null ? ', ${Math.round(m.memory_gb)} GB' : ""}');
		if (m.date != null) parts.push('measured ${m.date.substring(0, 10)}');
		if (m.commit != null) parts.push('commit ${m.commit}');
		final v = m.versions != null ? m.versions : new DynamicAccess();
		final tools = [
			for (t in [["reference", "Haxe"], ["node", "Node"], ["wasmtime", ""]])
				if (v[t[0]] != null) (t[1] != "" ? t[1] + " " : "") + version(v[t[0]])
		];
		facts.textContent = parts.join("; ") + (tools.length > 0 ? ". Tools: " + tools.join(", ") + "." : ".");
		final b = data.builds;
		final builds = document.getElementById("bench-builds");
		if (b == null || builds == null) return;
		final line = [];
		if (b["native"] != null) line.push('the x86-64 executable in ${secs(b["native"].wall)} (${size(b["native"].size)}, ${size(b["native"].gzip)} gzipped)');
		if (b["wasm"] != null) line.push('the WebAssembly module in ${secs(b["wasm"].wall)} (${size(b["wasm"].size)}, ${size(b["wasm"].gzip)} gzipped)');
		builds.textContent = "hxmc builds the port from source, cold: " + line.join("; ") + ".";
	}

	// ---- programs.json

	static function renderPrograms(root:Element, data:ProgramData) {
		final t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Program</th><th class=\"num\">x86-64</th><th class=\"num\">wasm, Node</th><th class=\"num\">wasm, wasmtime</th><th class=\"num wall\">Size x86-64 / wasm</th><th class=\"num wall\">Build x86-64 / wasm</th></tr></thead>";
		final body = el("tbody");
		final cell = (r:Null<ProgramRun>) -> el("td", "num", r == null ? "–" : r.error != null ? "failed" : secs(r.run));
		for (p in PROGRAMS) {
			final n = data.results[p[0] + "/hxmc"], wn = data.results[p[0] + "/hxmc-wasm-node"], ww = data.results[p[0] + "/hxmc-wasm-wasmtime"];
			if (n == null && wn == null) continue;
			final tr = el("tr");
			tr.append(el("td", "runner", p[1]));
			tr.append(cell(n));
			tr.append(cell(wn));
			tr.append(cell(ww));
			tr.append(el("td", "num wall", (n != null && n.size != null ? size(n.size) : "–") + " / " + (wn != null && wn.size != null ? size(wn.size) : "–")));
			tr.append(el("td", "num wall", (n != null && n.build != null ? secs(n.build) : "–") + " / " + (wn != null && wn.build != null ? secs(wn.build) : "–")));
			body.append(tr);
		}
		t.append(body);
		root.textContent = "";
		final scroll = el("div", "scroll");
		scroll.append(t);
		root.append(scroll);
		final m = data.meta;
		if (m == null) return;
		final parts = [];
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores');
		if (m.date != null) parts.push('measured ${m.date.substring(0, 10)}');
		if (m.commit != null) parts.push('commit ${m.commit}');
		root.append(el("p", "note", parts.join("; ") + "."));
	}

	// ---- targets.json

	static function targetIndex(target:String):Int {
		for (i => t in TARGETS) if (t[0] == target) return i;
		return -1;
	}

	static function targetsTable(rows:Array<TargetRun>):Element {
		final t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Target</th><th class=\"num\">Reference</th><th class=\"num\">Port</th><th class=\"barcol\">Port CPU vs. reference <span class=\"muted\">(log scale)</span></th><th class=\"num wall\">Peak RSS</th><th class=\"out\">Output</th></tr></thead>";
		final body = el("tbody");
		final bar = scale([for (r in rows) if (r.port != null && r.port.status == "ok") r.port.cpu / r.reference.cpu]);
		for (r in rows) {
			final tr = el("tr");
			final i = targetIndex(r.target);
			final name = el("td", "runner", i >= 0 ? TARGETS[i][1] : r.target);
			if (r.identical) name.append(el("span", "chk", " ✓"));
			tr.append(name);
			if (r.reference.status != "ok") {
				tr.append(failure("the reference compiler rejects this project: " + lastLine(r.reference.status).substring(0, 110), "fail muted", 5));
			} else if (r.port == null || r.port.status != "ok") {
				tr.append(el("td", "num", secs(r.reference.cpu)));
				tr.append(failure("port failed: " + (r.port != null ? r.port.status.substring(0, 110) : "not run"), "fail", 4));
			} else {
				tr.append(el("td", "num", secs(r.reference.cpu)));
				tr.append(el("td", "num", secs(r.port.cpu)));
				tr.append(bar(r.port.cpu / r.reference.cpu));
				tr.append(el("td", "num wall", mb(r.port.rss_mb) + " / " + mb(r.reference.rss_mb)));
				tr.append(el("td", "out " + (r.identical ? "ok" : "fail"),
					r.identical ? 'identical, ${r.port.members > 1 ? r.port.members + " files, " : ""}${size(r.port.bytes)}' : "different"));
			}
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	static function renderTargets(root:Element, data:TargetData) {
		final entries = [];
		for (p in PROJECTS) {
			final rows = data.results.filter((r) -> r.project == p[0]);
			if (rows.length == 0) continue;
			rows.sort((a, b) -> targetIndex(a.target) - targetIndex(b.target));
			final ok = rows.filter((r) -> r.port != null && r.port.status == "ok");
			var ref = 0.0, port = 0.0, same = 0;
			for (r in ok) {
				ref += r.reference.cpu;
				port += r.port.cpu;
				if (r.identical) same++;
			}
			final summary = ok.length > 0 ? ' Over the ${ok.length} targets: ${secs(port)} of CPU for the port, ${secs(ref)} for the reference (${ratio(port / ref)}); ${same} of ${ok.length} outputs identical.' : "";
			entries.push({
				label: p[0],
				pane: pane(p[1] + summary, targetsTable(rows), "CPU: minimum of the runs. Peak RSS: port / reference. The dashed line marks the reference; green bars are faster than it.")
			});
		}
		if (entries.length == 0) return;
		tabs(root, entries);
		final facts = document.getElementById("targets-machine");
		final m = data.meta;
		if (facts == null || m == null) return;
		final parts = [];
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores');
		if (m.date != null) parts.push('measured ${m.date.substring(0, 10)}');
		if (m.commit != null) parts.push('commit ${m.commit}');
		if (m.reference != null) parts.push('reference: ${m.reference}');
		facts.textContent = parts.join("; ") + ".";
	}
}
