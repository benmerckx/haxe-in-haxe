#!/usr/bin/env python3
"""Run untimed JSON EOF and Formatter NoIO output audits after timing finishes."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("site_bench", ROOT / "bench/site-bench.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sources", required=True, type=Path)
    p.add_argument("--hashlink", required=True, type=Path)
    o = p.parse_args()
    o.sources = o.sources.resolve()
    o.hashlink = o.hashlink.resolve()
    o.dox = None
    o.cc = "gcc -O2"
    os.environ["HAXE_STD_PATH"] = str(ROOT / "haxe/std")
    output = ROOT / "bin/site-bench/audits"
    output.mkdir(parents=True, exist_ok=True)
    results = {}
    for name, libs in [("JsonEofAudit", []), ("FormatterAudit", bench.CASES["formatter_noio"][1])]:
        cp = o.sources / "cases" / name
        cp.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "bench/site-bench-verify" / (name + ".hx"), cp)
        bench.CASES[name] = (name, libs, [], 120)
        results[name] = {}
        for target in ("hxc", "js-es6"):
            out = output / (name + "-" + target)
            out.mkdir(exist_ok=True)
            command, builds = bench.compile_case(name, target, o, out)
            row = {"command": command, "builds": builds}
            if command:
                if name == "FormatterAudit":
                    command += [str(o.sources / "cases/formatter_noio/data")]
                log = out / "run.log"
                row["process"] = bench.run_process(command, ROOT, log, 120)
                row["output"] = log.read_text(errors="replace")
            results[name][target] = row
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(name, target, row.get("output", "compile-failed"), flush=True)

if __name__ == "__main__":
    main()
