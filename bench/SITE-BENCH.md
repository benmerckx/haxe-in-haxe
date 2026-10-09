# Local fast-target benchmarks

These results run the workloads from [benchs.haxe.org](https://benchs.haxe.org/)
locally, using HaxeBenchmarks/benchmark-runner sources. The separate branch is
`bench/hxc-fast-targets`; no workflow or remote runner executes the benchmarks.

## Method

Machine: Linux container on AMD EPYC 9V74, 9 visible CPUs with an 8-core CPU
quota, 8 GiB memory limit. GCC 13.3.0, Node 24.19.0, OpenJDK 21.0.12.
This is a shared execution environment, not an isolated benchmarking host.

The port/backend source is commit `54799e3b6e1a989925f48da548514bba7a3ca989`.
Reference Haxe is the exact pinned submodule commit, built by upstream CI:
`5.0.0-preview.1+b10fa6e`. Dependency and dataset revisions, plus compiler
artifact/archive checksums, are recorded in `site-bench-lock.json`.

Targets: hxc, C++ default GC, C++ generational GC, HashLink JIT, HashLink C,
JVM, Node JS, Node ES6. PHP, Lua, Python, Neko, Eval, and Cppia are excluded.
hxc uses GCC `-O2 -fno-strict-aliasing`, with SSL/libuv disabled, as in the
backend build script. HashLink C uses GCC `-O3`; hxcpp uses its release build
defaults. These compare deployed target configurations, not identical C
optimization flags.

For each case all targets build before timing. Each executable gets one
untimed warm-up process and three measured fresh processes, with shuffled,
interleaved order, one executable running at a time. Reported times are median
wall seconds, including startup, JIT and GC; they are not steady-state loop
measurements. Raw samples, CPU time, peak RSS, commands, and build outcomes
are in `site-bench-results.json`. Tiny results near 20 ms are sensitive to the
5 ms observation interval and process startup.

Workload code and iteration counts are unchanged. JSON uses the formatter
schema; Formatter NoIO uses formatter source; Dox uses Haxe 4.1.0 API XML;
Formatter uses pinned Haxe std/OpenFL/Lime source trees, reset before each run.
These inputs are reproducible snapshots, not a claim to match the website's
historical datasets or hardware. Compare targets within these local runs,
not local seconds against the website's seconds.

Most upstream workloads do not emit checksums. Success means a successful
exit, not proof of equivalent computed results. Failures and timeouts receive
no timing aggregate. In particular the formatter workloads can reject source
syntax from newer dataset snapshots; their diagnostics must remain visible.
No compiler or runtime source was modified to obtain these results.

## Reproduce

System packages: GCC/G++, make, Git, Python 3, Node, Java, Neko, libpng,
libturbojpeg, libvorbis, and zlib development packages. Initialize `haxe/` at
its pinned commit. Install/build that compiler as `haxe/haxe` and put its
matching `haxe` and `haxelib` binaries first on PATH. The locked CI artifact is
one way to obtain it; GitHub artifacts may expire, so building the pinned
source is also valid.

From the repository root, choose an external dependency directory:

```sh
python3 bench/site-bench-setup.py /tmp/haxe-site-bench
export HAXE_STD_PATH="$PWD/haxe/std"
mkdir -p bin/backend
haxe/haxe -cp src -cp backend/src -main backend.Main -lib hxnodejs \
  -cp bench/js-shims --js bin/backend/wbk.js -w -WDeprecated
python3 backend/tools/mkstd.py
python3 bench/site-bench.py --sources /tmp/haxe-site-bench/benchmark-runner \
  --hashlink /tmp/haxe-site-bench/hashlink --dox /tmp/haxe-site-bench/dox -n 3
```

The setup registers local haxelib dev paths. The JS-hosted hxc compiler cannot
spawn haxelib, so the harness resolves those library classpaths/defines with
the reference haxelib before invoking it. Generated artifacts remain in
ignored `bin/site-bench/`. `--cases`, `--targets`, and `--reuse` allow focused
runs; reuse requires the original generated binaries to still exist.

Harness validation: Python syntax compilation and process accounting checks
for success, nonzero exit, and forced timeout. Dependency setup was performed
locally; the convenience setup script was reviewed and syntax checked, not
rerun from an empty directory.

## Results

Median wall seconds; **B** = build failed, **R** = runtime failed. No failed target receives an aggregate.


| Case | hxc | C++ | C++ gen GC | HL JIT | HL C | JVM | Node | Node ES6 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| binarytrees | 0.745 | 0.653 | 0.911 | 3.696 | 3.410 | 0.439 | 1.050 | 1.103 |
| nbody | 0.974 | 0.759 | 0.775 | 1.139 | 1.376 | 0.816 | 0.975 | 0.923 |
| sha256 | 0.214 | 0.210 | 0.205 | 0.507 | 0.326 | 0.163 | 0.281 | 0.270 |
| sha512 | 0.195 | 0.026 | 0.023 | 0.082 | 0.046 | 0.124 | 0.276 | 0.286 |
| bcrypt | 2.413 | 1.977 | 2.007 | 4.584 | 2.403 | 2.217 | 2.426 | 2.443 |
| json | R | 0.506 | 0.531 | 1.066 | 1.106 | 0.469 | 0.256 | 0.273 |
| alloc | 0.678 | 1.280 | 1.251 | 1.746 | 1.720 | 1.470 | 9.728 | 9.516 |
| mandelbrot | 0.990 | 1.418 | 1.148 | 19.246 | 19.214 | 0.753 | 0.815 | 0.864 |
| mandelbrot_anon_objects | 2.454 | 6.099 | 5.732 | 26.538 | 25.130 | 0.802 | 0.772 | 0.755 |
| formatter_noio | 5.512 | R | R | 14.417 | 13.370 | 4.545 | 13.736 | 13.848 |
| formatter | R | R | R | R | R | R | R | R |
| dox | B | R | R | 22.006 | B | 5.923 | 6.087 | 5.831 |

Allocation is hxc's strongest result: 0.678 s versus the fastest baseline,
C++ generational GC at 1.251 s (1.85x faster). Peak measured RSS is 688 MiB
for hxc, 1,132 MiB for either C++ mode, 769 MiB for HL, and 1,660 MiB for JVM.
SHA256 is close to C++; SHA512 is substantially slower than native baselines.
Fresh-process timings include startup, particularly significant for SHA512.

### Correctness and failures

- JSON: hxc rejects even ASCII `{}` with `Invalid char 0 at position 2`.
  The untimed audit reports `eof=0 isEof=false`. Reference `StringTools.isEof`
  lacks an hxc branch and returns false; the JSON parser never recognizes EOF.
  The schema error at position 36,956 is its character length, not evidence
  of faulty UTF-8 decoding. Latest main already adds the missing hxc EOF case;
  that fix is outside this original baseline revision.
- Formatter NoIO: output audit checks both configurations across all 36 input
  files. Both hxc and Node ES6 return 72 successes, zero failures/disabled,
  with identical checksum
  `525ae7321f430d9006b31873019bb998826e510f1b53ec5271f1e2200779ca1a`.
  The one-pass audit verifies formatted output, not all thirty timed repetitions.
- Formatter with I/O: all targets fail on the newer pinned source dataset.
  Formatter 1.9.1 rejects syntax in Haxe std, including `jvm/StringExt.hx`.
  This is not a useful performance comparison on these inputs.
- Dox: hxc cannot compile because its StringBuf override lacks `clear`, called
  by `haxe.Serializer`. Reference HL C has an internal compiler failure in
  `src/generators/hl2c.ml` at line 591. Both C++ modes also crash with SIGSEGV
  in measured runs; default C++ had two successful samples before crashing.
- Formatter NoIO: both C++ modes crash with SIGSEGV during warm-up.

Failed exits and diagnostic excerpts remain in the raw results. Successful
numerical workload exits still lack independent result checksums.

Run the untimed audits after timing finishes:

```sh
python3 bench/site-bench-audit.py --sources /tmp/haxe-site-bench/benchmark-runner \
  --hashlink /tmp/haxe-site-bench/hashlink
```

The next phase syncs main, fixes correctness first, and then measures targeted
performance improvements. This baseline remains tied to the original source
commit; subsequent results will be recorded separately.
