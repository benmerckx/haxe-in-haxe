#!/usr/bin/env python3
"""HXB conformance harness for the translated compiler (haxe.Main).

For every case in test/conformance-cases.txt:

1. The pinned reference compiles the case to HXB.
2. The port (HashLink build, see below) compiles the same invocation.
3. Both archives must have the same member set and byte-identical
   uncompressed .hxb payloads (ZIP container bytes are never compared).
4. The reference must consume the port's archive without the case's source
   class path.
5. With --eval, the port executed from Eval HXB and from source on Eval must
   produce the same member set and payloads.
6. With --hxb-lib, both compilers load every module of the reference archive
   back through --hxb-lib (without the case's source class path) and write
   it again; the two outputs must conform.

`hxblib` cases first build a library archive with the reference and compile
the case against it with --hxb-lib (HXB library input).

A case the reference rejects is an expected-failure case: the port must reject
it as well. Both invocations use -D disable-parallelism: the reference
allocates variable IDs from a global counter shared by parallel filter
workers, so its own output is otherwise not reproducible run to run.

By default the port is compiled to HashLink bytecode and executed with `hl`
(HAXE_HL selects the VM), which is an order of magnitude faster than Eval.
HAXE_IN_HAXE_PORT replaces that with another prebuilt port command, for
example "node bin/bench/hih.js" from bench/build.sh.
--eval additionally executes the port from an Eval HXB archive built by the
reference and from source on Eval, and requires both to reproduce the
HashLink output exactly (Eval-HXB host execution parity).

--parallel N runs the port N times per case without -D disable-parallelism
(the parallel filters, analyzer, DCE and HXB writer of a threaded build,
e.g. the 1:1 hxc build) instead of the comparisons above. Every run must
succeed, the reference must load every archive, and each archive must match
the sequential reference archive after normalizing variable IDs: the
reference loads both through --hxb-lib (fresh IDs, allocated in reading
order) and writes them again with -D disable-parallelism. Raw identity is
reported too. --parallel-reference also runs the reference itself in
parallel mode N times through the same check, for comparison.

Usage: HAXE_REFERENCE=haxe/haxe python3 test/conformance.py [-j N] [--eval] [--hxb-lib] [--parallel N [--parallel-reference]] [name-substring ...]
"""
import argparse, concurrent.futures, os, pathlib, shlex, shutil, subprocess, sys, tempfile, time, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
STD = ROOT / "haxe/std"
GENERATED = ROOT / "test/generated/conformance"
STACK = ["-D", "eval-call-stack-depth=10000"]
COMMON = ["-D", "disable-parallelism", "--interp", "--no-output"]
TIMEOUT = 900


def parse_cases(cases_file):
    cases = []
    for line in cases_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = shlex.split(line)
        kind, name = parts[0], parts[1]
        if kind == "direct":
            cases.append(dict(kind=kind, name=name, cwd=ROOT, args=["-cp", parts[2], "--main", parts[3]]))
        elif kind == "module":
            cases.append(dict(kind=kind, name=name, cwd=ROOT, args=["-cp", parts[2], parts[3]]))
        elif kind == "hxblib":
            # hxblib <name> <dir> "<library arguments>" "<arguments>": the
            # reference compiles the library arguments to an HXB archive, and
            # both compilers compile the arguments against it with --hxb-lib.
            # As for hxml cases, the arguments select their own target.
            cases.append(dict(kind=kind, name=name, cwd=ROOT / parts[2], lib=shlex.split(parts[3]), args=shlex.split(parts[4]), hxml=True))
        elif kind == "volatile":
            # volatile <case> <member> <reason ...>: the member's payload depends on the
            # time of compilation (a macro embeds Date.now()), so two invocations cannot
            # produce the same bytes; it must exist in both archives but is not compared.
            case = next(c for c in cases if c["name"] == name)
            case.setdefault("volatile", set()).add(parts[2])
        elif kind == "hxml":
            # HXML configurations select their own target; only defines and the output are added.
            # Arguments after the hxml are passed after it (hxml <name> <dir> <hxml> [argument ...]).
            cases.append(dict(kind=kind, name=name, cwd=ROOT / parts[2], args=parts[3:], hxml=True))
        else:
            raise SystemExit("Unknown case kind: " + line)
    return cases


