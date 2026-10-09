# Benchmarks

Wall-clock time of the pinned reference compiler (native OCaml) vs. the
translated compiler (`haxe.Main`) built for different Haxe targets. Every run
compiles a workload to HXB with `-D disable-parallelism`. A runner's timing
only counts if its archive matches the reference: same members and
byte-identical `.hxb` payloads.

```sh
make -C haxe haxe
HAXE=haxe/haxe sh bench/build.sh js hl jvm   # needs hxnodejs, hxjava
# C++ needs hxcpp from git with bench/hxcpp-single-thread-mark.patch:
CPP_FLAGS="-D HXCPP_SINGLE_THREAD_MARK" sh bench/build.sh cpp
# HL/C needs a compiler with bench/hl2c-virtual-field-cast.patch and HashLink headers:
HAXE_HLC=/path/to/patched/haxe HL_INCLUDE=/path/to/hashlink/src sh bench/build.sh hlc
# with bench/libhl-allocator.patch applied to HashLink (built with -ftls-model=initial-exec):
HL_STATIC="libhl.a fmt.o dxt.o sha1.o" sh bench/build.sh hlc   # static link
# the HashLink JIT loads libhl.so: point it at the patched build
LD_LIBRARY_PATH=/path/to/patched/hashlink HAXE_REFERENCE=haxe/haxe python3 bench/run.py -n 7
```

## hxc OS threads: sequential cost and parallel mode (2026-10-09, late)

`self` (a snapshot of `src`), clang -O2 builds, minimum of 3 runs per
round; 4-core Xeon @ 2.10 GHz, load 1.0–1.4 (one other job). "Before" is
commit 54799e3 (green threads only), "after" 66d8f9d (1:1 OS threads,
thread-local runtime state, safepoints). Parallel mode is the compiler
without `-D disable-parallelism`; the port's pool has
`NUMBER_OF_PROCESSORS` − 1 workers besides the calling thread, the
reference uses its default domain count (4). Every archive matched the
sequential reference after normalizing variable IDs (test/TESTING.md).

| Run | wall | CPU | peak RSS |
| --- | ---: | ---: | ---: |
| before, sequential (2 rounds) | 5.21 / 5.19 s | 5.16 / 5.15 s | 454 MB |
| after, sequential (2 rounds) | 5.20 / 5.21 s | 5.16 / 5.16 s | 469 MB |
| after, parallel, 1 thread | 5.33 s | 5.27 s | 469 MB |
| after, parallel, 2 threads | 4.52 s | 5.53 s | 501 MB |
| after, parallel, 4 threads | 4.18 s | 5.91 s | 536 MB |
| reference, sequential | 6.11 s | 6.03 s | 531 MB |
| reference, parallel (4 domains) | 4.03 s | 6.72 s | 592 MB |

- No sequential regression: the thread-local variables use the local-exec
  TLS model (one `%fs`-relative access, like a global), and with one thread
  a TLAB is the whole nursery. stdlib 0.20 → 0.21 s, hello 0.12 → 0.12 s.
  (The "after" binary also links mbedtls and libuv; "before" does not.)
- Parallel mode saves 20% wall time with 4 threads (the reference: 34%):
  only the filters, analyzer, DCE marking and HXB writing are parallel,
  typing is not. The port in parallel mode is within 4% of the reference in
  parallel mode, and 32% faster than the reference sequentially.

## A real program: haxe-formatter built with hxc (2026-10-09)

[haxe-formatter](https://github.com/haxecheckstyle/haxe-formatter) (pinned in
`tools/format-src.sh`) built with the hxc haxelib package and, for comparison,
by the reference compiler for its other targets; formatting upstream's
`haxe/std` (2583 files, 14 MB) in place with `hxformat.json`, CPU time min of 3
(load 1-2):

| Build | CPU | wall | peak RSS | output |
| --- | ---: | ---: | ---: | --- |
| hxc, gcc -O2 | 3.65 s | 3.67 s | | identical |
| hxc, clang -O2 | 3.81 s | 3.85 s | 183 MB | reference for the others |
| C++ (hxcpp) | 6.34 s | 6.00 s | 212 MB | identical |
| JS (Node 22) | 9.12 s | 6.15 s | 124 MB | identical |
| hxc, tcc | 8.16 s | 8.29 s | 184 MB | identical |
| HL/C | 8.58 s | 7.04 s | | identical |
| HashLink JIT | — | — | | crashes (SIGSEGV in stock `hl`) |

hxc's optimized builds format 1.6× faster than C++ and Node and 2.3× faster
than HL/C (CPU), with byte-identical output. Building it exposed and fixed
three hxc bugs: `Exception.caught/thrown` removed by `-dce full`,
`StringTools.isEof`, and `String.split` holding the delimiter across an
allocation (a moving-GC bug).

## hxc memory: below the OCaml compiler's peak RSS (2026-10-09, night)

Peak RSS and CPU time (user + system), minimum of 3–5 interleaved runs,
`-D disable-parallelism --interp --no-output --hxb`; `self` compiles a
snapshot of `src`; every archive byte-identical to the reference. Before:
commit d2bbaad; after: 4dc6b64 (details in backend/README.md, "Memory").
The machine was slower than in the sections below (the reference took
5.7–5.9 s for `self`).

| Workload | reference | hxc-o2 before | hxc-o2 after | hxc (tcc) after |
| --- | ---: | ---: | ---: | ---: |
| hello | 0.12 s / 39 MB | 0.11 s / 51 MB | 0.10 s / 32 MB | 0.26 s / 39 MB |
| stdlib | 0.24 s / 53 MB | 0.23 s / 51 MB | 0.22 s / 42 MB | 0.55 s / 49 MB |
| self | 5.78 s / 531 MB | 5.72 s / 837 MB | 4.98 s / 467 MB | 12.4 s / 477 MB |

`RT_CENSUS=1` (heap census at exit, after a major collection) on `self`:

