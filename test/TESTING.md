# Testing status

Earlier checkpoints are in the Git history of this file.

## Eval lock: OCaml's runtime lock for Eval threads — 2026-10-09

Upstream's Eval threads are OCaml threads sharing one runtime lock; the port
ran them truly in parallel on host threads, so the interpreter's shared state
raced (hxcoro crashed with SIGSEGV at `EvalAtomic` `AtomicInt.load` or hung in
`issues.hf.Issue37` in about 1 of 4 runs). `src/macros/eval/EvalLock.hx` (a
documented deviation, no upstream module) reproduces the runtime lock:

- Inactive until an Eval native starts a second host thread running Eval code
  (`EvalThread.spawn`, eval.luv `Thread.create`, the eval.luv thread pool);
  until then `tick` reads one static and `blocking` calls straight through.
- Once active, every thread running Eval code holds it (the compiler thread
  from activation on). Natives release it around host calls that block:
  sys.thread Mutex/Lock/Semaphore/Condition/Deque waits, thread messages,
  joins, sleeps, `Thread.yield` (FIFO hand-off), socket/process/file input,
  `Sys.getChar`, the eval.luv primitives and joins, uv_run (callbacks take it
  again), and the compilation server's idle wait.
- Fairness: a waiter that waited 2 ms sets `yieldRequested`; the holder gives
  way at its next function entry or loop iteration (`EvalLock.tick`), handing
  the lock over in FIFO order.
- Lock order: never block on a host primitive while holding the Eval lock;
  the lock's guard mutex is held only for list updates (nothing allocated).

| Check (HashLink build unless noted) | Result |
| --- | --- |
| `upstream.py party-hxcoro` (3 steps), 20 runs in a row | 20/20 (60/60 steps) |
| party-tink_core | pass |
| threads | 141/142 (unchanged: `testNative` needs libuv) |
| threads, connect-stdin, party (hxc build, tcc, libuv + mbedtls) | 144/144, pass, pass |
| full `upstream.py` | as before (unit-macro 11367/11371 with the 4 `Gc.finalise` errors, threads 141/142, the rest pass) |
| conformance / `--cases` macro / upstream `--hxb-lib` / party | 279 + 7, 66/66, 135 + 60, 2/2 |
| `server.py` (both cache modes; macro cases) | 595/595, 595/595; 132/132 |
| `bench/interp.py -n 5`, HL JIT, two alternating rounds before/after | Empty 0.78/0.76 → 0.73/0.72 s, Fib 1.97/2.01 → 1.97/1.88, NBody 2.97/2.79 → 2.83/2.85, Strings 1.44/1.35 → 1.34/1.34, Objects 5.65/5.68 → 5.59/5.62, Json 1.20/1.29 → 1.30/1.24 (noise) |
| macro cases summed time (`-j 1`, two rounds) | 91.4/90.5 s before, 89.7/91.1 s after |

HL/C was not benchmarked (no patched hl2c or HashLink headers in this
environment); `bench/interp.py` now reports a port build that is missing as
"not built" instead of failing.

## Wider upstream coverage: third-party projects and more suites — 2026-10-09

### Third-party projects (Macro.hx `party`)

`python3 test/upstream.py [--reference] party` runs upstream CI's tink_core and
hxcoro steps (clones pinned in `PARTY`: tink_core `b6745a8`, hxcoro `4b1a4d4`,
the master branches when added; utest `a055e05`, haxeserver `fad3af2`).
GitHub clones work through the proxy. lib.haxe.org metadata works, but
haxelib's own download fails: the 302 to haxelib-files.haxe.org yields an empty
download. curl follows it, so tink_core's test dependencies (the latest
releases of tink_unittest, deep_equal and their dependencies, pinned in
`TINK_CORE_LIBS`) are fetched with curl and installed with `haxelib install
<zip>`.

| Step | Reference | Port (HashLink build) |
| --- | --- | --- |
| party-tink_core (`--interp`) | 257/257 assertions | 257/257, identical output |
| party-hxcoro (from source) | 321 tests, 1256 assertions | same |
| party-hxcoro-hxb (`--hxb bin/test.hxb`) | same | same |
| party-hxcoro-hxblib (`--hxb-lib bin/test.hxb`) | same | same |

`test/conformance-party-cases.txt` compares the two projects' HXB output:
tink_core 327 members, hxcoro 369 members, identical.

Root causes of the port failures:

- tink_core: "You cannot use @:build inside a macro". `Common.clone` shared the
  global metadata array with the macro context; upstream's `global_metadata`
  is an immutable list, so the macro context keeps a snapshot. tink_syntaxhub
  adds a global `@:build` after the macro context exists.
- hxcoro HXB (135/369 payloads): coroutine hoisted fields were listed in
  insertion order instead of OCaml `Hashtbl.to_seq_values` order
  (`CoroToTexpr.handleLocals`, now an `OcamlHashtbl`), and `map_suspension`
  remapped block elements head first. OCaml's `remap hd :: remap_block tl`
  remaps the tail first, and the deferred expressions allocate variables
  (`CoroFromTexpr`).

### More upstream suites as HXB conformance cases

`test/conformance-upstream-cases.txt` (new, 195 cases; needs the utest and
haxeserver repository of `test/upstream.py`, found through `HAXELIB_PATH`):
the unit suite (`compile-macro.hxml`, also with `-dce no`), nullsafety,
threads, the four parts of the sys suite, the eval resolution projects typed
for Eval, the Eval parts of `tests/optimization/run.hxml`, the benchmarks, the
display and sourcemaps test runners, and every server test template module
(167). `test/display-snippet-cases.py` writes
`test/generated/display-snippets/cases.txt`: the 406 display test snippets
compiled normally. `conformance-cases.txt` gains the parts of two multi-part
misc/eval configurations (Issue11354 ×3, sys-exit). Exclusions are listed in
`upstream-hxb-exclusions.md` ("Upstream suites").

