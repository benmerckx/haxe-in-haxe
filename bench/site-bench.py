#!/usr/bin/env python3
"""Run benchs.haxe.org workloads locally, with hxc and fast baselines only.

Uses the pinned haxe/ executable and std. Sources and data live outside the
checkout. Build everything for a case before timing; execute one process at a
time, one untimed process warm-up, then interleaved measured processes. These
are end-to-end process times (JIT startup/GC included), not steady-state loops.
Upstream workloads generally have no observable checksum: exit success is a
smoke test, not proof of numerical equivalence. No source or iteration changes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shlex
import signal
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "binarytrees": ("BMBinaryTreesCode", [], [], 180),
    "nbody": ("BMNBodyCode", [], [], 180),
    "sha256": ("BMSHA256Code", [], [], 240),
    "sha512": ("BMSHA512Code", ["crypto"], [], 120),
    "bcrypt": ("BMBCryptCode", ["crypto"], [], 180),
    "json": ("BMJsonCode", [], [], 60),
    "alloc": ("BMAllocCode", [], [], 360),
    "mandelbrot": ("BMMandelbrotCode", [], [], 300),
    "mandelbrot_anon_objects": ("BMMandelbrotCode", [], ["anon_objects"], 180),
    "formatter_noio": ("BMFormatterNoIOCode", ["tokentree", "haxeparser", "hxparse", "json2object", "hxargs", "formatter"], [], 300),
    "formatter": ("BMFormatterCode", ["tokentree", "haxeparser", "hxparse", "json2object", "hxargs", "formatter"], [], 300),
    "dox": ("BMDoxCode", ["hxtemplo", "hxparse", "hxargs", "markdown"], [], 180),
}
TARGETS = ["hxc", "cpp", "cppGCGen", "hl", "hlc", "jvm", "js", "js-es6"]

def capture(cmd, cwd=ROOT):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return (p.stdout + p.stderr).strip()

def run_process(cmd, cwd, log, timeout):
    """wait4 returns this child's CPU and RSS, rather than cumulative children."""
    start = time.perf_counter()
    timed_out = False
    with log.open("wb") as output:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        while True:
            pid, status, usage = os.wait4(p.pid, os.WNOHANG)
            if pid:
                break
            if time.perf_counter() - start > timeout:
                timed_out = True
                os.killpg(p.pid, signal.SIGKILL)
                _, status, usage = os.wait4(p.pid, 0)
                break
            time.sleep(0.005)
        p.returncode = os.waitstatus_to_exitcode(status)
    return dict(wall_s=time.perf_counter() - start, cpu_s=usage.ru_utime + usage.ru_stime,
                max_rss_kib=usage.ru_maxrss, exit_code=p.returncode, timeout=timed_out)

def tree_hash(path):
    digest = hashlib.sha256()
    count = 0
    for p in sorted(path.rglob("*")):
        if p.is_file() and ".git" not in p.relative_to(path).parts:
            digest.update(str(p.relative_to(path)).encode() + b"\0" + p.read_bytes())
            count += 1
    return {"sha256": digest.hexdigest(), "files": count}

