# hxmc

The Haxe compiler ported from OCaml to Haxe, and hxmc, a Haxe target that
compiles it (and other programs) to machine code and WebAssembly. hxmc builds
the port for six targets (Linux, macOS and Windows on x86-64 and ARM64) and as
a wasm32-wasi module, and it builds itself. Building everything from a clean
checkout needs only node.

The port behaves exactly like the reference compiler of its pinned upstream
commit: byte-identical HXB, byte-identical output of every target generator,
the same `--interp` runs, display requests and compilation-server answers.

## Layout

| Path | |
| --- | --- |
| `haxe/src/` | the port, module by module after upstream's `haxe/upstream/src/` |
| `haxe/upstream/` | upstream Haxe (submodule, commit `995a7d1fe`): the reference sources and std |
| `haxe/test/` | the port's tests: conformance against the reference (HXB, display, server, JSON-RPC, `--interp`, `-L`, upstream's target suites), the fuzzer (`fuzz/`), unit tests of port modules (`unit/`, `unit.hxml`), peak memory and times (`Measure.hx`) |
| `hxmc/src/hxmc/` | hxmc's sources (package `hxmc`, class path `hxmc/src`): the IR and lowering (`ir/`), the code generators (`x64/`, `a64/`, `wasm/`), the linkers, the driver, `Main.hx` (the tool) and `HaxeMain.hx` (`haxe` with hxmc built in) |
| `hxmc/std/` | hxmc's std: overrides of upstream modules and the runtime's Haxe part (`hxmc.rt`), merged with the Eval originals by `hxmc/src/hxmc/MkStd.hx` |
| `hxmc/c/` | the runtime's C part (collector, threads, TLS over mbedtls, libuv), `deps.sh` (mbedtls and libuv) and `mkrt.sh` (the runtime objects), `zig-version` |
| `hxmc/test/` | hxmc's corpus (`cases/`, golden outputs `expected/`, frozen fuzzer programs `fuzz-1000.zip`), the encoder tests (`encoder/`), the scripts that run them (`Corpus`, `Check`, `Crosshost`, `Selfcheck`, `Tiers`, `EncCheck`), the release smoke test (`smoke.sh`) |
| `hxmc/web/` | the website and its playground (the port as a WebAssembly module in the browser) |
| `hxmc/bootstrap/` | the committed stage0 (`stage0.wasm.br`), node's WASI runner (`wasi.mjs`), the runtime objects by hash (`rt.mjs`), the npm package's launcher (`haxe`, `hxmc-rebuild`, `launcher.mjs`, `build.mjs`) |
| `tools/lix/` | lix (the lix client and haxeshim) ported to build with hxmc |
| `package.json` | the npm package `hxmc` |

## Using hxmc

```sh
npm i -D @hxmc/cli            # node 22 or later; then `npx haxe`, or haxe on PATH through node_modules/.bin
```

The package's `haxe` is the port's command line with hxmc built in: every
target works as usual (`--js`, `--interp`, ...), and `--custom-target
hxmc=<out>` writes an executable. A `build.hxml`:

```hxml
-cp src
-main Main
--custom-target hxmc=bin/app
# another of the seven targets than this machine's:
# -D hxmc.target=windows-x86_64
```