`conformance.py` changes: hxml cases take arguments after the hxml (or
arguments only); `volatile <case> <member>` names a member whose payload embeds
the compilation time (the unit suite's `TestMainNow`, `Date.now()` in a macro),
which must exist in both archives but is not compared.

| Case list (`conformance.py --hxb-lib`) | Result |
| --- | --- |
| `conformance-upstream-cases.txt` (195) | 135 PASS (115 identical `--hxb-lib` round trips, the rest rejected by both), 60 expected failures (59 server templates, `benchs-Coro`) |
| display snippets (406) | 117 PASS (115 identical round trips), 289 expected failures (incomplete snippets) |
| `conformance-party-cases.txt` (2) | 2 PASS |
| `conformance-cases.txt` (286) | 279 PASS, 7 expected failures |
| `conformance-macro-cases.txt` / `conformance-hxblib-cases.txt` | 66/66, 7/7 |

The unit suite case has 1827 members (the whole suite, std included); the
nullsafety, threads, sys, resolution and display runner cases 150 to 480 each.
The bootstrap build passes.

`python3 test/upstream.py` with the port: the existing steps are unchanged
(misc 684 tests, 0 failures; unit-macro and unit-macro-hxblib 11367/11371 with
the 4 `Gc.finalise` errors; threads 138/139 with `TestEval.testNative`;
nullsafety, misc-resolution, sys-hxb, sys-run, compiler-loops, connect-stdin
pass), and the party steps pass, except for an intermittent crash:

- hxcoro's tests sometimes die with SIGSEGV in a spawned Eval thread (always
  at `EvalAtomic` `AtomicInt.load`, in thread-pool tests such as
  `issues.hf.Issue32`/`Issue64` or `testReleaseAcquireConcurrency`) or hang
  (`issues.hf.Issue37.testNotCancelling`). 2 of 8 runs of the source build
  crashed, and 3 of 8 with the port as it was before this work, so these
  changes did not cause it; the reference passed 4/4. The port runs Eval
  threads truly in parallel on HashLink threads; a stand-alone HashLink test
  of the same locked `{v:Int}` cell pattern does not crash. Fixed by the Eval
  lock (see "Eval lock" above).

Root causes of the port failures:

- Lexer positions: sedlex counts code points, the port counted UTF-16 units,
  so positions after an emoji were off by one (unit TestJson, TestUnicode,
  TestUtf8 and 10 more modules).
- `FormatString`: OCaml's `format_string` counts UTF-8 bytes for offsets and
  positions; the port counted characters (sys TestUnicode).
- Folded float constants used `Std.string` instead of `Numeric.float_repres`
  (`%.12g`): `1455555555 * 1000.` is `1.455555555e+12` (unit TestDate). Also
  negated float constants and the Macro API's float encoding.

## Upstream test suite — 2026-10-09

`python3 test/upstream.py [--reference] [step ...]` runs upstream CI's
target-independent job (`haxe/tests/runci/targets/Macro.hx`) with the port as
`haxe` on PATH (see the script header).

### misc (`haxe/tests/misc`, 686 projects)

The reference passes all 686 projects. Second half of the 64 port failures
(Issue8019 through process-nonexistent, 32 projects): all pass now, none
excluded. Root causes:

- Abort after typing when errors were reported (the non-display branch of
  `DisplayProcessing.handle_display_after_typing`, previously missing): -main
  checks no longer add "Module X does not define type X" / "Invalid -main"
  after the real errors, and filters no longer add errors after them
  (Issue8258, Issue8277 ×2, Issue8517, Issue8697, Issue8787 ×2,
  Issue9010/NativeMeta, Issue9017, default_type_params ×3, extern-overloads
  ×3, issue5002/compile2, local-static Break/Continue).
- Coroutines: type paths and metadata arguments passed as `Dynamic` were
  anonymous objects on HashLink, failing the cast to `GlobalTypePath`/`Expr`
  (coro ×7; these projects use `-js`, but the errors are typing errors raised
  before generation).
- Plain arguments are classified with `Path.parse_path` (`Main.hx` is class
  `Main`, not `--include` of a package) (Issue8534).
- `#if` comparison errors print floats with OCaml `string_of_float`
  (`0.`) (Issue8677).
- The lexer records the lines before a lexer error (escape errors were
  reported on the previous line) (Issue8119 ×2).
- Type-path hash keys kept `[]` and `[""]` apart (a macro-defined type in
  package `""` was a "redefinition") (Issue8019 ×2).
- Eval's `sys.io.Process` follows `libs/extc/process.ml`: a command that
  cannot be spawned gives EOF stdout, the error on stderr and exit code 127
  (the command is looked up in PATH like `posix_spawnp`, since host
  processes fork first and exit 1 on HashLink) (process-nonexistent). This
  also removes the `process-nonexistent` difference of `test/interp.py`.

First half (HxbWildcardExclude through Issue7997, 32 projects): 30 pass,
2 excluded. Most were the abort after typing above; the others:

- `TUnification.close`: the "Recursive type" message prints the field type
  before the mono, as OCaml evaluates `sprintf` arguments right to left (the
  first printing of a constrained mono shows its constraint) (Issue11881,
  Issue7997).
- HashLink 2.0 JIT: every `endtrap` of an early `return`/`break` restores
  the innermost trap, so leaving two nested `try` blocks at once left the
  outer handler installed after its frame was gone, and the next uncaught
  exception jumped into a dead frame (Issue1138/compile3-fail segfaulted).
  The five such exits in the port (CallUnification, ImportHandling,
  InheritDoc, Dce, FixOverrides; found by scanning `-D dump`'s
  `dump/hlcode.txt` for consecutive `endtrap false`) now return after the
  inner `try`. Re-run that scan after adding `return` inside nested `try`.
- Coroutine module paths typed as `GlobalTypePath` (Issue12483 ×2).

Excluded in `test/upstream.py` (`MISC_EXCLUDED`, passed to the runner as a
negative `MISC_TEST_FILTER`): HxbWildcardExclude/compile (its first step
compiles with `-js` next to `--hxb`) and Issue4660/compile (runs `haxe -js`
and checks the JavaScript).

The full misc step now passes: 684/684 with 2 excluded. Conformance stays at
275 PASS + 7 EXPECTED-FAILURE (also `--hxb-lib`), and the bootstrap build
passes. (`python3 test/upstream.py misc` also runs `misc-resolution`; see
below.)

### The other steps

