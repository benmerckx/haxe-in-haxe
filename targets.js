// Target generators section: renders targets.json (bench/targets-results.json,
// written by bench/targets.py --json and copied by site/build.sh).
(() => {
	const root = document.getElementById("targets-results");
	if (!root) return;
	const TARGETS = {
		hxb: "HXB", js: "JavaScript", lua: "Lua", python: "Python", php: "PHP", neko: "Neko",
		hl: "HashLink", hlc: "HL/C (sources)", cpp: "C++ (sources)", jvm: "JVM", swf: "Flash (SWF)",
	};
	const PROJECTS = {
		formatter: "haxe-formatter 1.9.1 with its six libraries (tokentree, haxeparser, hxparse, json2object, hxargs, hxjsonast): the HaxeBenchmarks formatter case.",
		self: "The port's own source, about 1,000 modules including the C backend's runtime bindings. Targets without threads or a file system reject it, in both compilers.",
	};
	const el = (tag, cls, text) => {
		const e = document.createElement(tag);
		if (cls) e.className = cls;
		if (text != null) e.textContent = text;
		return e;
	};
	const secs = (s) => s < 10 ? s.toFixed(2) + " s" : s.toFixed(1) + " s";
	const ratio = (r) => r.toFixed(2) + "×";
	const mb = (m) => Math.round(m) + " MB";
	const size = (b) => b >= 1 << 20 ? (b / (1 << 20)).toFixed(1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB";

	function table(rows) {
		const t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Target</th><th class=\"num\">Reference</th><th class=\"num\">Port</th><th class=\"barcol\">Port CPU vs. reference <span class=\"muted\">(log scale)</span></th><th class=\"num wall\">Peak RSS</th><th class=\"out\">Output</th></tr></thead>";
		const body = el("tbody");
		const ok = rows.filter((r) => r.port && r.port.status === "ok");
		const rs = ok.map((r) => r.port.cpu / r.reference.cpu);
		const lo = Math.log(Math.min(0.5, ...rs)), hi = Math.log(Math.max(2, ...rs));
		const pos = (x) => 100 * (Math.log(x) - lo) / (hi - lo);
		for (const r of rows) {
			const tr = el("tr");
			const name = el("td", "runner", TARGETS[r.target] || r.target);
			if (r.identical) name.append(el("span", "chk", " ✓"));
			tr.append(name);
			if (r.reference.status !== "ok") {
				const last = r.reference.status.split(" | ").map((s) => s.trim()).filter((s) => s).pop() || "";
				const td = el("td", "fail muted", "the reference compiler rejects this project: " + last.replace(/^exit \d+: /, "").slice(0, 110));
				td.colSpan = 5;
				tr.append(td);
				body.append(tr);
				continue;
			}
			tr.append(el("td", "num", secs(r.reference.cpu)));
			if (!r.port || r.port.status !== "ok") {
				const td = el("td", "fail", "port failed: " + (r.port ? r.port.status.slice(0, 110) : "not run"));
				td.colSpan = 4;
				tr.append(td);
				body.append(tr);
				continue;
			}
			tr.append(el("td", "num", secs(r.port.cpu)));
			const x = r.port.cpu / r.reference.cpu;
			const bar = el("td", "barcol");
			const track = el("div", "track");
			const fill = el("div", "fill" + (x < 0.995 ? " fast" : ""));
			fill.style.width = Math.max(1.5, pos(x)) + "%";
			const mark = el("div", "mark");
			mark.style.left = pos(1) + "%";
			track.append(fill, mark, el("span", "lbl", ratio(x)));
			bar.append(track);
			tr.append(bar);
			tr.append(el("td", "num wall", mb(r.port.rss_mb) + " / " + mb(r.reference.rss_mb)));
			const out = el("td", "out " + (r.identical ? "ok" : "fail"), r.identical
				? `identical, ${r.port.members > 1 ? r.port.members + " files, " : ""}${size(r.port.bytes)}`
				: "different");
			tr.append(out);
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	function render(data) {
		const byProject = {};
		for (const r of data.results) (byProject[r.project] ||= []).push(r);
		const order = Object.keys(TARGETS);
		for (const p in byProject) byProject[p].sort((a, b) => order.indexOf(a.target) - order.indexOf(b.target));
		const names = Object.keys(PROJECTS).filter((p) => byProject[p]);
		if (!names.length) return;
		root.textContent = "";
		const tabs = el("div", "tabs");
		tabs.setAttribute("role", "tablist");
		const panes = [];
		names.forEach((p, i) => {
			const b = el("button", "", p);
			b.setAttribute("role", "tab");
			b.setAttribute("aria-selected", i === 0 ? "true" : "false");
			b.onclick = () => {
				for (const x of tabs.children) x.setAttribute("aria-selected", x === b ? "true" : "false");
				panes.forEach((q, j) => q.hidden = j !== i);
			};
			tabs.append(b);
			const pane = el("div", "pane");
			pane.hidden = i !== 0;
			const rows = byProject[p];
			const ok = rows.filter((r) => r.port && r.port.status === "ok");
			const ref = ok.reduce((a, r) => a + r.reference.cpu, 0), port = ok.reduce((a, r) => a + r.port.cpu, 0);
			const same = ok.filter((r) => r.identical).length;
			pane.append(el("p", "note", PROJECTS[p] + (ok.length ? ` Over the ${ok.length} targets: ${secs(port)} of CPU for the port, ${secs(ref)} for the reference (${ratio(port / ref)}); ${same} of ${ok.length} outputs identical.` : "")));
			const scroll = el("div", "scroll");
			scroll.append(table(rows));
			pane.append(scroll);
			pane.append(el("p", "note", "CPU: minimum of the runs. Peak RSS: port / reference. The dashed line marks the reference; green bars are faster than it."));
			panes.push(pane);
		});
		root.append(tabs, ...panes);
		const m = data.meta || {};
		const facts = document.getElementById("targets-machine");
		if (facts) {
			const parts = [];
			if (m.cpu) parts.push(`${m.cpu}, ${m.cores} cores`);
			if (m.date) parts.push(`measured ${m.date.slice(0, 10)}`);
			if (m.commit) parts.push(`commit ${m.commit}`);
			if (m.reference) parts.push(`reference: ${m.reference}`);
			facts.textContent = parts.join("; ") + ".";
		}
	}

	fetch("targets.json").then((r) => r.ok ? r.json() : null).then((d) => d && render(d)).catch(() => {});
})();