| Option | |
| --- | --- |
| `-D hxmc.target=<target>` | `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `windows-arm64`, `macos-x86_64`, `macos-arm64`, `wasm32-wasi` (default: this machine) |
| `-debug`, `-D hxmc.symbols` | a symbol table (profilers), wasm: a name section |
| `-D hxmc.shared`, `-D hxmc.pic` | a shared library, a position-independent executable (hooks: refused explicitly where not implemented yet) |
| `-D hxmc.jobs=<n>` | parallel module compilations (default: the cores) |
| `-D hxmc.wasm-eh=legacy` | wasm: the legacy exception-handling instructions (`try`/`catch_all`/`rethrow`: Chrome 95+, Firefox 100+, Safari 15.2+) instead of `exnref` (Chrome 137+, Firefox 131+, Safari 18.4+) |
| `HXMC_STATS=1` | what the build did and how long it took |

Packages: `hxmc` holds the compiler's sources (`haxe/src`, `hxmc/`), the std,
the runtime objects of the six targets and the compiler as a WebAssembly
module, the same on every platform; its optional dependencies
`@hxmc/linux-x64`, `@hxmc/linux-arm64`, `@hxmc/darwin-x64`,
`@hxmc/darwin-arm64`, `@hxmc/win32-x64` and `@hxmc/win32-arm64` each hold
the native compiler built by CI for one platform (npm installs the one that
matches, by their `os` and `cpu` fields). `haxe` runs, in this order: a
compiler `hxmc-rebuild` built (in the cache), the platform package's, or,
when there is none (an unsupported machine, an install without optional
dependencies), it builds the native compiler with the WebAssembly one in the
foreground on first use (about 40 s; `HXMC_PLATFORM_PACKAGE=0` forces this
path) into a cache shared by every project (`~/.cache/hxmc/<version>/<target>/`;
macOS `~/Library/Caches`, Windows `%LOCALAPPDATA%`; `HXMC_CACHE` overrides;
the log is `build.log` there; concurrent first calls wait for the same build).
Machines without a native target run the WebAssembly compiler
(`HXMC_NATIVE=0` too).

Without node: on Linux and macOS a postinstall script (best effort, offline,
it only writes inside the package) copies the native compiler over
`hxmc/bootstrap/haxe` and `dist/haxe`, so `node_modules/.bin/haxe` (a link to
it) starts the compiler directly; with install scripts disabled
(`--ignore-scripts`, pnpm's default) the first call through node does the
same. On Windows npm's `haxe.cmd` always starts node (about 40-60 ms per call),
which runs the native compiler; point editors and lix at
`node_modules/@hxmc/cli/dist/haxe.exe` to bypass it. Nothing but the compiler's own
output goes to stdout or stderr (editors run `haxe --wait stdio`, whose answers
are on stderr, and parse `haxe --version`); a notice of a first build goes to
an interactive terminal only, and a failed build prints one line and exits
non-zero. Run `npx haxe --version` once after installing when the fallback
applies; if an editor started before that build finished, restart its
language server. `HXMC_INSTALL=0` keeps the launcher in place.

`hxmc-rebuild` builds the native compiler from the package's (possibly
edited) `haxe/` and `hxmc/` sources with the packaged WebAssembly compiler,
into the cache, which `haxe` then prefers: edit the compiler in
`node_modules/@hxmc/cli` and rebuild. (On Windows the WebAssembly path runs on
node's WASI, whose gaps the launcher fills: `fd_readdir`, drive roots, Windows
paths in arguments; checked in CI on Windows too.)

Editors and lix: vshaxe with `"haxe.executable": "auto"` (the default) runs
the workspace's `node_modules/.bin/haxe` when there is one (as for the lix
npm package; expected from vshaxe's documentation of `auto`, not verified in
an editor here); on Windows set it to `node_modules/@hxmc/cli/dist/haxe.exe`.
`dist/` is an installation lix accepts as a path version (`dist/haxe`,
`dist/std`, `dist/platform.txt`, written on install or first use): `lix use
haxe ./node_modules/@hxmc/cli/dist`, or `.haxerc` with
`{"version": "./node_modules/@hxmc/cli/dist", "resolveLibs": "scoped"}`; lix's
`haxe` shim then runs hxmc (checked with this repository's lix on Linux and
macOS in CI). With the lix npm package in the same project both packages
declare a `haxe` bin: npm reports nothing and `node_modules/.bin/haxe` is
whichever it linked last (both orders occur), so use lix's shim with the
`dist/` version there.

Fast rebuilds: executables keep a `<out>.hxmc/` directory of compiled modules
(only changed modules are compiled again), and the compilation server keeps
typed modules, lowered bodies and compiled objects in memory:
`haxe --wait 6000`, then `haxe --connect 6000 build.hxml` (a no-change rebuild
of a small program in about 0.4 s).

## Building

```sh
git submodule update --init
make hxmc           # bin/hxmc/hxmc, the tool: on first use node runs the stage0, then the tool rebuilds itself
make port           # bin/port/haxe: the port with every generator (seconds after an edit)
make release TARGET=macos-arm64   # bin/release/<target>/haxe[.exe], with mbedtls and libuv
make lix            # bin/lix/lix
make npm            # bin/npm/*.tgz: hxmc and its six platform packages
make site           # bin/site
make help           # everything else
```

The [Makefile](Makefile) needs GNU make, node 22 and git; zig only for the
runtime objects. Everything is cross-built from Linux (macOS works as a host
too).

Bootstrap, as Zig does: `hxmc/bootstrap/stage0.wasm.br` is the tool built for
wasm32-wasi (brotli, 1.4 MB), committed and replaced only when the sources need
a newer one (`make stage0`). node runs it to build the first native tool from
source (`bin/hxmc/boot/hxmc1`, about 25 s), which builds `bin/hxmc/hxmc`; that
one rebuilds itself byte-identically (`make fixpoint`). `make bootstrap` does
all three (about a minute). Scripts run on the tool's Eval (`bin/hxmc/hxmc
-cp ... --run X`: a first argument starting with `-` makes the tool the
compiler's command line), or on the stage0's before there is a tool.

Runtime objects: `rt.o`, `ssl.o` and `uv.o` for the six targets are built by
zig from `hxmc/c` (the C runtime, mbedtls, libuv), which a source-only
bootstrap cannot do. They are keyed by a hash of `hxmc/c` (sources, pinned
versions, flags, the zig version) and published as the GitHub release
`rt-<hash>` (`node hxmc/bootstrap/rt.mjs hash|fetch|pack`); `make rt` downloads
them and falls back to `make rt-build` (zig) when the release is missing. CI
builds them only then, publishes the release from pushes to main and hxmc,
and passes them to its other jobs as an artifact.

The reference compiler is the official nightly of the pinned upstream commit
(build.haxe.org), downloaded by lix: `make reference` (`bin/reference/haxe`,
cached by CI). Nothing builds OCaml.

## Developer loop

| | |
| --- | --- |
| `make hxmc` | the tool after an edit of hxmc or the port: about 11 s (8 s of it typing the port; unchanged modules come from `bin/hxmc/hxmc.hxmc/`) |
| `make port` | the port after an edit: about 13 s (an edit of a central module such as the typer recompiles every module: 26 s) |
| `make quick` | after every edit of hxmc: the x64 corpus, again with `RT_VERIFY=1`, the wasm corpus under node (about 15 s; `CASES="Int64Gc Bench"` restricts it) |
| `make check` | before a commit: quick, arm64 (qemu), x64 Windows (wine), a 16 KB nursery, the wasm corpus with legacy exception handling, ThreadNatives x30, crosshost on three cases (`PORT=1`: the port's self-compile) |
| `make full` | before a push: every nursery and `RT_VERIFY`, wasmtime, the port's self-compile natively and as a module, crosshost on everything, the fixpoint |
| `make test` | HXB conformance of the port against the reference (seconds per 100 cases) |
| `make portcheck` | the port built by hxmc self-compiles to the reference's HXB |

## Testing

Every harness compares the port (`PORT_BIN`, default `bin/port/haxe`) with the
reference (`bin/reference/haxe`); outputs go to `bin/test/`. They are Haxe
scripts on the tool's Eval (`make test-<name>`, or `bin/hxmc/hxmc -cp
haxe/test --run <Name> --help`-style options at the top of each file):

| Script | Compares | Result |
| --- | --- | --- |
| `Conformance` | HXB archives (member names, uncompressed payloads) of `conformance-cases.txt` (286 configurations of the upstream suites), `conformance-macro-cases.txt` (66, run macros), `conformance-hxblib-cases.txt` (`--hxb-lib`); `--hxb-lib`, `--eval`, `--parallel N` modes | 279 + 7 expected failures, 66/66, 7/7 |
| `Display` | `--display` JSON-RPC requests from upstream's removed display suite | 679/679 |
| `Server` | the compilation server: cases twice, edits and invalidation (with the verbose logs), stdin, `--cmd`, errors, `--server-connect` | 595/595 |
| `ServerJsonRpc` | the `server/*` methods, both cache modes | 107/107 |
| `UpstreamTargets` | upstream's unit suite compiled for js, lua, python, php, neko, hl, hl/c, cpp, cppia, cppia host, jvm, flash by both, every output file (jars by member) | 12/12 identical |
| `Interp` | `--interp` runs of the case lists | 275/276 (`eval-eventLoop-compile` depends on thread timing) |
| `Haxelib` | `-L` through lix's haxelib shim, batch and server | 14/14 |
| `EvalDebugger` | scripted Eval debugger sessions (`-D eval-debugger`): breakpoints, stepping, scopes, evaluation, assignment, exception and function breakpoints, a macro | 6/6 |
| `fuzz/` | random programs per target (`diff:<target>`) or by program output (`exec:<a>,<b>`), with reduction (`make test-fuzz LANE=diff:js`) | |
| `Measure` | peak RSS, wall and CPU time: the self-compile (ours and the reference), the native build, the WebAssembly builds | self-compile 879 MB vs the reference's 1414 MB |
| `unit.hxml` | unit tests of port modules, in-process | pass |

Sequential runs pass `-D disable-parallelism`: the reference itself is not
deterministic in parallel mode. Upstream's compiler-side suite (RunCi `macro`:
the unit tests in the macro context with their HXB round trip, null safety,
misc, sys on Eval, threads, third-party projects) runs with the release
binaries as `haxe` (`.github/workflows/upstream-tests.yml`); no target runtime
is installed anywhere: target suites are compared, not run.

hxmc's corpus (`hxmc/test`, `Corpus`): the programs of `cases/` and the frozen
fuzzer programs, compiled by the tool, run with a 64 KB nursery (a missing
root shows) and compared with their golden files, which are frozen (the
outputs of hxc, the C target hxmc came from): a new case gets one with
`--bless` (checked by hand), a changed output is an edit of its golden file
with the reason in the commit. `Libm`: the math library against glibc's on
four targets, bit for bit where glibc rounds as LibM does, with `--core-math
<checkout>` against CORE-MATH's C code and its hard cases (9.5 million
inputs). `Crosshost`: the tool as a WebAssembly module
writes the same bytes as the native tool, for every target, itself included.
`RT_VERIFY=1` fills the free nursery with a pattern, so uninitialized
allocations and missed roots show at once.

CI (`.github/workflows/build.yml`): `rt` (the runtime objects), `build` (the
bootstrap from the stage0, the fixpoint, releases, lix, the npm package, the
site, the corpus for every target, crosshost, the reference, memory and
times), `conformance` (the harnesses above and the fuzzer's diff lanes),
`test` (on each of the six machines: the release binary's smoke test with a
TLS handshake and libuv, lix, the corpus, the self-compile), `wasm` (the
corpus and the self-compile under node and wasmtime, both also with legacy
exception handling under node, the playground in three browser engines with
both modules and its fallback to the legacy one in a Chromium without
exnref), `npm` (the packages in a fresh project on Linux, macOS and Windows:
native at once through the platform package, `--ignore-scripts`,
lix with `dist/`, the WebAssembly fallback and `hxmc-rebuild`),
`upstream-tests`, and `publish-npm` (the six platform packages, then `hxmc`,
with provenance: on `v*` tags as `latest`, from main as a nightly prerelease
`<version>-nightly.<date>.<commit>` tagged `next`; never from other
branches), the nightly release and the website.

## Porting rules

- `haxe/upstream` is the canonical reference: never edit its files or commit
  inside it (the harnesses leave it clean). Moving the pinned revision is a
  deliberate change: it ports every upstream commit in between, must land on
  a commit with a nightly build on build.haxe.org (the reference), and updates
  the revision in `Version.version_extra`'s counterpart
  (`haxe/src/compiler/server/ServerCompilationContext.hx`).
- Read the upstream OCaml module before adding or changing its Haxe
  counterpart, at the matching path (`typing/typer.ml` becomes
  `haxe/src/typing/Typer.hx`; `macro/eval/evalFoo.ml` becomes
  `haxe/src/macros/eval/EvalFoo.hx`, `macro` being a keyword). Names go
  `snake_case` to `camelCase`, records become classes, a name that is a Haxe
  keyword gets a suffix (`throw` becomes `throwValue`).
- Preserve function order, branch order, data layout, error messages and
  exception behavior. Prefer a direct translation over a redesign.
- Reproduce OCaml semantics that reach the output: `Hashtbl` iteration order
  (`core.ds.OcamlHashtbl`), `PMap` order (sorted keys), right-to-left
  evaluation of arguments with side effects, float printing (`core.Numeric`,
  `core.ds.OcamlPrintf`), 31/63-bit integers. Never derive output order from
  Haxe `Map` iteration.
- Never stub out behavior with a silent success: what the port cannot
  support fails explicitly with a `// port:` note.
- Comments from upstream stay at the matching place with upstream's wording
  (`(** *)` becomes `/** */`); a ported file starts with its upstream
  module's license header; every other comment in `haxe/src` starts with
  `// port:` (continuation lines `// ...`) and stays true.