| Step | Reference | Port (HashLink build) |
| --- | --- | --- |
| unit-macro | 11372/11372 assertions | 11367/11371, 4 errors (Gc.finalise) |
| unit-macro-hxblib | 11372/11372 | 11367/11371, 4 errors (Gc.finalise) |
| nullsafety | 232 expected errors, pass | 232 expected errors, pass |
| misc-resolution | 7/7 (3 excluded) | 7/7 (3 excluded) |
| sys-hxb | pass | pass |
| sys-run | 31 + 31 + 1103 assertions, all pass | same |
| compiler-loops | 19/19 | 19/19 |
| connect-stdin | 10/10 | 10/10 |
| threads | 144/144 assertions | 141/142, 1 error (`eval.luv.Loop`/`ThreadPool`: libuv; the test's last 2 assertions are not reached) |

Root causes of the port failures, one per fix:

- nullsafety segfaulted on HashLink: the nested-`try` HashLink JIT bug
  above (CallUnification), reached when a null-safety error followed a macro
  call. Found with gdb: the uncaught `Abort` longjmp'd to a trap below the
  stack pointer (a dead frame).
- unit-macro: the matcher passed an anonymous `{kind,pos}` as `Dynamic` where
  the `ConstructorData` class is read (HashLink cast error on non-exhaustive
  null matches); `Path.mkdir_from_path` split with an `EReg` without `g`, so
  `--hxb bin/hxb/eval.zip` only created `bin/`.
- unit-macro tests: OCaml `float_of_string` (`core.ds.OcamlFloat`: skips `_`,
  reads the whole string, hex/nan/inf) where upstream uses it (Eval
  constants, Macro API, optimizer, inliner, `#if`), so `12.3_4` is not
  `12.3`; `Numeric.parse_int` translated directly (`Std.parseInt("+-123")` is
  null); resources kept as bytes (UTF-8 decoding lost bytes of binary
  resources); NUL in Eval regex patterns passed as `\x00` (HashLink compiles
  NUL-terminated patterns); Eval sockets on HashLink (`EvalHostNet`: the
  `hxc.NativeNet` interface over the host's `sys.net.Socket`).
- unit-macro-hxblib reused unit-macro's archive, which was never written.
- connect-stdin "without close": the client forwarded `Sys.stdin()` with
  `readBytes` (HashLink `fread`: waits for 1024 bytes) and the blocked reader
  held the stdin `FILE` lock, so glibc's `exit` hung. On HashLink the client
  now polls descriptor 0 with `select` and reads it with `read(2)`, and joins
  the forwarding thread as upstream does (`PipeThings.RawStdin`).
- sys-hxb printed 133 `WDeprecatedEnumAbstract` warnings at unknown
  positions: types aliased the declaration's metadata array and unshifted
  `@:enum` (null_pos) into it, which the second `--next` compilation saw
  when typing the cached AST again. Types and fields now copy the
  declaration's metadata (upstream prepends to an immutable list).
- compiler-loops: fixed by the abort after typing above.

Excluded in `test/upstream.py`, for both compilers:

- misc-resolution (`RESOLUTION_EXCLUDED`): Issue9367, modulestatics and spec
  `compile.hxml` compile with `-js` and run `node test.js`.
- sys-hxb and sys-run (`STEP_PATCHES`): the `--cmd haxe
  compile-neko-exitcode.hxml` block of `compile-each.hxml` (builds
  `bin/neko/ExitCode.n` with `-neko` and `nekotools`; `ExitCode.getNative`
  only copies it on Windows, gcc builds `bin/ExitCode` elsewhere). sys-run
  needs it too: `TestCommandBase.testCommand` runs `haxe compile-each.hxml`.

Remaining failures (host limits of the HashLink build, not typing):

- `unit.TestGcFinalizer` (4 tests): `Gc.finalise` needs finalisers on
  arbitrary values; HashLink has neither finalisers nor weak references for
  Haxe objects, and a finaliser receives the value, which would have to be
  resurrected after the host GC freed it.
- threads `cases.TestEval.testNative`: `ThreadPool.queueWork` needs a
  libuv loop, which only the hxc host provides (`EvalLuv`); the `sys.thread`
  and `eval.luv.Thread` parts of the test pass (eval.luv threads and
  synchronization primitives need no libuv, see "eval.luv threads" below).

### The C build of the port (hxc)

```sh
RT_NO= RT_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto -luv" sh backend/build.sh port     # tcc
CC="gcc -O2" BIN=hih_o2 RT_NO= RT_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto -luv" sh backend/build.sh port
HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih python3 test/upstream.py
```

| Step | Reference | HashLink build | hxc build (tcc and gcc -O2) |
| --- | --- | --- | --- |
| unit-macro | 11372/11372 | 11367/11371, 4 errors (Gc.finalise) | 11372/11372 |
| unit-macro-hxblib | 11372/11372 | 11367/11371, 4 errors | 11372/11372 |
| nullsafety | pass | pass | pass |
| misc | 684/684 (2 excluded) | 684/684 | 684/684 |
| misc-resolution | 7/7 | 7/7 | 7/7 |
| sys-hxb, sys-run | pass | pass | pass |
| compiler-loops | 19/19 | 19/19 | 19/19 |
| connect-stdin | 10/10 | 10/10 | 10/10 |
| threads | 144/144 | 138/139 (eval.luv) | 138/139 (eval.luv, as HashLink) |

Before the fixes unit-macro segfaulted on hxc; with an unlimited stack it
reported 30 failures and 5 errors. Root causes, one per fix:

- Stack overflow: the hxc regular expression engine (a backtracking
  matcher in continuation-passing style) recursed past the 8 MB process
  stack on a few thousand characters. The program's main now runs on a
  1 GB reserved stack (`rt_run_main`, `RT_STACK_MB`; OCaml 5, which the
  reference is built with, lets the main fiber's stack grow to 1 GB) and the
  main shadow stack is a 1 GB reservation with a guard page.
- `Math.ffloor/fceil/fround` went through Int `floor`, wrapping infinities
  to 0: the hxc std now declares them extern (TestMath, TestBasetypes).
- `String.toUpperCase/toLowerCase` in Eval used the host's mapping
  (ASCII-only on hxc); `EvalString.caseMap` now maps through upstream's
  `EvalBytes.Unicase` tables (`EvalBytesUnicase.hx`) on every host.
- EReg in Eval: hxc.Regex was ASCII-only; it now follows PCRE2_UCP
  (Unicode `\d \w \s \b`, POSIX classes, caseless sets) as PCRE2 does in
  the reference and HashLink (TestUnicode).
- `Int64Map`: the key equality was physical on hxc (Int64 is an object).
- `unit.TestGcFinalizer`: the hxc GC (`rt.c`) implements OCaml's
  `Gc.finalise` (function a root, value a root of minor collections only,
  an unreachable value is copied back by the major collection and its call
  queued; calls run at the next allocation slow path or after Eval's
  `Gc.minor/major/full_major/compact`, which now collect). Weak references
  are not needed by the port's Eval and are not provided. HashLink keeps
  its 4 errors: it has no finalisers on Haxe objects.

Checks after the fixes: conformance 275 PASS + 7 EXPECTED-FAILURE with the
tcc, gcc -O2 and HashLink builds; `test/server.py` with the tcc build
587/587; self-compile CPU time of the gcc -O2 build (`--interp --no-output
--hxb`, min of 3, two rounds, loaded machine): 5.49/5.50 s before,
5.46/5.29 s after. One earlier run with the pre-fix tcc binary stalled for
15 minutes in misc on `eval/projects/Issue10871/Compiler/compile1.hxml`
(the child compiler spinning); it did not recur in the three full misc runs
since (tcc twice, gcc -O2) nor when run alone.

## C build of the port (hxc): OS threads and parallel mode — 2026-10-09, late

gcc, clang and cosmocc builds now run Haxe threads on OS threads with a
stop-the-world collector (backend/README.md, "OS threads (1:1)"); tcc keeps
the green threads below. The port runs its parallel passes (filters,
analyzer, DCE marking, HXB writing) when `-D disable-parallelism` is not
given. `test/conformance.py --parallel N` checks parallel-mode archives: each
run must succeed, the reference must load the archive, and after normalizing
variable IDs (the reference reads the archive with `--hxb-lib` and writes it
again sequentially) it must equal the sequential reference archive.

```sh
CC="clang -O2" BIN=hih_clang RT_NO= RT_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto -luv" sh backend/build.sh port
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih_clang python3 test/conformance.py -j 3 --parallel 3
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih_clang python3 test/conformance.py -j 2 --parallel 3 --cases test/conformance-macro-cases.txt
# the self-compile as a case: "direct self <abs path of a src snapshot> haxe.Main" in a case file
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih_clang python3 test/conformance.py -j 1 --parallel 4 --parallel-reference --cases self-case.txt
```

| Check (clang -O2 build with mbedtls/libuv unless noted) | Result |
| --- | --- |
| Conformance, sequential (tcc, green threads; clang) | 279 PASS + 7 expected failures / same |
| Conformance, macro cases, sequential (tcc; clang) | 66/66 / 66/66 |
| `test/upstream.py threads` (clang; 4 runs) | 144/144 assertions each |
| Conformance `--parallel 3` (837 parallel runs; two rounds, before and after the `Inline.hx` fix) | 279 PASS + 7 expected failures; every run of every case identical to the sequential reference after normalizing (raw-identical: 3/3 runs in 31 cases, 0/3 in 174) |
| Macro cases `--parallel 3` | 66/66 pass; 54 normalized-identical in 3/3 runs, 12 cannot be normalized because the reference cannot reload its own archive without the sources (macro-built types; runs succeed) |
| Self-compile `--parallel 4 --parallel-reference` | port 4/4 and reference 4/4 identical after normalizing (434 members), 0 raw-identical for either |
| `backend/bench/threads` (clang -O2, OS threads; 10 runs, loaded machine) | all |
| ThreadSanitizer, runtime instrumented (backend/README.md): self-compile ×2, stdlib, hello in parallel mode; `backend/bench/threads` fully instrumented | after the fixes below: 0 reports on the port runs; bench: only races of the test program's own unsynchronized Haxe variables and arrays |

No run crashed or hung. Found and fixed:

- `Inline.hx`: parallel filter workers inlining into classes of the same
  module unshifted into that module's `mInlineCalls` array at the same time
  (TSan: `Array_insert` vs `hx_apush_slow`/`hx_arr_grow`). Upstream conses
  onto an immutable list; the port's push now takes a mutex.
- hxc std: `EReg.escape` shared one static `EReg`; `Regex` published its
  case-set map before filling it (both by review).
- `rt_nthreads` was read plainly while updated atomically (TSan): relaxed
  atomic loads (`RT_NTHREADS`).
- `backend/bench/threads` semaphore test: an unguarded counter and a fixed
  10 ms sleep failed on a loaded machine (1 run in 5) with OS threads.
- Earlier on this branch: `RenameVars`/`AnalyzerTexpr` shared static
  `EReg`s, which corrupted generated variable names in parallel mode.

Benign races left (TSan, plain stores): `sys.thread.Thread.create` (std,
as on HashLink) stores the thread's id and name from both the parent and the
child; new expressions published to other filter workers without a fence
(upstream's documented races, x86-64 store order).

Not run in this pass (by request, the full matrix runs at merge): gcc -O2
and cosmocc conformance, the wasm build, `test/server.py`, the other
`test/upstream.py` steps, `--parallel` on tcc.

## C build of the port (hxc): green threads — 2026-10-09

The hxc runtime has M:1 cooperative threads (`backend/rt/rt_thread.c`, see
`backend/README.md`), and the C build of the port uses the hxc `sys.thread`
package instead of the single-threaded stand-ins of `bench/js-shims`, so
the compilation server works in it. `test/server.py` takes the port command
from `HAXE_IN_HAXE_PORT`, as `test/conformance.py` does. The hxc
`sys.net.Socket.bind` sets SO_REUSEADDR as HashLink's does, so a server
restarted on its port (`tests/misc/eval/connect_stdin` reruns) can bind.

```sh
sh backend/build.sh port                     # bin/backend/hih/hih (tcc)
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=bin/backend/hih/hih python3 test/conformance.py -j 3
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=bin/backend/hih/hih python3 test/server.py -j 2
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT=bin/backend/hih/hih python3 test/server.py --hxb-cache -j 2
HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih python3 test/upstream.py threads connect-stdin
sh backend/build.sh backend/bench/threads Threads && bin/backend/Threads/prog_c
```

| Check (hxc build of the port, tcc unless noted) | Result |
| --- | --- |
| Conformance (also gcc -O2) | 275 PASS + 7 expected failures |
| Conformance, macro cases / `--hxb-lib` / hxblib cases | 66/66, 275 + 7, 7/7 |
| Server, `-D disable-hxb-cache`: all scenarios (also gcc -O2) | 587/587 |
| Server, default HXB cache: all scenarios | 587/587 |
| Server, macro cases (both cache modes) | 132/132 |
| `tests/threads` in the port's Eval (`--interp`; tcc, gcc -O2, cosmocc) | 144/144 with libuv (tcc, cosmocc; see "eval.luv threads") |
| `tests/misc/eval/connect_stdin` (`--wait`/`--connect` stdin forwarding) | 10/10 |
| `backend/bench/threads` (Lock, Mutex, Deque, Semaphore, Condition, Tls, messages, sleep, GC, preemption at allocation, contention, exceptions, sockets, processes; tcc, gcc -O2, cosmocc; nursery 4 KB to 4 MB) | all |
| Server, cases with `RT_MINOR_KB=64` (a thread switch at every 64 KB of allocation while others are runnable) | 564/564 |
| Server `misc` and conformance, cosmocc build (`hih.com`) | 10/10, 275 + 7 |
| Self-compile CPU time, gcc -O2 (`--interp --no-output`, min of 5, two rounds) | 4.05/4.06 s before, 4.03/3.86 s after |

## Cosmopolitan builds with mbedtls and libuv — 2026-10-09

The APE builds link mbedtls 2.28.10 and libuv 1.48.0 built with cosmocc
(`backend/tools/cosmo-deps.sh`; bench/COSMO.md, backend/README.md).

```sh
sh backend/tools/cosmo-deps.sh               # bin/cosmo-deps (cosmocc on PATH)
CC="cosmocc -O2" RT_DEPS=bin/cosmo-deps BIN=hih.com sh backend/build.sh port
HAXE_REFERENCE=haxe/haxe HAXE_IN_HAXE_PORT="sh bin/backend/hih/hih.com" python3 test/conformance.py -j 3
sh bin/backend/hih/hih.com -cp backend/bench/natives -main Luv --interp
sh bin/backend/hih/hih.com -cp backend/bench/natives --run Tls 4433 ca.pem example.com   # openssl s_server on 4433
```

| Check (cosmocc fat APE with mbedtls and libuv, Linux x86-64) | Result |
| --- | --- |
| Conformance | 275 PASS + 7 expected failures |
| Conformance, macro cases | 66/66 |
| `tests/threads` in the port's Eval | 144/144 |
| `backend/bench/natives/Luv.hx` (`--interp`, macro; also the haxelib `hxc.com`) | all, as the reference |
| `backend/bench/natives/Tls.hx` (local `openssl s_server`, HTTPS GET of example.com; also `hxc.com`, `-D hxc.static -D hxc.ssl` through the haxelib package, tcc with system mbedtls) | all, as the reference |

## eval.luv threads, thread pool and synchronization — 2026-10-09

`eval.luv.Thread`, `ThreadPool`, `Once`, `Mutex`, `RwLock`, `Semaphore`,
`Condition` and `Barrier` (evalLuv.ml) run on host threads in the port's
Eval (`EvalLuv.hx`: `LuvThreadHandle`, `LuvThreadPool`, `LuvSync`); on the hxc
host these are green threads, `Loop.run` gives way to them while they exist,
and finished thread pool work reaches the loop through an async handle
(backend/README.md). On HashLink everything but `ThreadPool` works (no libuv
loop there).

```sh
RT_NO= RT_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto -luv" sh backend/build.sh port
HAXE_IN_HAXE_PORT=$PWD/bin/backend/hih/hih python3 test/upstream.py threads connect-stdin
bin/backend/hih/hih -cp backend/bench/natives -main LuvThreads --interp   # = haxe/haxe ... --interp
```

| Check | Result |
| --- | --- |
| `tests/threads`, hxc build with libuv (tcc; cosmocc APE with `RT_DEPS`) | 144/144 assertions (reference 144/144) |
| `tests/threads`, HashLink build | 141/142 (`ThreadPool`: no libuv loop) |
| `backend/bench/natives/LuvThreads.hx` (Thread create/join/self, NativeThread messages and exit in a luv thread, the primitives and their error results, queueWork/cancel, Async from a thread, `Loop.stop`/`ONCE` with threads, exceptions), hxc tcc with libuv, cosmocc | output identical to the reference (5 runs) |
| same without the loop parts: HashLink build, hxc build without libuv | identical to the reference |
| Conformance, HashLink build / hxc build | 275 PASS + 7 expected failures / same |
| Conformance, macro cases (HashLink / hxc) | 66/66 / 66/66 |
| `backend/bench/threads` | all |
| Server conformance (hxc build with libuv), all scenarios | 587/587 |

The earlier count of 138/139 was not a different test set: `testNative`
aborted at `eval.luv.Thread.create`, so its later assertions never ran.

Fixed on the way (hxc runtime, all races at a thread switch inside an
allocation, `rt_alloc_slow` -> `rt_preempt`; they hung or deadlocked the
port's own parallel filters at random, e.g. on one class name but not
another):
- `sys.thread.Tls` kept its values in an unguarded `IntMap` shared by all
  threads: a switch while the map grew left it half rebuilt (an endless
  probe in `remove`). Accesses now hold a mutex.
- `sys.thread.Mutex` allocated its waiter list lazily
  (`if (waiters == null) waiters = []`): two threads could each allocate
  one, and the second assignment dropped the first waiter, which then
  waited forever. The list is now allocated with the mutex.
- `hx_apush_slow` (and `Array.insert`/`unshift`, `hx_aset_slow`) read the
  length before growing the array and used it after the allocation;
  `hx_arr_grow` now retries when another thread grew the array meanwhile.

## Compilation server and haxelib — 2026-10-09

The port runs as a compilation server (`--wait <port>`, `--server-connect`)
and as its client (`--connect`), with the server caches of
`compiler/server/*.ml`, and expands `-L`/`--library` through `haxelib path`.
`test/server.py` sends the same requests to a reference server and a port
server; `test/haxelib.py` uses a local haxelib repository (no network).

```sh
HAXE_REFERENCE=haxe/haxe python3 test/server.py -j 2
HAXE_REFERENCE=haxe/haxe python3 test/server.py --scenario cases --cases test/conformance-macro-cases.txt -j 2
HAXE_REFERENCE=haxe/haxe python3 test/server.py --hxb-cache -j 2
HAXE_REFERENCE=haxe/haxe python3 test/haxelib.py --server
```

| Check (same exit code, client stdout/stderr, HXB members and payloads) | Result |
| --- | --- |
| `-D disable-hxb-cache`: all scenarios (282 cases twice, edit, misc, `--server-connect`) | 587/587 |
| `-D disable-hxb-cache`: macro cases, two rounds each | 132/132 |
| Edit sequence (edit, add, syntax error, fix, remove, touch) | 8/8 |
| Verbose server logs of the edit sequence (reusing/skipping/parsed/directories) | identical (628 lines) |
| `misc`: `--interp` output, stdin forwarding, `--cmd`, macro output, errors, `--next` | 10/10 |
| `--server-connect` (length-prefixed requests, exit on disconnect) | 4/4 |
| Default HXB cache (modules restored with the HXB reader): all scenarios | 587/587 |
| Default HXB cache, macro cases, two rounds each | 132/132 |
| haxelib: batch and server (`-L`, `--library`, `-lib`, dependencies, several libraries, `--haxelib-global`, missing library, hxml) | 14/14 |

After merging the HXB reader, the batch lanes stay green: `test/conformance.py
--hxb-lib` 275/275 with 7/7 expected failures, the macro cases 66/66, the
`--hxb-lib` cases 7/7, and the bootstrap build. Before the merge,
`test/interp.py` gave 270 identical with 2 known host differences
(`process-nonexistent`, exit 127 vs 1), and the all-module and unit builds
passed.

Known limits:

- Display requests work in batch mode (see the display section); `server/*`
  JSON-RPC methods through a server are not covered by a harness yet, and
  `server/module` still raises (it needs `hxb_reader_api_com` in
  `displayJson.ml`).
- The pinned upstream rejects `--wait stdio` ("Invalid host/port"); so does
  the port. The host socket API is IPv4 only: an IPv6 address fails with a
  Failure, where the reference fails with `EAFNOSUPPORT` in this environment.
- File times have one-second resolution on HashLink, so an edit within the
  same second as the previous compilation is not seen (upstream uses
  sub-second times).

Fixes found with these tests: class/field metadata saved for `cl_restore`
must be copied (DCE adds `@:keep` in place), `ClassPaths.relative_path` must
not resolve symbolic links, `Path.find_directories` conses like upstream,
`m_deps` copies where upstream shares a persistent map, and the server's
stdout/stderr pipes buffer like OCaml channels (output order with `--cmd`).

## HXB library input: `--hxb-lib` — 2026-10-09

The port reads HXB archives (`src/compiler/hxb/HxbReader.hx`, a translation
of `hxbReader.ml`, with `hxbLib.ml` and `hxbReaderApi.ml`). `load_module'`
looks a module up in the `--hxb-lib` archives before parsing, as upstream.

```sh
HAXE_REFERENCE=haxe/haxe python3 test/conformance.py -j 2 --hxb-lib
HAXE_REFERENCE=haxe/haxe python3 test/conformance.py -j 2 --hxb-lib --cases test/conformance-macro-cases.txt
HAXE_REFERENCE=haxe/haxe python3 test/conformance.py -j 2 --hxb-lib --cases test/conformance-hxblib-cases.txt
HAXE_IN_HAXE_PORT="hl $PWD/test/generated/conformance/haxe-in-haxe.hl" \
  HAXE_REFERENCE=haxe/haxe python3 test/interp.py -j 2 --cases test/conformance-hxblib-cases.txt
```

- `--hxb-lib` round trip (new `conformance.py` option): after a case passes,
  both compilers load every module of the reference's archive through
  `--hxb-lib`, without the case's class path, and write it again with
  `--hxb`. Every module, std included, then comes from the reader, and the
  writer serializes what it restored. The two outputs must have the same
  member set and byte-identical payloads.
- `hxblib` cases (`test/conformance-hxblib-cases.txt`, new case kind): the
  reference builds a library archive from `test/hxblib/*/lib`, and both
  compilers compile `test/hxblib/*/app` against it. The libraries cover
  classes, interfaces, inheritance, overloads, enums, enum abstracts,
  abstracts with operators, `@:from`/`@:to`, `@:arrayAccess` and properties,
  typedefs, generics (`@:generic`, constraints, default type parameters,
  generic methods), static extensions, `__init__`, dynamic functions, private
  types, module-level fields, macro functions, `@:build` and `@:autoBuild`
  (loaded into the macro context from the archive's `macro/` modules), and a
  broad std selection (with and without `-dce full`). `hl-Issue12357` is
  `haxe/tests/misc/hl/projects/Issue12357` typed for HashLink without
  generation.
- `test/interp.py` runs the `hxblib` cases that use `--interp` with both
  compilers: exit code, stdout and stderr must be identical.

| Check | Result |
| --- | --- |
| Regular set with `--hxb-lib` round trip | 275/275 accepted cases pass with identical round trips; 7/7 expected failures |
| Macro set with `--hxb-lib` round trip | 66/66 pass; 17 round trips identical, 49 rejected by both compilers (the archive alone lacks macro sources or `eval` modules for the detected target) |
| `hxblib` cases (member set, payloads, round trip) | 7/7 (6 identical round trips; the HashLink case is rejected by both because `Main` is a module-level function) |
| `hxblib` cases under `--interp` (exit, stdout, stderr) | 6/6 identical (the HashLink case doesn't execute) |
| Eval-HXB host execution of the `hxblib` cases (`--eval`) | 7/7 identical to the HashLink-executed port |

Upstream tests that use `--hxb-lib`: `tests/unit/compile-hxb-interp-roundtrip.hxml`,
`tests/sys` (`compile-eval-hxb.hxml`) and the hxcoro build in
`tests/runci/targets/Macro.hx` need haxelib (`-lib utest`, `hxcoro`), which
the port does not support yet; `tests/unit/compile-hxb-jvm-roundtrip.hxml`
needs the JVM target. `tests/misc/hl/projects/Issue12357` is covered as above.

Not ported: the server and display uses of the reader (`serverCache.ml`,
`displayJson.ml`, `displayTexpr.ml`) and `commonCache.ml`, which only the
compilation server uses. `read_chunks`/`read_chunks_until` are translated
but have no batch caller.

Two fixes came out of this work:
- HashLink's `Bytes.getString` stops at the first NUL byte, so the reader
  decodes pool strings that contain NUL segment by segment (`"\x00"` in
  `haxe.macro.Printer`).
- `ClassPaths.relativePath` used `sys.FileSystem.fullPath` (`realpath`),
  while upstream's `Path.get_full_path` doesn't resolve symbolic links on
  Unix. With a symlinked std path (a worktree whose `haxe/` links to the
  main checkout), PosInfos file names of std modules stayed absolute, and 85
  regular cases differed from the reference.

## Display services: `--display` JSON-RPC — 2026-10-09

```sh
HAXE_REFERENCE=haxe/haxe python3 test/display.py -j 2 [--extended]
```

`test/display.py` uses the upstream display test corpus
(`haxe/tests/display/src/cases/*.hx`) as input. Each documented test method
holds a snippet with `{-N-}` markers. The harness extracts the snippet like
`Marker.hx`, writes it where `RpcDisplayTestContext`'s Vfs would (one
directory per method), and sends each request that the method body names
(`fields`/`toplevel` → display/completion, `type`/`doc` → display/hover,
`position` → display/definition, `usage` → display/references, `signature`
→ display/signatureHelp, `diagnostics()`, `documentSymbols()`) as a batch
`--display '<json-rpc>'` invocation to both compilers, with the arguments of
`BaseDisplayTestContext.runHaxe`. `initialize`, display/metadata and
display/defines are sent once. Exit code, stdout and stderr must be
identical after the response `timestamp` is zeroed. The upstream assertions
are not evaluated: the reference's answer is the oracle, so a case that
upstream marks as failing still has to be reproduced.

`--extended` also sends every position method (completion, hover,
definition, typeDefinition, implementation, references, signatureHelp) at
every marker, and diagnostics, documentSymbols, statistics and package for
every snippet.

| Run | Requests | Identical | Differ |
| --- | ---: | ---: | ---: |
| Default | 679 | 679 | 0 |
| `--extended` | 7325 | 7325 | 0 |

The default run takes about 4 minutes and the extended run about 70 minutes
with `-j 2`.

Notes:
- In the pinned upstream, `--display` always takes JSON-RPC; the legacy
  `file@pos` form (still used by `XmlDisplayTestContext` and
  `documentSymbols()` there) is a JSON-RPC parse error in both compilers.
- Batch mode runs with a compilation cache like upstream
  (`Server.setup_server_context`/`enable_cache_mode`): toplevel completion
  lists the types of every cached file, so it depends on the parse cache.
- Output order follows OCaml `Hashtbl` iteration, reproduced with
  `core.ds.OcamlHash` (`caml_hash`).
- Not covered: the `server/*` methods (server milestone) and memory
  statistics (`server/memory`, which needs OCaml object sizes).

Bugs found by the corpus besides the display port itself: the lexer lost
lines of the line table on a lexer error, `Std.isOfType(e, StreamError)` in
the grammar tested against an enum constructor, a Dynamic-typed for-loop
display callback received an anonymous structure instead of an `Expr`,
`Path.getRealPath` returned null for a missing file on HashLink, type
metadata prepends mutated the parsed declaration, and
`ClassPaths.relativePath` resolved symlinks (PosInfos file names became
absolute with a symlinked std; the HXB conformance suite caught this in a
worktree whose `haxe/` is a symlink). The extended run also found:
`OcamlHashtbl.hashInt` hashed the untagged int (caml_hash mixes 2n+1, which
also affects Eval's int-keyed tables), statistics read the inline-call pairs
swapped, `ExtString.String.nsplit ""` is `[]`, `magic_type_path` is compared
structurally, and uncaught exceptions print `Printexc` text.

HXB conformance after this work: 275 identical + 7 expected failures; macro
cases 66/66; `test/interp.py`: 269 identical, the 3 known differences below.

After merging the server/HXB-reader branch (cache tables back to OcamlHashtbl
so display output keeps OCaml's order): display default run 679/679,
conformance `--hxb-lib` 275 + 7 expected failures, macro cases 66/66,
`test/server.py` 587/587 with `-D disable-hxb-cache` and with the HXB cache,
`test/haxelib.py` 7/7 and `--server` 14/14, `test/upstream.py misc` 684 tests
with 0 failures (5 recorded skips), bootstrap build.

## Execution: `--interp` and `--run` — 2026-10-08

The port now executes programs on its own Eval (`Generate.generate` →
`MacroContext.interpret`, as upstream). Other code generators are still
missing and fail explicitly.

```sh
HAXE_REFERENCE=haxe/haxe python3 test/interp.py -j 4
```

`test/interp.py` runs every conformance case with both compilers.
Direct/module cases get `--interp`, and hxml cases run when they execute. Each
hxml case runs in a scratch copy of its directory. Exit code, stdout and stderr
must be identical.

| Result | Cases |
| --- | ---: |
| Identical exit code, stdout and stderr | 268 |
| Differ | 4 |
| Skipped (the hxml doesn't execute) | 76 |

The known differences:
- `process-nonexistent` (×2): spawning a missing command exits 127 under
  OCaml's `Unix.create_process` and 1 under HashLink's process API (a host
  runtime difference).
- `eval-eventLoop-compile`: a race. A task scheduled with
  `EventLoop.addTask` runs on a worker thread, and the point where its event
  joins the main loop depends on thread timing. It passes in some runs.
- One run showed "Null access .meta" on two small cases; it didn't reproduce
  in later runs. The harness runs without `-D disable-parallelism`, so the
  parallel filter paths are suspected.

Eval threads (`Thread.create`, and domains used by `createWithEventLoop`) run
on host threads, and `Thread.join` waits on a completion lock.

## Macro milestone: Eval macro runtime — 2026-10-08

The port now runs macros (`--macro`, `@:build`, `macro` functions) in its own
Eval interpreter (`src/macros/eval/`, a translation of `macro/eval/*.ml`), with
the Macro API bridge (`src/macros/MacroApi.hx`) and the macro context
(`src/typing/MacroContext.hx`). See `src/macros/PORTING.md`.

```sh
HAXE_REFERENCE=haxe/haxe python3 test/conformance.py --cases test/conformance-macro-cases.txt -j 8
```

| Check | Result |
| --- | --- |
| Macro-context cases (`test/conformance-macro-cases.txt`): same member set and byte-identical `.hxb` payloads, including the `macro/` modules | 66/66 |
| Regular conformance set (`test/conformance-cases.txt`) | 275/275 accepted, 7/7 expected failures |

The macro list holds the 67 cases that `test/discover-cases.py` excludes for
creating a macro context, minus `eval-Pull11784-compile`, whose hxml sets its
own `--hxb` output.

**Supported host: HashLink.** Conformance is maintained on the HashLink build
(`hl`) only. The JS, JVM, C++ and Go builds are no longer kept passing:
- JS has no string identity. Upstream writes positions with a physical file
  name comparison (`p.pfile != pw.p_file`), so 10 macro cases differ there.
- The JVM build fails bytecode verification. Since the AST records became
  classes, genjvm switches on `Dynamic` values without a cast.

Not supported: mbedtls (TLS) and libuv natives, and the Eval debugger. Code
reaching them throws "... is not supported by haxe-in-haxe". The mbedtls enum
constants are registered.

### Porting pitfalls behind the macro fixes

- OCaml's physical equality on strings matters for HXB output. Positions from
  macros carry freshly decoded file name strings
  (`core.ds.StrTools.physNeq`).
- HashLink's `StringMap` truncates keys at NUL, so `"\x00"` and `""` collided
  in the HXB string pool (`core.ds.StringPool`).
- In `make e :: loop el tl`, OCaml evaluates the recursive tail first. Enum
  pattern arguments are therefore typed last to first, and that order decides
  variable ids (`ExprToPattern`).
- Upstream iterates immutable field lists. Filters that add fields
  (`local_statics`) must not see their own additions (`SafeCom`).
- `t_infos` returns the live record. The port's projection had to be re-read
  after build macros replaced metadata (`TypeloadFields`).
- HashLink can't cast optional arguments in function-typed record fields, so
  compiler API callbacks take explicit `depth` arguments.

## First milestone: HXB compile without the macro runtime — 2026-10-07

The translated compiler (`haxe.Main`, a port of the batch path in
`haxe/src/compiler/haxe.ml`) now produces HXB that matches the pinned
reference compiler byte for byte across the whole conformance set.

```sh
export OPAMROOTISOK=1; eval $(opam env --switch=5.2.1)   # or any OCaml setup
make -C haxe haxe                                          # pinned reference
HAXE_REFERENCE=haxe/haxe python3 test/conformance.py -j 8          # HL host
```

Results (`test/conformance-cases.txt`, 282 cases):

| Check | Result |
| --- | --- |
| Same member set and byte-identical uncompressed `.hxb` payloads as the reference | 275/275 accepted cases |
| Reference consumes every port archive through `--hxb-lib` without the case's class path | 275/275 |
| Cases the reference rejects are rejected by the port too (expected failures) | 7/7 |

The case list holds the smoke inventory (optimization issues, `misc/eval`
projects, `test/unit/moduleload` fixtures) plus every configuration found by
`test/discover-cases.py`. Discovery classifies 543 upstream candidates under
`tests/misc/eval/projects`, `tests/misc/eval/resolution`,
`tests/misc/eval/compiler_loops` and `tests/optimization`: 147 are included
and the rest are recorded in `upstream-hxb-exclusions.md` (306 only have
compile-fail configurations, 67 create a macro context, 10 are rejected by the
reference, 6 need haxelib, 4 are multi-part, 2 make the reference write no
archive, 1 times out). The other upstream suites (`tests/unit`,
`tests/nullsafety`, `tests/threads`, `tests/benchs`, `tests/display`,
`tests/server`, `tests/sys`, target `misc` folders) need `--macro`, haxelib
libraries, display/server services, or a non-HXB target.

The same suite also runs on other builds of the port through
`HAXE_IN_HAXE_PORT` (see `bench/README.md`). The HashLink, HL/C, JS and JVM
builds each pass all 282 cases. So does Go (`bench/hx2go/build.sh`, hx2go
with patches), and C++, built with
`bench/hxcpp-single-thread-mark.patch`; stock hxcpp's parallel GC marking
crashes it (see `bench/README.md`).

Other lanes, all passing:

- `haxe haxe-in-haxe.hxml` (bootstrap build) and `haxe compile-all.hxml`
- `haxe test/unit.hxml`
- `haxe test/upstream-parser-corpus.hxml`: 1,355/1,366 with the translated
  parser (`src/syntax/Grammar.hx`, `src/syntax/Lexer.hx`)

### How the harness runs the port

- The port is compiled to HashLink (`test/generated/conformance/haxe-in-haxe.hl`)
  and run with `hl`, which is roughly ten times faster than Eval. `HAXE_HL`
  selects the VM. HashLink 1.15 fails with "Invalid opcode", so build HashLink
  from master.
- Every invocation uses `-D disable-parallelism`. With parallel filters the
  reference takes variable IDs from a global counter shared between workers,
  so even the reference doesn't produce the same output twice.
- The reference gets the checkout's `haxe/std` explicitly. Otherwise its
  built-in std path leaks into serialized positions.

### Porting pitfalls behind the fixes in this milestone

Most payload differences came from upstream relying on OCaml semantics:

- OCaml evaluates constructor, tuple and function arguments right to left.
  For example, `TVar (fv v, Option.map f eo)` in `Texpr.map_expr_type`
  allocates the initializer's variables before the declared one. Haxe goes
  left to right, so the port names the order explicitly (`Texpr.mapExprType`,
  `Inline`, `Exceptions.catchesToIfs`).
- `Globals.IntMap` uses a reversed comparison, so it iterates in descending
  order. `PMap` iterates in ascending key order using OCaml string comparison
  (`HxbWriter.sortedKeys`).
- `TLazy` is a mutable `tlazy ref`. It is now a `TLazy` class with a mutable
  state, so resolving a lazy type updates every holder.
- Labeled optional arguments (`~static:true`) were mistranslated as
  positional ones.
- `Filename.dirname "Main.hx"` is `"."`, and `Unix.getcwd` has no trailing
  slash.
- On a `Dynamic` subject, an unqualified enum constructor in a pattern can
  resolve to the wrong enum (`Custom` → `ErrorMsg.Custom`, `This` →
  `Keyword.This`). Constructors matched against metadata are qualified as
  `core.MetaList.StrictMeta.X`.
- HashLink doesn't pad missing optional arguments in dynamic calls, so hook
  references and callbacks have typed signatures.

The HXB writer (`src/compiler/hxb/HxbWriter.hx`), the grammar and the lexer
were replaced with direct translations of `hxbWriter.ml`, `grammar.ml` and
`lexer.ml`. The earlier versions are kept as `LegacyGrammar`/`LegacyLexer`
for the bootstrap entry point (`haxe.LegacyMain`) and its unit tests.

### Out of scope for this milestone

- Macro execution: done in the macro milestone above.
- Multi-part builds (`--next`/`--each`), haxelib, display/server, and
  HXB-library input in the port (HXB-library input: done, see above).

## C build of the port (hxc): memory work — 2026-10-09

After the object-layout and GC-policy changes (backend/README.md, "Memory";
bench/README.md), checked on the tcc and gcc -O2 builds (with mbedtls and
libuv):

| Check | Result |
| --- | --- |
| Conformance, tcc / gcc -O2 | 275 PASS + 7 expected failures / same |
| Conformance, macro cases, tcc / gcc -O2 | 66/66 / 66/66 |
| `test/server.py` (tcc) | 587/587 |
| `test/upstream.py`, tcc / gcc -O2 | 10/10 steps each (unit-macro 11372 assertions, misc 684/684, threads 144/144) |
| self-compile, cosmocc APE (no deps) | archive identical to the reference |
| WebAssembly (site/build.sh step 3 flags) | builds |

A GC deduplicating promoted strings was tried and dropped: 10 macro cases
differed, because `StrTools.physNeq` (OCaml's `!=` on position file names)
observes string identity.
