// Benchmarks section: renders bench.json (bench/results.json, written by
// bench/run.py --json and copied by site/build.sh).
(() => {
	const root = document.getElementById("bench-results");
	if (!root) return;
	const RUNNERS = [
		["reference", "OCaml reference"],
		["eval-source", "Eval, from source"],
		["eval-hxb", "Eval, from HXB"],
		["hl", "HashLink JIT"],
		["hlc", "HL/C"],
		["js", "JS (Node)"],
		["jvm", "JVM"],
		["cpp", "C++ (hxcpp)"],
		["hxc", "hxc, tcc"],
		["hxc-o2", "hxc, gcc -O2"],
		["hxc-cosmo", "hxc, cosmocc"],
		["wasm", "hxc, wasm (Node)"],
	];
	const WORKLOADS = {
		self: "The port's own source: 52k lines in 382 modules, with std macros run by the Eval interpreter.",
		stdlib: "32 standard library modules (JSON, XML, zip, crypto, data structures) as roots.",
		hello: "Hello world: mostly start-up time and the core standard library.",
	};
	const el = (tag, cls, text) => {
		const e = document.createElement(tag);
		if (cls) e.className = cls;
		if (text != null) e.textContent = text;
		return e;
	};
	const secs = (s) => s == null ? "–" : s < 10 ? s.toFixed(2) + " s" : s < 100 ? s.toFixed(1) + " s" : Math.round(s) + " s";
	const ratio = (r) => r < 10 ? r.toFixed(2) + "×" : r < 100 ? r.toFixed(1) + "×" : Math.round(r) + "×";
	const mb = (m) => m == null ? "–" : m >= 1024 ? (m / 1024).toFixed(1) + " GB" : Math.round(m) + " MB";

	function table(rows, ref) {
		const t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Runner</th><th class=\"num\">CPU</th><th class=\"barcol\">CPU vs. reference <span class=\"muted\">(log scale)</span></th><th class=\"num wall\">Wall</th><th class=\"num\">Peak RSS</th><th class=\"out\">Output</th></tr></thead>";
		const body = el("tbody");
		const ok = rows.filter((r) => r.cpu_min != null);
		const rs = ok.map((r) => r.cpu_min / ref.cpu_min);
		const lo = Math.log(Math.min(0.5, ...rs)), hi = Math.log(Math.max(2, ...rs));
		const pos = (r) => 100 * (Math.log(r) - lo) / (hi - lo);
		for (const r of rows) {
			const tr = el("tr", r.runner === "reference" ? "ref" : "");
			const name = el("td", "runner", r.label);
			// on narrow screens the Output column is hidden: a check mark marks verified runs
			if (r.verified) name.append(el("span", "chk", " ✓"));
			if (r.runs > 1 || r.runs === 1) name.title = `${r.runs} run${r.runs > 1 ? "s" : ""}`;
			tr.append(name);
			if (r.cpu_min == null) {
				// "exit 1: <log tail with | for newlines>": the last log line is the error
				const last = r.status.split(" | ").map((s) => s.trim()).filter((s) => s).pop() || r.status;
				const td = el("td", "fail", r.status.startsWith("exit") ? "failed: " + last.replace(/^exit \d+: /, "").slice(0, 120) : r.status);
				if (r.note) td.textContent += ". " + r.note;
				td.colSpan = 5;
				tr.append(td);
				body.append(tr);
				continue;
			}
			const x = r.cpu_min / ref.cpu_min;
			tr.append(el("td", "num", secs(r.cpu_min) + (r.runs === 1 ? "¹" : "")));
			const bar = el("td", "barcol");
			const track = el("div", "track");
			const fill = el("div", "fill" + (r.runner === "reference" ? " base" : x < 0.995 ? " fast" : ""));
			fill.style.width = Math.max(1.5, pos(x)) + "%";
			const mark = el("div", "mark");
			mark.style.left = pos(1) + "%";
			track.append(fill, mark, el("span", "lbl", ratio(x)));
			bar.append(track);
			tr.append(bar);
			tr.append(el("td", "num wall", secs(r.wall_min)));
			tr.append(el("td", "num", mb(r.maxrss_mb)));
			tr.append(el("td", "out " + (r.verified ? "ok" : "muted"), r.runner === "reference" ? "baseline" : r.verified ? "identical" : "–"));
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	function render(data) {
		const byWorkload = {};
		for (const r of data.results) (byWorkload[r.workload] ||= {})[r.runner] = r;
		const names = Object.keys(WORKLOADS).filter((w) => byWorkload[w] && byWorkload[w].reference);
		if (!names.length) return;
		root.textContent = "";
		const tabs = el("div", "tabs");
		tabs.setAttribute("role", "tablist");
		const panes = [];
		names.forEach((w, i) => {
			const b = el("button", "", w);
			b.setAttribute("role", "tab");
			b.setAttribute("aria-selected", i === 0 ? "true" : "false");
			b.onclick = () => {
				for (const x of tabs.children) x.setAttribute("aria-selected", x === b ? "true" : "false");
				panes.forEach((p, j) => p.hidden = j !== i);
			};
			tabs.append(b);
			const pane = el("div", "pane");
			pane.hidden = i !== 0;
			const rows = [];
			for (const [id, label] of RUNNERS) if (byWorkload[w][id]) rows.push(Object.assign({label, note: (data.notes || {})[w + "/" + id]}, byWorkload[w][id]));
			const ref = byWorkload[w].reference;
			pane.append(el("p", "note", WORKLOADS[w] + ` Reference: ${secs(ref.cpu_min)} CPU, ${mb(ref.maxrss_mb)}.`));
			const scroll = el("div", "scroll");
			scroll.append(table(rows, ref));
			pane.append(scroll);
			pane.append(el("p", "note", "Identical (✓): every .hxb member byte-identical to the reference's. The dashed line marks the reference." + (rows.some((r) => r.runs === 1) ? " ¹ Single run (slow runner)." : "")));
			panes.push(pane);
		});
		root.append(tabs, ...panes);
		const m = data.meta || {}, v = m.versions || {};
		const facts = document.getElementById("bench-machine");
		if (facts) {
			const parts = [];
			if (m.cpu) parts.push(`${m.cpu}, ${m.cores} cores${m.memory_gb ? `, ${Math.round(m.memory_gb)} GB` : ""}`);
			if (m.date) parts.push(`measured ${m.date.slice(0, 10)}`);
			if (m.commit) parts.push(`commit ${m.commit}`);
			const tools = [["reference", "Haxe"], ["node", "Node"], ["node_wasm", "Node (wasm)"], ["hl", "HashLink"], ["java", ""], ["gcc", ""], ["tcc", ""], ["cosmocc", ""], ["emcc", ""]]
				.filter(([k]) => v[k]).map(([k, n]) => (n ? n + " " : "") + v[k].replace(/\s*\([^)]*\)/g, "").replace(/ version /, " ").replace(/"/g, "").replace(/ \d{4}-\d\d-\d\d$/, ""));
			facts.textContent = parts.join("; ") + (tools.length ? ". Tools: " + tools.join(", ") + "." : ".");
		}
	}

	fetch("bench.json").then((r) => r.ok ? r.json() : null).then((d) => d && render(d)).catch(() => {});
})();