| | before | after |
| --- | ---: | ---: |
| live heap | 214 MB, 6.82M objects | 170 MB, 6.53M objects |
| same data in OCaml's representation (estimate) | 154 MB | 142 MB |
| enum values (2.0M) | 54 MB (a tag slot each) | 39 MB |
| `core.Pos` (753k) | 23 MB (32 B) | 17 MB (24 B, Int fields packed) |
| arrays (946k, 511k of them empty) | 29 + 22 MB data (32 B headers, slack 9 MB) | 22 + 16 MB (24 B, slack 3 MB) |
| strings | 410k, 13.6 MB (32.8k distinct) | 120k, 5.5 MB |
| remembered set (malloc) | 16 MB (128 MB with a 16 MB nursery) | 0.2 MB |

What it was, in order of effect on the peak:

- **GC memory policy** (837 → 565 MB, and −0.8 s): the from-space of the
  copying major collection stayed resident and the to-space was faulted in
  up to the from-space's size; both are now returned or faulted in on
  demand. `Array.insert` at the front of large arrays (the port's
  translation of `x :: l`) re-recorded every young element in the
  remembered set at each call (700M slot checks, 16M entries); a long
  range now remembers the object once.
- **Representation** (565 → 467 MB): no enum tag slot, no array capacity
  slot, exact array literals and growth from 2, Int/Bool fields packed two
  per slot, identifiers interned per file by the lexer.
- Not kept: a GC that deduplicates promoted strings (−3 MB more live) breaks
  HXB conformance, because string identity is observable in the port
  (`StrTools.physNeq`); a larger nursery (8 MB: −14 MB on `self`, +8 MB on
  hello and stdlib); a different old-space limit (128 MB first / 2.5× live
  instead of 256 MB / 3×: 436 MB on `self`, tuned to one workload).

With a copying old generation the peak is at least the old space at a
major collection plus what survives it. Simulated with an experimental
limit factor (old space limit = f × live after a major; not committed):

| f | majors | major time | peak RSS (copying) | old space before a major (≈ peak in place) |
| ---: | ---: | ---: | ---: | ---: |
| 3 (default) | 1 | 0.26 s | 467 MB | 415 MB (at exit) |
| 2 | 2 | 0.49 s | 562 MB | 360 MB |
| 1.5 | 3 | 0.73 s | 476 MB | 275 MB |

A mark-sweep or mark-compact old generation (planned after the OS threads
work) would bring the peak down to the last column plus the nursery and
binary (~30 MB): about 390 MB at f = 2 or 305 MB at f = 1.5, for 0.25–0.5 s
more collection time if marking costs what copying does.

## hxc: clang vs gcc (2026-10-09)

The same generated C of the port (`bin/backend/hih/prog.c`), built with
`-w -fno-strict-aliasing` and each optimizer, self-compile CPU time
(`/tmp/claude-0/cpu.py -n 5`, two alternating rounds, load 2-3):

| Build | build time | binary | self CPU (round 1 / 2) | stdlib | hello | peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gcc 13.3 -O2 | 179 s | 11.5 MB | 4.57 / 4.71 s | 0.20 s | 0.12 s | 773 MB |
| clang 18.1 -O2 | 151 s | 12.1 MB | 4.41 / 4.19 s | 0.19 s | 0.12 s | 773 MB |
| clang 18.1 -O3 | 151 s | 12.4 MB | 4.36 / 4.37 s | | | 774 MB |

clang -O2 is 4-10% faster on the large workload and builds faster; -O3 adds
nothing. The clang build passes conformance (279 + 7 expected failures, macro
cases 66/66). The haxelib package (`backend/haxelib/hxc/Build.hx`) now
prefers clang when it is installed. cosmocc is GCC-based, so the portable
builds are unaffected.

## All runners, CPU time and memory (2026-10-09, evening)