- `haxe/upstream/libs` holds OCaml dependencies: reproduce what the compiler
  reaches (`haxe/src/libs`: the Neko compiler, swflib, zlib's deflate,
  extlib IO, ziplib) rather than porting them.
- Before calling a change done, run the lanes it can affect: HXB conformance
  and macro cases for typing or filters, the fuzzer's `diff:<target>` lanes
  and `UpstreamTargets` for generators, display and server for those
  services, `quick`/`check` for hxmc, everything for broad changes. Never
  commit `bin/`.

## hxmc

hxmc turns a typed Haxe program into a native executable with its own code
generator and linker: no C compiler, assembler or system linker at build time.

```
typed AST --(ir.Lower)--> hxmc IR --(Prep: ir.Facts)--> --(MirBuild)--> Mir (SSA) --(Opt)-->
    --(x64|a64 Isel)--> LIR --(Regalloc, Emit)--> Obj (per module, cached) | --(wasm/WasmGen)--> wasm
    --(DataGen: tables, strings)--> Obj --(Link: ELF | LinkPE | LinkMachO | LinkWasm)--> executable
```

| File (`hxmc/src/hxmc/`) | |
| --- | --- |
| `Main.hx`, `Options.hx`, `Driver.hx` | the tool: runs the port's compiler with a generate hook, compiles every module (in parallel, cached) and links; `--server` keeps the compilation server resident |
| `HaxeMain.hx` | `haxe` with hxmc built in (the npm package): `--custom-target hxmc=<out>` |
| `ir/Ir.hx`, `Lower.hx`, `FnLower.hx` | the IR (structured statements in A-normal form, explicit GC points) and the lowering of the filtered typed AST |
| `ir/Facts.hx`, `Prep.hx` | the program-wide facts: names, layouts, type indices, field ids, no-GC functions, cold sites, GC points, as symbols |
| `UpToDate.hx`, `Fingerprint.hx`, `LowerCache.hx` | rebuilds: the whole build skipped when nothing changed, each module's object reused when its fingerprint is unchanged, lowered bodies reused by the server |
| `Mir.hx`, `MirBuild.hx`, `Opt.hx`, `Inline.hx` | the SSA IR, its construction, inlining, value numbering, store forwarding, LICM, dead code |
| `Lir.hx`, `Regalloc.hx`, `x64/`, `a64/` | instruction selection, linear-scan allocation, encoders (checked against llvm-mc: `EncCheck`), emission |
| `Obj.hx`, `ElfWriter.hx`, `*Reader.hx`, `Link*.hx`, `MkRt.hx`, `DataGen.hx` | objects, the linkers (static ELF; PE with imports written directly; Mach-O with an ad-hoc signature), the runtime-object builder, the program's data |
| `wasm/` | wasm32-wasi: structured code from Mir, the linker, exception handling with `exnref` (or the legacy instructions) |
| `Target.hx`, `Abi.hx` | per-target facts |
| `MkStd.hx` | hxmc's std merged with the Eval originals (the macro context shares the program's class paths) |