def run(cmd, cwd, log, env):
    start = time.monotonic()
    try:
        with open(log, "wb") as stream:
            code = subprocess.run(cmd, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        code = "timeout"
    return code, time.monotonic() - start


def first_error(log):
    try:
        text = pathlib.Path(log).read_text(errors="replace")
    except OSError:
        return ""
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("Called from")]
    for l in lines:
        if l.startswith("|"):
            content = l[1:].strip()
            if content and not set(content) <= set("^ ") and content != "[...]":
                return content[:200]
    return (lines[-1] if lines else "")[:200]


def compare(expected, actual, volatile=()):
    """Returns None when the archives conform, otherwise a description."""
    try:
        a = zipfile.ZipFile(expected)
        b = zipfile.ZipFile(actual)
    except (OSError, zipfile.BadZipFile) as e:
        return "unreadable archive: %s" % e
    na, nb = set(a.namelist()), set(b.namelist())
    if na != nb:
        only_a = sorted(na - nb)
        only_b = sorted(nb - na)
        return "member set differs (reference-only %d %s, port-only %d %s)" % (len(only_a), only_a[:3], len(only_b), only_b[:3])
    diffs = []
    for name in sorted(na):
        if not name.endswith(".hxb") or name in volatile:
            continue
        x, y = a.read(name), b.read(name)
        if x != y:
            i = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
            diffs.append("%s@%d" % (name, i))
    if diffs:
        return "%d/%d payloads differ: %s" % (len(diffs), len(na), " ".join(diffs[:4]))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--eval", action="store_true")
    ap.add_argument("--hxb-lib", action="store_true", help="also load each reference archive back through --hxb-lib with both compilers and compare their output")
    ap.add_argument("--cases", default="test/conformance-cases.txt", help="case list (test/conformance-macro-cases.txt: cases that run macros)")
    ap.add_argument("--parallel", type=int, default=0, metavar="N", help="run the port N times per case in parallel mode (no -D disable-parallelism) and check its archives against the sequential reference after normalizing variable IDs")
    ap.add_argument("--parallel-reference", action="store_true", help="with --parallel, also run the reference in parallel mode through the same check")
    ap.add_argument("filters", nargs="*")
    opts = ap.parse_args()
    reference = os.environ.get("HAXE_REFERENCE")
    if not reference or not os.access(reference, os.X_OK):
        raise SystemExit("HAXE_REFERENCE must be the executable built from the pinned haxe/ submodule.")
    reference = os.path.abspath(reference)
    env = os.environ.copy()
    env["HAXE_STD_PATH"] = str(STD)
    env["HAXE_IN_HAXE_STD_PATH"] = str(STD)
    # Upstream suites that use utest (-lib utest, test/conformance-upstream-cases.txt) find it in
    # the haxelib repository test/upstream.py sets up; local repositories (.haxelib) still win.
    upstream_haxelib = ROOT / "test/generated/upstream/.haxelib"
    if "HAXELIB_PATH" not in env and upstream_haxelib.is_dir():
        env["HAXELIB_PATH"] = str(upstream_haxelib)

    cases = [c for c in parse_cases(ROOT / opts.cases) if not opts.filters or any(f in c["name"] for f in opts.filters)]
    GENERATED.mkdir(parents=True, exist_ok=True)
    if os.environ.get("HAXE_IN_HAXE_PORT"):
        # Another build of the port, e.g. "node --stack-size=65500 bin/bench/hih.js" (see bench/build.sh).
        port_cmd = [str(ROOT / a) if (ROOT / a).is_file() else a for a in shlex.split(os.environ["HAXE_IN_HAXE_PORT"])]
    else:
        hl = os.environ.get("HAXE_HL") or shutil.which("hl")
        if not hl:
            raise SystemExit("HashLink (hl) not found; set HAXE_HL")
        port_hl = GENERATED / "haxe-in-haxe.hl"
        code, _ = run([reference, "-cp", str(ROOT / "runtime/hl"), "-cp", str(ROOT / "src"), "-main", "haxe.Main", "-hl", str(port_hl)], ROOT, GENERATED / "build-hl.log", env)
        if code != 0:
            raise SystemExit("Building the port for HashLink failed; see " + str(GENERATED / "build-hl.log"))
        port_cmd = [hl, str(port_hl)]
    compiler = GENERATED / "haxe-in-haxe.eval.hxb"
    if opts.eval:
        code, _ = run([reference, "-cp", str(ROOT / "src"), "-main", "haxe.Main", "--interp", "--no-output", "--hxb", str(compiler)], ROOT, GENERATED / "build.log", env)
        if code != 0:
            raise SystemExit("Building the port as Eval HXB failed; see " + str(GENERATED / "build.log"))
        if "eval/haxe/Main.hxb" not in zipfile.ZipFile(compiler).namelist():
            raise SystemExit("Compiler archive does not contain eval/haxe/Main.hxb")

    def run_case(case):
        out = GENERATED / case["name"]
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        cwd = case["cwd"]
        ref_hxb, port_hxb, src_hxb = out / "reference.hxb", out / "port.hxb", out / "source.hxb"
        def invocation(hxb):
            # An HXML configuration may end in --run, which takes all following
            # arguments, so the output and defines precede it; --no-output keeps
            # the reference from executing the program.
            if case.get("hxml"):
                return ["--hxb", str(hxb), "-D", "disable-parallelism", "--no-output"] + case["args"]
            return COMMON + case["args"] + ["--hxb", str(hxb)]
        if case.get("lib"):
            lib_hxb = out / "lib.hxb"
            lc, _ = run([reference, "--hxb", str(lib_hxb), "-D", "disable-parallelism", "--no-output"] + case["lib"], cwd, out / "lib.log", env)
            if lc != 0:
                return dict(name=case["name"], seconds=0, status="FAIL", detail="reference cannot build the library: " + first_error(out / "lib.log"))
            case = dict(case, args=["--hxb-lib", str(lib_hxb)] + case["args"])
        rc, rt = run([reference] + invocation(ref_hxb), cwd, out / "reference.log", env)
        pc, pt = run(port_cmd + invocation(port_hxb), cwd, out / "port.log", env)
        result = dict(name=case["name"], seconds=round(rt + pt, 1))
        if rc != 0:
            if pc == 0:
                result.update(status="FAIL", detail="reference rejects (%s) but port accepts" % first_error(out / "reference.log"))
            else:
                result.update(status="EXPECTED-FAILURE", detail="both reject: " + first_error(out / "reference.log"))
            return result
        if pc != 0:
            result.update(status="FAIL", detail="port failed (%s): %s" % (pc, first_error(out / "port.log")))
            return result
        volatile = case.get("volatile", set())
        diff = compare(ref_hxb, port_hxb, volatile)
        if diff:
            result.update(status="FAIL", detail=diff)
            return result
        # Every module of the archive is a root: the reference must load all of
        # them from the archive alone, without the case's source class path.
        names = [n for n in zipfile.ZipFile(port_hxb).namelist() if n.endswith(".hxb")]
        target = ["--interp", "--no-output"] if any(n.startswith("eval/") for n in names) else ["--no-output"]
        roots = [n.split("/", 1)[1][:-4].replace("/", ".") for n in names]
        cc, _ = run([reference, "--hxb-lib", str(port_hxb)] + target + roots, ROOT, out / "consume.log", env)
        if cc != 0:
            # Modules built by macros need the macro's source to load; that
            # only counts against the port if the reference's own archive loads.
            rc, _ = run([reference, "--hxb-lib", str(ref_hxb)] + target + roots, ROOT, out / "consume-reference.log", env)
            if rc == 0:
                result.update(status="FAIL", detail="reference cannot consume port archive: " + first_error(out / "consume.log"))
                return result
            result["note"] = " (neither archive loads without the case's source: " + first_error(out / "consume-reference.log") + ")"
        if opts.hxb_lib:
            # HXB library input: both compilers load every module of the
            # reference archive through --hxb-lib (no source class path) and
            # write it again; the outputs must conform.
            def roundtrip(hxb):
                return ["--hxb-lib", str(ref_hxb), "-D", "disable-parallelism"] + target + roots + ["--hxb", str(hxb)]
            rt_ref, rt_port = out / "roundtrip-reference.hxb", out / "roundtrip-port.hxb"
            rrc, rrt = run([reference] + roundtrip(rt_ref), ROOT, out / "roundtrip-reference.log", env)
            rpc, rpt = run(port_cmd + roundtrip(rt_port), ROOT, out / "roundtrip-port.log", env)
            result["seconds"] = round(result["seconds"] + rrt + rpt, 1)
            if rrc != 0:
                if rpc == 0:
                    result.update(status="FAIL", detail="reference rejects the --hxb-lib round trip (%s) but port accepts" % first_error(out / "roundtrip-reference.log"))
                    return result
                result["note"] = result.get("note", "") + " (--hxb-lib round trip rejected by both: " + first_error(out / "roundtrip-reference.log") + ")"
            elif rpc != 0:
                result.update(status="FAIL", detail="port failed the --hxb-lib round trip (%s): %s" % (rpc, first_error(out / "roundtrip-port.log")))
                return result
            else:
                diff = compare(rt_ref, rt_port)
                if diff:
                    result.update(status="FAIL", detail="--hxb-lib round trip: " + diff)
                    return result
                result["note"] = result.get("note", "") + " (--hxb-lib round trip identical)"
        if opts.eval:
            eval_hxb = out / "eval-hxb.hxb"
            ec, et = run([reference] + STACK + ["--hxb-lib", str(compiler), "--run", "haxe.Main"] + invocation(eval_hxb), cwd, out / "eval-hxb.log", env)
            sc, st = run([reference] + STACK + ["-cp", str(ROOT / "src"), "--run", "haxe.Main"] + invocation(src_hxb), cwd, out / "source.log", env)
            result["seconds"] = round(result["seconds"] + et + st, 1)
            for code, hxb, what, log in [(ec, eval_hxb, "Eval-HXB-executed", "eval-hxb.log"), (sc, src_hxb, "source-executed", "source.log")]:
                if code != 0:
                    result.update(status="FAIL", detail="%s port failed: %s" % (what, first_error(out / log)))
                    return result
                diff = compare(port_hxb, hxb, volatile)
                if diff:
                    result.update(status="FAIL", detail="%s port differs from HashLink-executed port: %s" % (what, diff))
                    return result
        members = len(zipfile.ZipFile(ref_hxb).namelist())
        if volatile:
            result["note"] = " (%d volatile not compared)" % len(volatile) + result.get("note", "")
        result.update(status="PASS", detail="%d members identical" % members + result.get("note", ""))
        return result

    def run_case_parallel(case):
        out = GENERATED / case["name"]
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        cwd = case["cwd"]
        def invocation(hxb, parallel):
            par = [] if parallel else ["-D", "disable-parallelism"]
            if case.get("hxml"):
                return ["--hxb", str(hxb)] + par + ["--no-output"] + case["args"]
            return par + ["--interp", "--no-output"] + case["args"] + ["--hxb", str(hxb)]
        if case.get("lib"):
            lib_hxb = out / "lib.hxb"
            lc, _ = run([reference, "--hxb", str(lib_hxb), "-D", "disable-parallelism", "--no-output"] + case["lib"], cwd, out / "lib.log", env)
            if lc != 0:
                return dict(name=case["name"], seconds=0, status="FAIL", detail="reference cannot build the library: " + first_error(out / "lib.log"))
            case = dict(case, args=["--hxb-lib", str(lib_hxb)] + case["args"])
        ref_hxb = out / "reference.hxb"
        rc, seconds = run([reference] + invocation(ref_hxb, False), cwd, out / "reference.log", env)
        result = dict(name=case["name"])
        def finish(**kw):
            result.update(seconds=round(seconds, 1), **kw)
            return result
        if rc != 0:
            # an expected failure: every parallel run must reject it as well
            for i in range(opts.parallel):
                pc, pt = run(port_cmd + invocation(out / ("parallel-%d.hxb" % i), True), cwd, out / ("parallel-%d.log" % i), env)
                seconds += pt
                if pc == 0 or pc == "timeout" or (isinstance(pc, int) and pc < 0):
                    return finish(status="FAIL", detail="reference rejects but parallel run %d: %s" % (i, pc))
            return finish(status="EXPECTED-FAILURE", detail="all %d parallel runs reject: %s" % (opts.parallel, first_error(out / "reference.log")))
        names = [n for n in zipfile.ZipFile(ref_hxb).namelist() if n.endswith(".hxb")]
        target = ["--interp", "--no-output"] if any(n.startswith("eval/") for n in names) else ["--no-output"]
        roots = [n.split("/", 1)[1][:-4].replace("/", ".") for n in names]
        words = list(case["args"])
        for a in case["args"]:
            if a.endswith(".hxml") and (cwd / a).is_file():
                words += shlex.split((cwd / a).read_text(), comments=True)
        cps = [a for i, a in enumerate(words) if i > 0 and words[i - 1] in ("-cp", "-p", "--class-path")] or ["."]
        # one normalization per output directory: macro-context modules
        # (macro/, eval/) load with --interp, the others for the cross target
        groups = {}
        for n in names:
            groups.setdefault(n.split("/", 1)[0], []).append(n.split("/", 1)[1][:-4].replace("/", "."))
        def normalize(hxb, tag):
            # the reference reads the archive (fresh variable IDs) and writes it
            # again; modules built by macros need the macro's source: then with
            # the case's class paths too. Returns the normalized archives, or None.
            norms = []
            for prefix, group in sorted(groups.items()):
                norm = out / ("normalized-%s-%s.hxb" % (tag, prefix))
                gtarget = ["--interp", "--no-output"] if prefix in ("eval", "macro") else ["--no-output"]
                cmd = [reference, "--hxb-lib", str(hxb), "-D", "disable-parallelism"] + gtarget + group + ["--hxb", str(norm)]
                log = out / ("normalize-%s-%s.log" % (tag, prefix))
                nc, _ = run(cmd, ROOT, log, env)
                if nc != 0 and cps:
                    nc, _ = run(cmd[:1] + sum([["-cp", c] for c in cps], []) + cmd[1:], cwd, log, env)
                if nc != 0:
                    normalize.failed = log
                    return None
                norms.append(norm)
            return norms
        ref_norm = normalize(ref_hxb, "reference")
        ref_consumes = None # whether the reference loads its own archive without the case's source
        runs = [("port", port_cmd, i) for i in range(opts.parallel)]
        if opts.parallel_reference:
            runs += [("reference", [reference], i) for i in range(opts.parallel)]
        raw_same = {"port": 0, "reference": 0}
        norm_same = {"port": 0, "reference": 0}
        diffs = [] # runs that differ after normalizing (all runs go on)
        for who, cmd, i in runs:
            tag = "%s-%d" % (who, i)
            hxb = out / ("parallel-%s.hxb" % tag)
            pc, pt = run(cmd + invocation(hxb, True), cwd, out / ("parallel-%s.log" % tag), env)
            seconds += pt
            if pc != 0:
                return finish(status="FAIL", detail="parallel %s run %d failed (%s): %s" % (who, i, pc, first_error(out / ("parallel-%s.log" % tag))))
            if compare(ref_hxb, hxb) is None:
                raw_same[who] += 1
            cc, _ = run([reference, "--hxb-lib", str(hxb)] + target + roots, ROOT, out / ("consume-%s.log" % tag), env)
            if cc != 0 and ref_consumes is None:
                ref_consumes = run([reference, "--hxb-lib", str(ref_hxb)] + target + roots, ROOT, out / "consume-reference.log", env)[0] == 0
            if cc != 0 and ref_consumes:
                return finish(status="FAIL", detail="reference cannot consume parallel %s archive %d: %s" % (who, i, first_error(out / ("consume-%s.log" % tag))))
            if ref_norm is None:
                continue
            norm = normalize(hxb, tag)
            if norm is None:
                return finish(status="FAIL", detail="reference cannot normalize parallel %s archive %d: %s" % (who, i, first_error(normalize.failed)))
            diff = next((d for d in (compare(a, b) for a, b in zip(ref_norm, norm)) if d), None)
            if diff:
                diffs.append("%s run %d: %s" % (who, i, diff))
                continue
            norm_same[who] += 1
        members = len(zipfile.ZipFile(ref_hxb).namelist())
        detail = "%d members; port: %d/%d runs identical after normalizing, %d raw-identical" % (members, norm_same["port"], opts.parallel, raw_same["port"])
        if opts.parallel_reference:
            detail += "; reference: %d/%d normalized, %d raw" % (norm_same["reference"], opts.parallel, raw_same["reference"])
        if ref_norm is None:
            detail += " (no normalization: the reference cannot load its own archive without the case's source: %s)" % first_error(normalize.failed)
        if any(d.startswith("port") for d in diffs):
            return finish(status="FAIL", detail=detail + "; differs after normalizing: " + " | ".join(diffs[:3]))
        if diffs:
            detail += "; the parallel reference itself differs: " + " | ".join(diffs[:2])
        return finish(status="PASS", detail=detail)

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=opts.j) as pool:
        for r in pool.map(run_case_parallel if opts.parallel else run_case, cases):
            results.append(r)
            print("%-17s %-40s %6.1fs  %s" % (r["status"], r["name"], r["seconds"], r["detail"]), flush=True)
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    summary = ", ".join("%s %d" % kv for kv in sorted(counts.items()))
    print("Conformance: %d cases: %s" % (len(results), summary))
    (GENERATED / "summary.tsv").write_text("".join("%s\t%s\t%s\n" % (r["status"], r["name"], r["detail"]) for r in results))
    sys.exit(1 if counts.get("FAIL") else 0)


if __name__ == "__main__":
    main()
