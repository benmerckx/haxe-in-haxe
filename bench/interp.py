#!/usr/bin/env python3
"""Eval vs. Eval vs. host: run small programs with the reference's Eval
(`haxe --interp`, OCaml), the port's Eval (`--interp` on the HL/C and HashLink
JIT builds of haxe.Main) and natively on HashLink (compiled by the reference
to .hl, run with `hl`; compile time excluded). Outputs must agree.

`Empty` measures the fixed cost of an --interp invocation (startup plus typing
the std modules a program pulls in); the other rows include it.

Usage: HAXE_REFERENCE=haxe/haxe python3 bench/interp.py [-n RUNS] [workload ...]
"""
import argparse, os, pathlib, statistics, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIR = ROOT / "bench/interp"
WORKLOADS = ["Empty", "Fib", "NBody", "Strings", "Objects", "Json"]


def timed(cmd, env):
    t = time.perf_counter()
    p = subprocess.run(cmd, cwd=DIR, env=env, capture_output=True)
    return time.perf_counter() - t, p.returncode, p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=3)
    ap.add_argument("workloads", nargs="*")
    opts = ap.parse_args()
    ref = str(pathlib.Path(os.environ.get("HAXE_REFERENCE", ROOT / "haxe/haxe")).resolve())
    env = dict(os.environ, HAXE_STD_PATH=str(ROOT / "haxe/std"))
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="hih-interp-bench-"))
    runners = [
        ("reference Eval", lambda w: [ref, "-main", w, "--interp"]),
        ("port Eval (HL/C)", lambda w: [str(ROOT / "bin/bench/hih-hlc"), "-main", w, "--interp"]),
        ("port Eval (HL JIT)", lambda w: ["hl", str(ROOT / "bin/bench/hih.hl"), "-main", w, "--interp"]),
        ("native HashLink", lambda w: ["hl", str(tmp / (w + ".hl"))]),
    ]
    print("%-10s" % "workload" + "".join("%20s" % r[0] for r in runners))
    for w in opts.workloads or WORKLOADS:
        subprocess.run([ref, "-main", w, "--hl", str(tmp / (w + ".hl"))], cwd=DIR, env=env, check=True)
        row, expected = [], None
        for name, cmd in runners:
            times, out = [], None
            exe = pathlib.Path(cmd(w)[1 if name.endswith("JIT)") else 0])
            if name.startswith("port") and not exe.is_file():
                row.append("not built")  # bench/build.sh hl / hlc
                continue
            for _ in range(opts.n):
                t, code, out = timed(cmd(w), env)
                if code != 0:
                    out = None
                    break
                times.append(t)
            if out is None:
                row.append("failed")
                continue
            if expected is None:
                expected = out
            row.append("%.2fs" % statistics.median(times) + ("" if out == expected else " (output differs)"))
        print("%-10s" % w + "".join("%20s" % c for c in row), flush=True)


if __name__ == "__main__":
    main()