Conventions: references live across a GC point are shadow-stack slots
(cold sites spill only on the slow path); `try` is `rt_handler` with the C
library's `_setjmp`; calls follow the target's C ABI; thread-locals use
local-exec TLS on Linux, `_tls_index` on Windows, the TLV template on macOS;
program-wide numbers (type indices, field ids, offsets) are absolute symbols
resolved by the linker, so a module's code does not change when the numbering
does.

Runtime in Haxe: most of the runtime is Haxe compiled with the program
(`hxmc/std/hxmc/rt`: strings, Dynamic access, reflection, arrays, bytes,
dates, inflate, the POSIX and Windows system layers), written with a small
internal API (`hxmc.unsafe`: `Ptr`, `Mem` loads, stores, allocation and
symbols, `Atomic`; `@:hxmc.c` and `@:hxmc.rt` externs of C functions,
`@:hxmc.noGc` functions, `@:hxmc.export`/`@:hxmc.host` implementations of
runtime functions). What stays C (`hxmc/c`): the collector and allocator,
threads and the stop-the-world handshake, TLS over mbedtls, libuv, the field
names and inline-cache tables, float formatting. A change of the runtime's
interface or of the IR's conventions needs a tool that knows it: build once
against the previous runtime first, or bootstrap again.

Math (`hxmc/std/hxmc/rt/LibM.hx`, `LibMTrig.hx`, `LibMArc.hx`): `Math`'s
functions in Haxe for every target, with glibc's results (the reference
compiler's C library): `exp`, `log` and `pow` are Arm's Optimized Routines as
glibc runs them on processors with FMA, bit for bit; `sin`, `cos`, `tan`,
`asin`, `acos`, `atan` and `atan2` are the CORE-MATH project's correctly
rounded functions (glibc's differ from them by an ulp in about one case in a
thousand). They use the processor's fused multiply-add (`Mem.fma`: x86-64
with FMA3, checked once at run time, and ARM64) or an exact one in software
(WebAssembly, older x86-64), with the same results. The C library still
computes the exact functions (`%`, `floor`, `ceil`).