def compile_case(case, target, options, out):
    main, libs, defines, _ = CASES[case]
    cp = options.sources / "cases" / case
    args = ["-cp", str(cp), "-main", main]
    if case == "mandelbrot_anon_objects":
        args += ["-cp", str(options.sources / "cases/mandelbrot")]
    if case == "dox":
        args += ["-cp", str(options.dox / "src"), "-dce", "no"]
    for lib in libs:
        if target == "hxc":
            # The JS-hosted frontend cannot spawn haxelib. Resolve the same
            # classpaths/defines using the reference haxelib before invoking it.
            lookup = ["haxelib", "path", lib]
            started = time.perf_counter()
            try:
                paths = subprocess.check_output(lookup, text=True, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError as e:
                (out / (target + "-dependency.log")).write_text(e.output)
                return None, [{"command": lookup, "wall_s": time.perf_counter() - started,
                               "exit_code": e.returncode, "error": e.output}]
            for line in paths.splitlines():
                line = line.strip()
                if line.startswith("Warning:"):
                    continue
                if line.startswith("-D "):
                    args += ["-D", line[3:]]
                elif line and not line.startswith("-"):
                    args += ["-cp", line]
                elif line:
                    raise RuntimeError("Unsupported haxelib option: " + line)
        else:
            args += ["-lib", lib]
    for define in defines:
        args += ["-D", define]
    commands = []
    if target == "hxc":
        generated = out / "hxc"
        commands.append(["node", "--stack-size=65500", str(ROOT / "bin/backend/wbk.js"), str(generated)] + args
                        + ["-cp", str(ROOT / "backend/std"), "--custom-target", "hxc", "-D", "disable-parallelism"])
        commands.append(shlex.split(options.cc) + ["-w", "-fno-strict-aliasing", "-DHXC_NO_SSL", "-DHXC_NO_UV",
                        "-I", str(ROOT / "backend/rt"), str(generated) + ".c"]
                        + [str(p) for p in sorted((ROOT / "backend/rt").glob("rt*.c"))]
                        + ["-lm", "-o", str(generated)])
        runtime = [str(generated)]
    else:
        cmd = [str(ROOT / "haxe/haxe")] + args
        if target in ("cpp", "cppGCGen"):
            dest = out / target
            cmd += ["--cpp", str(dest), "-D", "HXCPP_COMPILE_THREADS=4"]
            if target == "cppGCGen":
                cmd += ["-D", "HXCPP_GC_GENERATIONAL"]
            runtime = [str(dest / main)]
        elif target == "hl":
            dest = out / "hl.hl"
            cmd += ["--hl", str(dest)]
            runtime = [str(options.hashlink / "hl"), str(dest)]
        elif target == "hlc":
            dest = out / "hlc/main.c"
            cmd += ["--hl", str(dest), "-D", "no-compilation"]
            commands.append(cmd)
            cmd = ["gcc", "-O3", "-std=c11", "-I", str(options.hashlink / "src"), "-I", str(dest.parent),
                   str(dest), "-L", str(options.hashlink), "-Wl,-rpath," + str(options.hashlink), "-lhl", "-lm",
                   str(options.hashlink / "fmt.hdll"), "-o", str(dest.parent / "prog")]
            runtime = [str(dest.parent / "prog")]
        elif target == "jvm":
            dest = out / "jvm.jar"
            cmd += ["-lib", "hxjava", "--jvm", str(dest)]
            runtime = ["java", "-jar", str(dest)]
        else:
            dest = out / (target + ".js")
            cmd += ["-lib", "hxnodejs", "--js", str(dest)]
            if target == "js-es6":
                cmd += ["-D", "js-es=6"]
            runtime = ["node", str(dest)]
        commands.append(cmd)
    if case == "formatter":
        for name, sub in [("haxe", "std"), ("openfl", "src"), ("lime", "src")]:
            runtime += ["-s", str(cp / "data" / name / sub)]
    elif case == "dox":
        runtime += ["-theme", str(options.dox / "themes/default"), "-i", str(cp / "data")]
    results = []
    for i, cmd in enumerate(commands):
        sample = run_process(cmd, ROOT, out / (target + f"-build-{i}.log"), 900)
        sample["command"] = cmd
        results.append(sample)
        if sample["exit_code"]:
            return None, results
    return runtime, results

def reset_data(case, o):
    if case == "formatter":
        for name in ("haxe", "openfl", "lime"):
            p = o.sources / "cases/formatter/data" / name
            subprocess.run(["git", "-C", str(p), "checkout", "--", "."], check=True, stdout=subprocess.DEVNULL)
    if case == "dox":
        import shutil
        shutil.rmtree(o.sources / "cases/dox/benchmark-run/pages", ignore_errors=True)

def summarize(rows):
    for row in rows:
        samples = row["samples"]
        # Partial/failing targets never receive a successful aggregate.
        if row["status"] == "success":
            row["median_wall_s"] = statistics.median(s["wall_s"] for s in samples)
            row["min_wall_s"] = min(s["wall_s"] for s in samples)
            row["max_wall_s"] = max(s["wall_s"] for s in samples)
            row["median_cpu_s"] = statistics.median(s["cpu_s"] for s in samples)
            row["max_rss_kib"] = max(s["max_rss_kib"] for s in samples)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sources", type=Path, required=True)
    p.add_argument("--hashlink", type=Path, required=True)
    p.add_argument("--dox", type=Path)
    p.add_argument("--cc", default="gcc -O2")
    p.add_argument("-n", type=int, default=3)
    p.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    p.add_argument("--targets", nargs="+", choices=TARGETS, default=TARGETS)
    p.add_argument("--reuse", action="store_true", help="reuse successful commands from a previous run")
    p.add_argument("--output", type=Path, default=ROOT / "bin/site-bench/results.json")
    o = p.parse_args()
    if o.n < 1:
        p.error("-n must be positive")
    if "dox" in o.cases and o.dox is None:
        p.error("--dox is required for the dox case")
    for key in ("sources", "hashlink", "dox", "output"):
        if getattr(o, key) is not None:
            setattr(o, key, getattr(o, key).resolve())
    os.environ["HAXE_STD_PATH"] = str(ROOT / "haxe/std")
    os.environ["LD_LIBRARY_PATH"] = str(o.hashlink) + ":" + os.environ.get("LD_LIBRARY_PATH", "")
    o.output.parent.mkdir(parents=True, exist_ok=True)
    previous = json.loads(o.output.read_text()) if o.output.exists() else {}
    results = {"metadata": {"created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "haxe_commit": capture(["git", "-C", "haxe", "rev-parse", "HEAD"]),
               "haxe_version": capture(["haxe/haxe", "-version"]),
               "benchmark_commit": capture(["git", "-C", str(o.sources), "rev-parse", "HEAD"]),
               "hashlink_commit": capture(["git", "-C", str(o.hashlink), "rev-parse", "HEAD"]),
               "cpu": capture(["lscpu"]), "platform": platform.platform(),
               "node": capture(["node", "--version"]), "java": capture(["java", "-version"]),
               "gcc": capture(["gcc", "--version"]), "cc": o.cc, "samples": o.n,
               "method": "interleaved fresh-process wall times; 1 process warm-up; median; unchanged upstream workloads",
               "validation": "successful exit only; upstream workloads generally do not print checksums"},
               "cases": previous.get("cases", {})}
    def save():
        temp = o.output.with_suffix(".tmp")
        temp.write_text(json.dumps(results, indent=2) + "\n")
        temp.replace(o.output)
    for case in o.cases:
        out = o.output.parent / case
        out.mkdir(parents=True, exist_ok=True)
        cwd = o.sources / "cases" / case / "benchmark-run"
        cwd.mkdir(parents=True, exist_ok=True)
        if case == "dox":
            import shutil
            (cwd / "resources").mkdir(exist_ok=True)
            shutil.copy2(o.dox / "resources/meta.json", cwd / "resources/meta.json")
        data = o.sources / "cases" / case / "data"
        entry = {"rows": [], "data": tree_hash(data) if data.exists() else None}
        old_rows = {r["target"]: r for r in results["cases"].get(case, {}).get("rows", [])}
        results["cases"][case] = entry
        print("BUILD " + case, flush=True)
        for target in o.targets:
            old = old_rows.get(target)
            if o.reuse and old and old.get("command") and all(s["exit_code"] == 0 for s in old["builds"]):
                runtime, builds = old["command"], old["builds"]
            else:
                runtime, builds = compile_case(case, target, o, out)
            row = {"target": target, "command": runtime, "builds": builds, "samples": [],
                   "compile_wall_s": sum(s["wall_s"] for s in builds), "status": "ready" if runtime else "compile-failed"}
            entry["rows"].append(row)
            print("  " + target + ": " + row["status"], flush=True)
            save()
        active = [r for r in entry["rows"] if r["command"]]
        for round_index in range(o.n + 1):
            order = active.copy()
            random.Random(4300 + round_index).shuffle(order)
            for row in order:
                if row["status"] in ("runtime-failed", "timeout"):
                    continue
                reset_data(case, o)
                sample = run_process(row["command"], cwd, out / (row["target"] + f"-run-{round_index}.log"), CASES[case][3])
                if round_index == 0:
                    row["warmup"] = sample
                else:
                    row["samples"].append(sample)
                if sample["exit_code"]:
                    row["status"] = "timeout" if sample["timeout"] else "runtime-failed"
                    print("  " + row["target"] + ": " + row["status"], flush=True)
                save()
        for row in active:
            if row["status"] == "ready":
                row["status"] = "success"
        summarize(entry["rows"])
        save()
        print("RESULT " + case + " " + json.dumps({r["target"]: round(r["median_wall_s"], 4) if r["status"] == "success" else r["status"] for r in entry["rows"]}), flush=True)

if __name__ == "__main__":
    main()