`bench/run.py` now also runs the port on the reference's Eval (`eval-source`:
`haxe -cp src --run haxe.Main …`, typed on every run; `eval-hxb`: from an Eval
HXB archive built once, `--hxb-lib … --run haxe.Main …`) and the hxc C output
compiled by Emscripten for Node (`wasm`: `sh bench/build.sh wasm`, the
playground's wasm64 build but with NODERAWFS; memory64 needs Node 24, so
`NODE_WASM=~/emsdk/node/24.19.0_64bit/bin/node`). Per run it records wall
time, CPU time (user + system of the child and its reaped children, from
`wait4`) and peak RSS; `--json FILE` merges machine-readable results into
FILE (`bench/results.json`, shown on the website's Benchmarks section).

```sh
NODE_WASM=... python3 bench/run.py -n 3 -w hello -w stdlib -w self --json bench/results.json hl hlc js jvm cpp hxc hxc-o2 hxc-cosmo wasm
python3 bench/run.py -n 3 -w hello -w stdlib --json bench/results.json eval-source eval-hxb
python3 bench/run.py -n 1 -w self --json bench/results.json eval-source eval-hxb
```

CPU time, minimum of 3 runs (1 for the Eval runners on `self`), ratio to the
reference; `-D disable-parallelism`; every archive byte-identical to the
reference. Commit 93f1df5, 4-core Xeon @ 2.10 GHz shared with other jobs
(load 5–9 during the runs, so wall times are noisier: JS, JVM and wasm also
use extra threads for JIT and GC, so their CPU time exceeds wall time).

| Runner | hello | stdlib | self | self peak RSS |
| --- | ---: | ---: | ---: | ---: |
| reference (OCaml) | 0.12 s | 0.23 s | 5.05 s | 480 MB |
| eval-source | 15.1 s (124×) | 24.5 s (106×) | 1929 s (382×) | 3506 MB |
| eval-hxb | 11.3 s (92×) | 20.6 s (89×) | 1885 s (373×) | 3329 MB |
| hl (JIT) | 0.79 s (6.5×) | 1.15 s (5.0×) | 15.3 s (3.0×) | 1351 MB |
| hlc (patched static libhl) | 0.18 s (1.5×) | 0.39 s (1.7×) | 8.15 s (1.6×) | 1657 MB |
| js (Node 22) | 2.19 s (18×) | 4.30 s (19×) | 41.8 s (8.3×) | 1717 MB |
| jvm (OpenJDK 21) | 5.90 s (48×) | 9.24 s (40×) | 64.3 s (12.7×) | 1027 MB |
| cpp (hxcpp, single-thread mark) | 0.40 s (3.3×) | 0.87 s (3.8×) | 17.9 s (3.5×) | 1266 MB |
| hxc (tcc) | 0.28 s (2.3×) | 0.58 s (2.5×) | 11.6 s (2.3×) | 805 MB |
| hxc-o2 (gcc -O2) | 0.12 s (0.98×) | 0.22 s (0.97×) | 4.42 s (0.87×) | 798 MB |
| hxc-cosmo (fat APE) | 0.10 s (0.84×) | 0.22 s (0.96×) | 5.05 s (1.00×) | 760 MB |
| wasm (hxc, Node 24) | 2.01 s (16×) | 2.61 s (11×) | 11.6 s (2.3×) | 1219 MB |

- The Eval runners need `-D eval-call-stack-depth=1000000` and an unlimited
  native stack on `self`: with 10000 frames both stopped after about 4.5 min
  with "Stack overflow". `run.py` sets both for them.
- Most of an Eval run is not typing the port: `eval-hxb` skips it and is
  only 3–4 s faster on hello and stdlib; on `self` they are within 3%.
  Building the Eval archive itself takes about 6 s of CPU.
- The hxc wasm build runs the self-compile in 11.6 s of CPU (9.0 s wall),
  against 22.7 s wall for the HL/C wasm build below.
- The C++ build first failed to compile: the JS-only `@:native("arguments_")`
  on `ServerMessage.arguments` made hxcpp emit a call to a global
  `arguments_`. The metadata is now applied on JS only.

## hxc backend: faster than the OCaml compiler (2026-10-09)

The port compiled by `backend/` (the hxc target: C, gcc -O2) now beats the
reference. CPU time (user + system), minimum of 3 runs, `-D disable-parallelism`,
outputs byte-identical:

| Workload | OCaml reference | hxc (gcc -O2) |
| --- | ---: | ---: |
| self (the port, 52k lines, runs macros) | 4.94 s | 3.89–4.08 s |
| 282 conformance cases, summed | 18.05 s | 16.79 s (faster on 220) |
| 66 macro cases, summed | 12.12 s | 10.49 s (faster on all) |
| hello / 17 std modules | 0.11 s / 0.20 s | 0.11 s / 0.18 s |

Peak RSS on `self`: 694 MB against 462 MB. What mattered, in order:
depth-first copying in the GC (the compiler is memory-latency bound: an
object's descendants now sit right after it, in the order its tree walks
visit them; −15% on `self`), pre-faulting the old space in 32 MB batches,
keeping the from-space resident, and smaller runtime costs (no data block
for empty arrays, field ids for literal Dynamic names, inline string
helpers, lazily allocated map indexes). Nursery and heap sizes stay at
generic defaults (`RT_MINOR_KB`, `RT_OLD_MB`) rather than being tuned to this
benchmark.

## Experimental HXB → native/wasm backend: go/no-go (2026-10-09)

Details, numbers and caveats are in [WASM-BACKEND.md](WASM-BACKEND.md);
the prototype is in `backend/`. One typed IR, lowered from the filtered
typed AST that HXB serializes, feeds a WasmGC emitter and a C emitter, and
every route printed identical output.

| Bench (enum trees; `-D retain`: ≈200 MB live) | Bench | retain |
| --- | ---: | ---: |
| HL/C native (patched libhl) | 0.43s | 0.61s |
| HL/C → wasm (Emscripten) | 0.59s | 0.83s |
| JS (Node 22) | 1.12s | 1.93s |
| new C (precise generational GC, shadow stack) | 0.32s | 0.54s |
| new WasmGC (Node 22) | 0.38s | 0.66s |
| new C → linear-memory wasm | 0.39s | 0.65s |
| new WasmGC via Wasmtime / WAMR AOT | 2.0s / 0.62s | 0.98s / 1.14s |

- **Go** on a typed IR plus a C backend with an OCaml-style GC (copying
  nursery; the non-moving major heap is still to be written) for the native
  binary. Translate `hxbReader.ml` for input.
- **Go** on wasm from the same runtime design in linear memory (it matched
  WasmGC here), with exceptions mapped to wasm exception handling. The
  WasmGC emitter is the optional alternative.
- **No-go** on native through wasm runtimes for WasmGC modules: wasm2c has
  no GC support, WAMR has no standard exception handling, and Wasmtime's
  default collector is 3–6× slower here. **Viable** for the linear-memory
  build: precompiled with Wasmtime (Cranelift), it runs within 7–11% of gcc
  (Bench 0.34s vs 0.32s, retain 0.60s vs 0.53s). Exceptions there cost
  the same as in V8 (14× native `setjmp`).
- **The ~20 s V8 stall is caused by `setjmp`.** Emscripten's lowering of
  `hl_trap` makes ten functions 45% of the module; V8 waits at exit for
  their optimization. For today's build, `backend/tools/wasm_hints.py`
  marks functions of 100 KB and more as Liftoff-only (run with
  `--experimental-wasm-compilation-hints --no-wasm-dynamic-tiering`). This
  brings the self-compile from 25–31 s to 17.5–18 s with identical output.
- **Alternative, measured:** generating OCaml source. ocamlopt was the
  fastest native route (Bench 0.28s, retain 0.44s, least memory), with no
  runtime of our own to write. wasm_of_ocaml is slower (0.64s / 0.99s),
  because its `int` is 31-bit and Haxe `Int` needs boxed `Int32`
  (WASM-BACKEND.md §2.8).
- **Unknown:** how the prototype's gains hold for the whole compiler. The
  benchmarks don't cover Dynamic, strings, maps or reflection.

## WebAssembly build (2026-10-09)

`bench/build-wasm.sh` compiles the HL/C output with Emscripten 6.0.12 for
Node.js: stock HashLink runtime, single-threaded, zlib built from source.
The self-compile (`-D disable-parallelism`) and `stdlib` produce archives
byte-identical to the reference.

| | size | gzip -9 |
| --- | ---: | ---: |
| `hih.wasm` | 51.5 MB | 4.27 MB |
| `hih.js` (loader) | 171 KB | 46 KB |
| native HL/C binary, for comparison | 14.3 MB | 4.49 MB |

Binaryen's `--spill-pointers`, which makes pointers held in wasm locals
visible to libhl's conservative stack scan, grows the module from 30.6 MB.

| Workload (Node 22, `--liftoff-only`) | Wasm | native HL/C | reference |
| --- | ---: | ---: | ---: |
| hello | 2.0s | 0.15s | 0.12s |
| self, `-D disable-parallelism` | 22.7s | ~6s | 4.7s |

V8's optimizing tier spends about 20 seconds compiling HL/C's very large
functions, and the program waits for it (hello takes 22s and the self-compile
26s without `--liftoff-only`), so the baseline compiler alone is faster here.
`--interp` needs `--stack-size=60000` for the typer's recursion.

**Compared with the JS target** (would a host GC, as WasmGC would give,
help?). Best of 3, `-D disable-parallelism`, all four outputs byte-identical:

| Workload | reference | HL/C | JS (Node 22) | Wasm (`--liftoff-only`) |
| --- | ---: | ---: | ---: | ---: |
| hello | 0.08 | 0.11 | 0.90 | 2.11 |
| stdlib | 0.19 | 0.27 | 1.60 | 2.63 |
| self | 4.53 | 7.67 | 23.40 | 26.95 |

V8's profiler puts 14% of the JS self-compile in V8's garbage collector
(516 scavenges, 3.0s), against about 38% in libhl allocation and marking
for the Wasm build (`gc_allocator_new_page` 15%, `hl_gc_alloc_gen` 13%).
So a host GC removes most of the allocation cost, but JS ends up about as
slow overall: its time goes to exceptions used for control flow
(`haxe_Exception`, `Grammar.fail`), closure binding (`$_`) and dynamic
access. JS is 6.1 MB (0.88 MB gzipped).

## Results — 2026-10-09 early (second performance pass)

Same container and build as below. Median of 5 runs (3 for memory); every
archive byte-identical. The machine's speed drifted by 10–15% during the
night (the reference took 3.9–4.8s for `self`), so changes were compared in
interleaved A/B runs and the ratios below come from runs taken together.

| Workload | reference | HL/C | ratio | night pass |
| --- | ---: | ---: | ---: | ---: |
| self, `-D disable-parallelism` | 4.81s / 414 MB | 6.17s / 1348 MB | 1.3× | 1.7× (1083 MB) |
| self, parallel | 3.41s / 472 MB | 4.95s / 1412 MB | 1.45× | 2.0× (1593 MB) |
| stdlib | 0.23s | 0.32s | 1.4× | |
| hello | 0.12s | 0.15s | 1.25× | |

These are the last runs of the pass, taken interleaved while the machine was
at its slowest. On a quieter stretch an earlier build of `self` ran in 5.48s
against the reference's 3.98s.

| Eval (`bench/interp.py`) | reference Eval | port Eval (HL/C) | ratio | night pass |
| --- | ---: | ---: | ---: | ---: |
| Fib | 0.29s | 0.42s | 1.4× | 1.6× |
| NBody | 0.62s | 0.90s | 1.45× | 1.6× |
| Strings | 0.31s | 0.33s | 1.1× | 1.3× |
| Objects | 1.44s | 1.92s | 1.3× | 1.5× |
| Json | 0.15s | 0.22s | 1.5× | 1.7× |

What changed, roughly by effect:

- **Free-run threshold in libhl.** After a sweep the non-moving heap is
  fragmented, and about one allocation in ten refilled its thread's slice
  from a short free run. Runs under 256 bytes now wait for the next sweep
  (8% on `self`).
- **Persistent workers (HL/C).** `parallelFor` started threads per call;
  each start registers with the GC and blocks the caller, and the analyzer's
  nested per-class loops started ~1400 of them. Workers are now kept for the
  process (parallel `self` −11%). This exposed two races in libhl's lazy type
  initialisation, which marked closure types and object runtime data ready
  before filling them in (a rare crash in a filter worker); the patch
  publishes them last. The JIT, which loads the system libhl, keeps
  call-scoped threads.
- **GC trigger on live data (HL/C).** `GcPolicy` grew its threshold with page
  memory, which fragmentation keeps well above the live data; small changes in
  allocation timing then moved `self` between ~1.4 GB and ~1.7 GB heaps and
  hid allocation savings. The patched libhl reports the bytes in use after a
  collection, and HL/C collects after 5× that (at least 64 MB).
- **Closures per call.** HashLink allocates each local function when its
  definition runs. The typer's `typeField`, `fieldAccess`, call unification,
  cast checks and pattern conversion, and several analyzer and parser
  functions, allocated a dozen or more per call. Helpers that are only called
  are now `inline`, first in the hot functions and then in every package
  (8–10% on `self` together). `Texpr` walkers that passed a typed
  function through a generic parameter got a wrapper closure per call.
- **Quadratic translations of persistent structures.** `captured_vars`
  copied its variable maps at every block (OCaml PMap snapshots are free):
  `core.ds.ScopedIntMap` undoes changes instead. The matcher hash-consed
  decision trees by linear search (upstream: a Hashtbl) and filtered the
  constructor list once per case.
- **Stack captures.** Remaining hot `throw`s of control-flow exceptions
  (`unify_min`, the matcher's extractor probe, `Invalid_expr`) use
  `FastThrow`; each native throw unwound and recorded the typer's deep stack.
- **Smaller fixes.** Unification contexts allocate their recursion stacks on
  first use. libhl allocated method-less classes (Eval's `Env`) through
  `hl_get_obj_proto` every time and gave every `[]` its own zero-length native
  array. Eval call sites cast the forced `AtomicLazy` back from `Dynamic` on
  every call.

Tried and not kept: a generational GC on this workload (live data is larger
here than on `stdlib`, but a 32–128 MB nursery still made `self` 35–60%
slower), bigger allocation slices, skipping the zeroing of pointer-free
slices, populating GC chunks at `mmap`, `-O3`, and transparent huge pages
(synchronous compaction here).

In the parallel run the typer, which upstream also runs on one thread, is
most of the remaining difference; filters, analyzer, parsing and HXB
generation are within about 10–25% of the reference or faster. One
interp-suite run in seven after the libhl fix timed out once (a 300 s hang
in a trivial case) that 900 targeted reruns did not reproduce.

## Results — 2026-10-08 night (performance pass)

Same container; HL/C linked statically against the patched libhl
(`libhl-allocator.patch`). Median of 3 runs; every archive byte-identical.

| Workload | reference | HL/C | ratio | earlier today |
| --- | ---: | ---: | ---: | ---: |
| self, `-D disable-parallelism` | 4.01s / 405 MB | 6.73s / 1083 MB | 1.7× | 8.68s / 1.80 GB (2.0×) |
| self, parallel | 2.73s / 462 MB | 5.55s / 1593 MB | 2.0× | 6.06s |

| Eval (`bench/interp.py`) | reference Eval | port Eval (HL/C) | ratio | earlier today |
| --- | ---: | ---: | ---: | ---: |
| Empty (startup) | 0.05s | 0.05s | 1.0× | 0.09s |
| Fib | 0.31s | 0.50s | 1.6× | 0.92s |
| NBody | 0.56s | 0.90s | 1.6× | 0.98s |
| Strings | 0.29s | 0.38s | 1.3× | 0.35s |
| Objects | 1.40s | 2.08s | 1.5× | 9.24s |
| Json | 0.15s | 0.26s | 1.7× | 0.63s |

What changed, roughly by effect:

- **Eval exceptions without native backtraces.** On HashLink, throwing an
  exception object captures a native backtrace unless the throw goes through
  `hl.Api.rethrow` (`core.ds.FastThrow`). Eval's `Return`/`Break`/`Continue`
  and the sort's `Bottom` were thrown directly. That was 65% of `Objects`.
- **GC during Eval.** `GcPolicy` only ticked from typed-expression
  construction, so programs run with `--interp` never collected (2 GB peak).
  Eval calls and loops tick now.
- **libhl pages.** `MADV_HUGEPAGE` made page faults compact memory
  synchronously (THP defrag is `madvise` here; now opt-in with
  `HL_HUGEPAGES=1`). Pages freed by a sweep are kept for reuse (up to 512 MB)
  instead of being unmapped. Small zeroings are inlined.
- **Fewer allocations in the compiler.** `Texpr.mapExpr` returns unchanged
  nodes as is. Recursive walkers use `mapExprWith`/`iterWith` instead of a
  closure per node. Local helper functions in hot paths are `inline`, because
  HashLink allocates every local closure at its definition. Several string
  keys are cached or verified instead of rebuilt.
- **Quadratic array use.** The typer's pass queue used `unshift`/`shift` at the
  front of arrays (cons/head upstream). Pass stacks now keep their top at the
  end of the array.
- **Eval calls.** No per-call `try` (a `setjmp` on HL/C; frames are popped
  where an exception is caught, which is the state upstream's `finally`
  leaves). Environment slots are native arrays and argument arrays are
  preallocated. `AtomicLazy` reads without a lock once set, as upstream's
  `Atomic.get`. The current Eval is a static while single-threaded.
- **Parallel DCE race.** It showed up once runs went without
  `-D disable-parallelism`. Metadata arrays are replaced, not mutated, while
  readers don't lock.

What remains is mostly the runtime itself: allocation and GC marking are over
half of the self-compilation's instructions. Live data is about 2.5× the
reference's (1.08 GB vs 405 MB), and libhl's collector is not generational.
Each phase is now 1.6–2× the reference, with no single hot spot.

## Results — 2026-10-08 (Eval vs. Eval vs. host)

`bench/interp.py` runs small programs (`bench/interp/`) with `--interp` on
the reference, on the port's HL/C and JIT builds, and natively on HashLink
(compiled by the reference, compile time excluded). Outputs are identical.
Median of 3 runs:

| workload | reference Eval | port Eval (HL/C) | port Eval (HL JIT) | native HashLink |
| --- | ---: | ---: | ---: | ---: |
| Empty (startup) | 0.05s | 0.09s | 0.49s | 0.01s |
| Fib (calls) | 0.33s | 0.92s | 3.17s | 0.02s |
| NBody (float fields) | 0.63s | 0.98s | 2.65s | 0.02s |
| Strings (Map, StringBuf) | 0.32s | 0.35s | 1.15s | 0.07s |
| Objects (sort, closures) | 1.39s | 9.24s | 13.73s | 0.60s |
| Json | 0.16s | 0.63s | 1.03s | 0.02s |

## Results — 2026-10-08 (macros, `self` workload)

The port compiling its own source (`self` in `bench/run.py`: 229 files,
~52k lines, 382 modules, std macros executed by the port's Eval). The archives
are byte-identical to the reference. 4-core container, median of 5 runs
(JIT: 3 runs).

| Runner | wall | user | sys | peak RSS | vs. reference |
| --- | ---: | ---: | ---: | ---: | ---: |
| reference (native OCaml) | 4.32s | 4.05s | 0.27s | 404 MB | 1× |
| HL/C (static patched libhl) | 8.68s | 7.64s | 2.22s | 1803 MB | 2.0× |
| HashLink JIT (stock libhl) | 13.46s | 13.13s | 1.62s | 1486 MB | 3.1× |

HL/C's first run took 14.6s (cold page cache). The gap is wider than on
`stdlib` (1.5×). From `--times` (timers add overhead and GC pauses land
anywhere, so these are rough):

| Phase | reference | HL/C | ratio |
| --- | ---: | ---: | ---: |
| DCE mark | 0.13s | ~1.5s | ~11× |
| HXB generation | 0.66s | ~2.9s | ~4× |
| analyzer | 0.95s | ~2.6s | ~2.7× |
| typing | 1.32s | ~2.5s | ~2× |
| macro | 0.05s | ~0.24s | ~4× |

DCE mark stood out. It was allocation rather than an algorithm problem.
`markT` built a new type stack array per recursion level and a closure per
call, `expr` made two closures per expression, and `Meta.has` did a checked
`Dynamic`→enum cast for every metadata entry. After removing those, DCE mark
takes 0.36s (from ~1.45s; reference 0.12s; 1.6G → 0.66G instructions).
Head to head over 8 alternating runs, end to end goes from 9.2–9.35s to 8.6s
and peak memory from 1.80 GB to 1.55 GB. Part of the time charged to DCE was
GC collections, which now run in later phases. Memory is still about 4× the
reference.

Binary sizes:

| Binary | size | stripped |
| --- | ---: | ---: |
| reference `haxe` (OCaml, every target generator) | 30.5 MB | 21.3 MB |
| `hih-hlc` (HL/C, libhl linked statically, HXB only) | 14.3 MB | 10.8 MB |
| `hih.hl` (HashLink bytecode; needs `hl` + libhl, 0.7 MB) | 2.7 MB | — |

The generated C for HL/C is 37 MB of source.

## Results — 2026-10-08 (fifth round)

4-core Linux container. Median of 7 runs, in seconds. Both HashLink runners
use the patched libhl (`libhl-allocator.patch`): HL/C links it statically,
the JIT loads it through `LD_LIBRARY_PATH`. (Earlier rounds' JIT numbers
used the stock libhl.) C++ uses hxcpp git `cd5dc3b` with
`hxcpp-single-thread-mark.patch`.

| Runner | hello | trycatch | stdlib | vs. reference (stdlib) | stdlib, fourth round |
| --- | ---: | ---: | ---: | ---: | ---: |
| reference (native OCaml) | 0.13 | 0.12 | 0.24 | 1× | 0.23 |
| HL/C (HashLink compiled to C) | 0.17 | 0.17 | 0.37 | 1.5× | 0.53 |
| C++ (hxcpp) | 0.43 | 0.43 | 0.96 | 4× | 1.02 |
| HashLink (JIT) | 0.59 | 0.66 | 1.04 | 4.3× | 1.12 |
| JS (Node 22) | 1.25 | 1.23 | 2.11 | 9× | 2.16 |
| JVM (OpenJDK 21) | 2.01 | 1.94 | 2.96 | 12× | 3.13 |

The JIT's runs vary a lot (0.85–1.35s on `stdlib`).

Instruction counts (callgrind, stdlib): the reference executes 1.10G, HL/C
2.25G (2.61G before this round; the lexer changes in item 11 came after
the table above). Of HL/C's instructions, 38% are
allocation and GC: about 9.2M allocations at roughly 30–55 instructions
each (OCaml's minor-heap allocation is an inline pointer bump), plus a
non-generational major collection. 24% are
runtime type checks, dynamic casts and closure/enum/array allocation in
libhl, 10% libc (mostly zeroing), and 25% the compiled program itself. C++
executes 5.36G: about a third of that is C++ exception unwinding in libgcc
(see the C++ note below).

Memory for speed: with the default `HAXE_IN_HAXE_GC_FACTOR=1` HL/C peaks at
141 MB on `stdlib` (the reference: 52 MB). A factor of 2 skips the one
major collection for about 10% more speed at 216 MB.

Every build above passes the full conformance suite (282 cases) through
`HAXE_IN_HAXE_PORT`.

Workloads:

- `hello`: a `trace("Hello, world!")` main (63 modules, mostly std).
- `trycatch`: `test/unit/moduleload/TryCatch.hx` (63 modules).
- `stdlib`: 32 std modules as bare roots (95 modules).

The port's own source can't be a workload yet: compiling it executes std
macros, which are outside the first milestone.

## What made it faster

In rough order of impact:

1. **Exceptions without stack traces.** The port follows upstream in using
   exceptions for control flow (about 119k throws for `stdlib`: parser
   backtracking, `Not_found`, `Exit`). OCaml exceptions are nearly free;
   Haxe targets capture a stack trace for each one.
   - `Not_found`, `Exit`, `Stream.Failure` and `MetaNotFound` are thrown as
     shared instances (`throw NotFound.raise()`).
   - Like OCaml, stack traces are only recorded with `OCAMLRUNPARAM=b`: JS
     sets `Error.stackTraceLimit = 0`, and `runtime/hl/haxe/Exception.hx`
     skips capture in the constructor.
   - On HashLink, `raise()` and `haxe.Exception.thrown` throw through
     `hl.Api.rethrow`, which skips libhl's native stack capture. That capture
     was 80% of the HL/C run.
2. **HashLink GC trigger.** libhl starts a full, non-generational mark after
   every 20% of heap growth, so a heap full of typed modules is marked over
   and over. `core.ds.GcPolicy` disables that and collects once allocation
   since the last major exceeds half the heap size
   (`HAXE_IN_HAXE_GC_FACTOR`, default 0.5). This took HL from 2.0s to 1.4s on
   `stdlib`, with peak memory going from 86 MB to 130 MB.
3. **Algorithms.** `Hashtbl` was a list scanned with reflective structural
   comparison; it's now indexed by a canonical key string.
   `PersistentMap` uses binary search. The lexer no longer allocates a
   substring for each operator candidate on every token.
4. **Static types.** `TExpr`, `Pos`, `Expr`, `TVar`, `TClassField` and
   `TMono` are `@:structInit` classes instead of anonymous structures. The
   typer's `com` field and the `scom` and `ctx` parameters are typed instead
   of `Dynamic`. This helps HL a little and the JVM a lot. It also cut the
   pinned compiler's JVM generation from about 8 minutes to 90 seconds.
5. **Counters.** `allocVar` and `allocMid` use `haxe.atomic.AtomicInt`
   (upstream's `Atomic.fetch_and_add`) instead of a mutex.
6. **libhl allocator** (`libhl-allocator.patch`, second round). Fixed-size
   classes go up to 128 bytes instead of 40, so typical compiler objects use
   the thread-local slice fast path instead of the locked free-list
   allocator. The fast path is a small separate function. Slices are zeroed
   once when created rather than per allocation. Sweeping skips whole bitmap
   bytes. Built with `-ftls-model=initial-exec` and linked statically, it
   cuts HL/C from 0.86s to about 0.6s on `stdlib`.
7. **Fewer allocations and conversions** (second round). More records became
   classes (`GlobalTypePath`, `UnificationContext`, `LexedToken`,
   `MetadataEntry`, `PlacedName`, `PlacedAccess`, `TypeHint`, map entries).
   `RecStack` is the array itself. `Record.copy` resolves `clone()` at
   compile time. The lexer's operator table is typed and its line table
   avoids O(n) prepends and per-character strings. `Stream.peek` no longer
   copies. Some hot local helpers became static functions. The default GC
   factor is 1.0 (peak memory on `stdlib` about 140 MB, against the
   reference's 53 MB).
8. **Records as classes everywhere** (third round). The AST, typed AST,
   typer contexts and the analyzer, matcher, coroutine and filter records
   are all `@:structInit` classes. `CommonContext` stays a structure because
   its 62-argument constructor exceeds the HashLink JIT's argument limit.
   `Record.copyDynamic` clones any record class reflectively. Also made
   the JVM build (genjvm) take seconds instead of minutes.

9. **Allocator, fifth round** (`libhl-allocator.patch`). New pages come
   zeroed from `mmap`, so neither the page nor slices carved from untouched
   blocks are cleared again (a per-page `zero_from` mark tracks this).
   Slices are 8 KB instead of 2 KB. Pages are carved from 2 MB-aligned
   32 MB chunks marked `MADV_HUGEPAGE`, which cuts page faults on `hello`
   from 21k to 1.3k. The global GC lock skips its `setjmp` context save when
   the lock is uncontended (the collecting thread saves its own context in
   `gc_stop_world`). The lazy sweep scans the mark bitmap 64 bits at a time.
   `hl_alloc_obj` bumps the thread's slice directly. Together: `stdlib`
   0.53s → 0.37s on HL/C.
10. **Fewer dynamic checks** (fifth round). On HashLink `Std.isOfType` casts
   its class argument from `Dynamic` before checking, about 200
   instructions per call; `haxe.Exception.caught`/`thrown`, `Key` and
   `Meta` use `Std.downcast` instead, a direct type check.
   `newRecStack` is inline, so each unification context no longer converts
   five arrays from `Array<Dynamic>`. `TUnification.updated` (a copy plus
   reflective field sets) became `Record.withFields`, which sets the
   fields statically.

11. **Lexer** (fifth round). A token only tries the operators starting with
   its first character instead of all of them; comments are found with
   `indexOf` and copied at once instead of a one-character string per
   character; `skipWhitespace` compares code units. `ZipOutput` computes
   the CRC-32 with a table instead of `haxe.crypto.Crc32`'s bitwise loop.
   `Lexer.token` went from 80M to 18M instructions on `stdlib`.

12. **Inline allocation** (sixth round). `libhl-allocator.patch` adds an
   allocation fast path to `hlc.h`: generated code allocates objects, enums,
   closures, small arrays, virtuals and bytes by bumping the thread's slice
   directly instead of calling into libhl (about 70 instructions per
   allocation before). After a collection free runs are short, so a slice
   refill now takes several runs under one lock and queues them. HL/C
   `stdlib`: 2.25G → 1.90G instructions, 0.38s (reference 0.24s); with
   collection disabled it is about 1.25× the reference in CPU time. What
   remains is mostly memory management: the non-generational major
   collections, zeroing reused memory, and first writes to fresh memory,
   which OCaml's cache-resident minor heap avoids.

13. **Dynamic typing and boxing** (seventh round). HashLink compiles an
   `Array<T>` of a type parameter to `ArrayDyn` and a structure to a virtual,
   so generic helpers boxed every array argument (an allocation and a dynamic
   call per element access) and generic structures went through
   `hl_to_virtual` on every use. `Stream` is now `@:generic`; the generic
   `List`/`Texpr`/HXB-writer list helpers and the parser combinators
   (`tryHead`, `plist`, `psep*`) are inline; two hot private structures
   became classes. `tryHead` tests the shared `Stream.Failure` by identity
   instead of a typed catch, and string tests use the type pointer instead
   of `Std.downcast`. Runtime side: `runtime/hl` overrides `StringBuf.add`
   (the same string test) and `ArrayObj.__expand` (grow from 4 and double
   while small, instead of reallocating at 1, 2, 3, 4, 6, 9, 13…), and
   `hlc.h` gains an inline `hl_dyn_castp` fast path for exact-type casts.
   HL/C `stdlib`: 1.81G → 1.57G instructions (reference 1.10G). Minimum CPU
   time over 21 runs: 0.37s (reference 0.24s); with collection disabled
   (`HAXE_IN_HAXE_GC_FACTOR=1e9`) its user time is 0.22s against the
   reference's 0.20s. What is left is memory management: the major
   collections, and zeroing recycled memory when slices are refilled
   (about 80M instructions of `memset`).

14. **Generational GC: tried, not adopted** (2026-10-08). A sticky-mark-bit
   generational mode with an hl2c write barrier works (all 282 conformance
   cases pass even with a 1 MB nursery) but is slower: 0.42s or more of user
   time on `stdlib`, against 0.32s. The barrier costs about 0.03s, and the
   live set is so small (6–12 MB for 260 MB allocated) that the current rare
   majors already mark little. Details, data and patches:
   [experiments/generational-gc](experiments/generational-gc/README.md).

Where the time went after the first round (HL/C, callgrind): libhl allocation and GC were about
45% of the run. libhl takes a global lock and a TLS lookup on every
allocation, which is far more expensive than OCaml's pointer bump. The rest is
spread over the typer, filters and analyzer with no dominant hotspot. The
next steps would be allocating less in the filter/analyzer passes (52% of
all allocation) or a cheaper allocator.

## Notes

- **Go** (hx2go). The pinned compiler has no Go target; the
  [hx2go](https://github.com/go2hx/hx2go) custom target (git `2739b6c`)
  generates Go that only builds and runs after patching:
  `HAXE=haxe/haxe sh bench/hx2go/build.sh` produces `bin/bench/hih-go`. With
  those patches it passes the full conformance suite (282 cases) and runs
  every workload, but it's the slowest build: `stdlib` 5.10s (20× the
  reference; HL/C 0.48s, JS 2.21s, JVM 3.09s in the same run), `hello`
  2.34s. About a third of its time is Go panic/recover unwinding for the
  port's exception-based control flow, and a quarter is GC; much of the rest
  goes through reflection-based dynamic calls.
  The fixes, all specific to hx2go 2739b6c:
  - Source (`bench/hx2go/source.patch`, applied to a copy of `src`): rename
    two exception fields called `error` (hx2go's `haxe.Exception` defines
    `error()`); explicit null checks for the two enum-valued default
    arguments (hx2go drops callee-side defaults); `catch (e:NotFound)`
    instead of `catch (e:Dynamic)` plus `Std.isOfType` (a caught subclass
    arrives as its base `haxe.Exception`); `exists` before calling a
    function read from a map (hx2go's adapter makes it non-null).
  - Generated Go: `trybreak.py` (a `break` out of a loop inside a `try` body
    left the whole `try` body, skipping e.g. class field initialization),
    `tryreturn.py` (`return f()` inside `try` marked the function as returned
    before evaluating `f()`, so a caught exception made it return nil),
    `staticorder.py` (static initializers ran before the statics they read),
    `autofix.py` (generic array variance, dead `break`/`continue`, missing
    returns, `any` assertions), and `manual.py`: a name clash between
    `core.Texpr` and `core.TExpr`, `super` inside closures, typed `catch` on
    a typedef alias, `Map` values stored as concrete maps, a recursion limit
    for `Std.string` (types are cyclic), void functions behind dynamic
    closure adapters, and the string runtime. hx2go's `charCodeAt` counted
    runes from the start of the string on every call (quadratic lexing) and
    `indexOf` returned byte offsets while `substr` used code points; the
    patched runtime has O(1) paths for ASCII strings and code-point-correct
    `indexOf`. Mutex ownership formatted a stack trace (`runtime.Stack`) per
    acquire to get the goroutine id; with a single goroutine it's now constant.
  - Debugging aids in the patched runtime: `HXGO_TRACE=1` prints the Go
    stack of every thrown Haxe value (except the control-flow singletons) and
    runtime error; `HXGO_CPUPROFILE=file` writes a pprof CPU profile.
- **HL/C.** The pinned compiler's `hl2c` dies (`Globals.die` in `rassign`)
  when a `Dynamic` field of a structural type is read into a typed register.
  `hl2c-virtual-field-cast.patch` converts through `hl_dyn_cast` there, like
  `OSafeCast`. HL/C is the fastest build, but only once throws skip the stack
  capture: before that it was slower than the JIT (4.75s), because the C
  build captures stacks through libgcc unwinding. Static linking of libhl and
  `-O3 -march=native` made no measurable difference.
- **C++.** Needs hxcpp from git: the 4.3.2 haxelib release (and 4.3.99)
  don't support the pinned std's zip API.
  - **Crash.** Release builds crashed or hung on random runs: segfaults in
    random places (hxcpp's string hash, the GC, field reads from objects that
    had been collected) and deadlocks. The cause is hxcpp's multi-threaded GC
    marking. With a single marker thread every run passes; disabling only
    the hand-off of large arrays to other marker threads doesn't help.
    `hxcpp-single-thread-mark.patch` adds `HXCPP_SINGLE_THREAD_MARK`,
    which turns parallel marking off, the same as `HXCPP_GC_VERIFY` does
    without that define's verification work. Debug builds also mark on one
    thread, which is why they never crashed.
  - **Port fixes.** `switch` directly on a call through a function-typed
    field with an enum result generated invalid C++ (`.StaticCast` on the
    callable), so `InstanceBuilder` stores the result in a local first. On
    hxcpp `StringTools.fastCodeAt` on a structure field calls `cca`
    dynamically and failed at startup, so the lexer's first-character table
    is built from its typed operator texts. Also fixed earlier: a C++
    trigraph (`"??="`) in the lexer.
  - **Speed.** `StringTools.lpad` reads `StringBuf.length`, which is O(n)
    on hxcpp, so `ParserEntry.parseExprString` padding a string by `pmin`
    spaces was quadratic: half of all instructions for `hello`. It now
    builds the spaces directly (upstream's `String.make`). What remains is
    mostly exceptions: parser backtracking throws (about 119k throws for
    `stdlib`) unwind through libgcc's table-driven unwinder, which costs
    about 19k instructions per throw on the deep recursive-descent stacks.
    `HXCPP_SINGLE_THREADED_APP` (no TLS lookup per allocation) saves about 8%
    more, but it's unsafe once the compiler runs parallel filters.
- **JVM.** `genjvm` emits a method (`typing.Typer.typeExpr`) that the
  bytecode verifier rejects. The jar runs correctly with verification off
  (`-XX:-BytecodeVerificationLocal`), which `run.py` passes. The JVM
  initializes classes lazily, so `haxe.Main.initHooks` installs every forward
  reference explicitly. Java can't change the working directory, so
  `core.Path.restoreCwd` skips `Sys.setCwd` when the directory didn't change.
- **JS.** Needs hxnodejs for `sys`. `bench/js-shims` holds single-threaded
  `sys.thread` stand-ins; the compiler only spawns workers when parallelism is
  enabled. Building with `-D analyzer-optimize` currently produces different
  (non-conforming) output on JS, so all targets are built without it. Larger
  V8 semi-spaces and `-D js-enums-as-arrays` made no difference. When stdout
  is a pipe or `/dev/null`, hxnodejs's `Sys.stdout().flush()` fails
  (`fsync` EINVAL).
- **Conformance on other targets.** For example,
  `HAXE_IN_HAXE_PORT="node --stack-size=65500 bin/bench/hih.js" python3 test/conformance.py`
  runs the whole conformance suite on a prebuilt port.