Targets: Linux (static ELF with musl's members), Windows (PE over the UCRT,
imports written from the import libraries), macOS (Mach-O against
libSystem, ad-hoc signed), each on x86-64 and ARM64, and wasm32-wasi (the
whole runtime in Haxe; exception handling with `exnref`, or with
`-D hxmc.wasm-eh=legacy` the legacy `try`/`catch_all`/`rethrow`, which node 22
runs without flags and wasmtime not at all; run with
`node hxmc/bootstrap/wasi.mjs m.wasm` or `wasmtime run -W exceptions=y --dir . m.wasm`;
no threads, sockets or processes). mbedtls 2.28 and libuv 1.48
(`hxmc/c/deps.sh`) become `ssl.o` and `uv.o`, linked only into programs that
use `sys.ssl` or `eval.luv`. Environment for development: `HXMC_OPT=0`,
`HXMC_INLINE=<flat>,<loop>,<runtime>`, `HXMC_SYMBOLS=1`, `HXMC_SIZE_STATS=1`,
`HXMC_DUMP=<function>`, `HXMC_MAP=<file>` (Windows), `RT_MINOR_KB`,
`RT_OLD_MB`, `RT_STATS`, `RT_VERIFY`.

hxmc began as the second back end of hxc, the C target this repository had
until 2026-10-14; its IR, runtime and std came from there, and its corpus's
golden files are hxc's outputs. Plans: [hxmc/PLANS.md](hxmc/PLANS.md); the low-level
API and C interop design: [hxmc/LOWLEVEL.md](hxmc/LOWLEVEL.md).

## License

GPL-2.0-or-later, like the Haxe compiler it is ported from; hxmc's runtime and
std, which end up in compiled programs, are MIT. Details: [LICENSE](LICENSE).
