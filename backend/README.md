# backend/ (EXPERIMENTAL)

This is a prototype code generator: one typed IR feeding a WasmGC emitter
and a C emitter. It is an explicit scope expansion and not part of the
port's conformance work. The design, measurements and recommendation are in
[bench/WASM-BACKEND.md](../bench/WASM-BACKEND.md).

- `src/backend/Main.hx`: runs the port's compiler (cross platform). Through
  `compiler.Compiler.generateHook`, it receives the filtered program (what an
  HXB archive holds) and writes `<out>.wat` and `<out>.c`.
- `src/backend/Lower.hx`: typed AST → IR (`Ir.hx`), for the subset listed
  in the design note.
- `src/backend/EmitWat.hx`: IR → WasmGC text (prototype; a real emitter
  would write binary wasm, see the design note §2.7).
- `src/backend/EmitC.hx`: IR → C. Its `Roots` analysis decides which
  references need shadow-stack slots.
- `rt/`: the C runtime (generational copying GC, exceptions, arrays) and
  `run.js`, the Node runner for WasmGC modules.
- `bench/`: the benchmark programs. `tools/`: the baseline builders and the
  Wasmtime/WAMR runners.

```sh
sh backend/build.sh                                   # Bench -> bin/backend/Bench/{prog_c,prog_linear.js,prog.wasm}
HXFLAGS="-D retain" VARIANT=-retain sh backend/build.sh
sh backend/build.sh backend/bench/exc Exc
sh backend/tools/baselines.sh                         # HL/C native, HL/C->wasm, JS for comparison
bin/backend/Bench/prog_c
node backend/rt/run.js bin/backend/Bench/prog.wasm
python3 backend/tools/besttime.py 5 bin/backend/Bench/prog_c
```

`build.sh` needs Node, gcc and Binaryen (`BINARYEN`, default
`/root/emsdk/upstream/bin`). `baselines.sh` also needs Emscripten, the
runtime objects from `bench/build-wasm.sh` and a haxe with the hl2c fix
(`HAXE_HLC`).

## Memory: object layouts, heap census, GC policy

Object layouts (`rt/rt.h`): a header word, then 8-byte slots.

- Classes and anonymous structures pack Int/Bool fields two per slot
  (`EmitC.layout`: in field order, the second fills the free half of the
  previous one; a subclass's layout extends its superclass's). Generated
  code and the runtime address them by 4-byte index (`FH`), which is what
  `rt_field.slot` holds for 'i'/'b' fields of every type. `core.Pos` is 24
  bytes instead of 32.
- Enum values have no tag slot: the constructor is the header's type index
  (constructors of an enum have consecutive indices in tag order, so
  `Type.enumIndex` of a known enum is `TINDEX(v) - base`). Argument-less
  constructors are shared values, as before.
- An `Array` is 24 bytes (length, element kind, data); its capacity is the
  data block's slot count. `[]` has no data block; literals and copies get
  exactly their length, growth from empty goes 2, 4, 8...
- Strings are UTF-16. One byte per character would save 1.6 MB of the 5.5
  MB of strings live at the end of the self-compile (all of them Latin-1),
  less than 1% of the heap, for a change touching every string native; the
  port's lexer interns identifiers per file instead (13.6 → 5.5 MB). A GC
  that deduplicates promoted strings saved 2 MB more but cannot be used:
  string identity is observable in the port (`StrTools.physNeq`, OCaml's
  `!=` on position file names, changes HXB output).

`RT_CENSUS=1` prints a heap census at exit (after a major collection, so
only live objects count; `RT_CENSUS=2` also after every major collection,
`RT_CENSUS_TOP=n` rows): bytes and counts per type, an estimate of the same
data in OCaml's representation (a word per field, no overflow slot,
1-byte strings, arrays as OCaml arrays), strings (Latin-1 share, length
histogram, duplicates), arrays (empty, length histogram, capacity slack),
arrays/strings/maps by the type and field that first refers to them, the
heap's sizes, malloc'd memory and RSS (`rt_census.c`). `RT_STATS=1` prints
each major collection (live, from-space and new limit) and the peak RSS.

`RT_VERIFY` (heap and remembered-set checks, added while debugging the formatter) was dropped when the remembered set became per-thread (OS threads); it needs porting to the per-mutator sets.

GC policy (the copying algorithm is unchanged): the from-space is returned
to the kernel after a major collection (`RT_RELEASE=0` keeps it), the
to-space is faulted in as the copy reaches it, the populate-ahead batch is
an eighth of the space in use (4–32 MB, `RT_AHEAD_MB`), `rt_barrier_range`
remembers a whole object for ranges longer than 16 slots (the port's
`Array.insert` at the front of large arrays used to add the array's length
to the remembered set at every call), and `rt_set_ptr` does not record a
slot again that already held a young pointer.

Self-compile, gcc -O2 (bench/README.md): live heap at exit 214 → 170 MB,
peak RSS 837 → 467 MB (the reference: 531 MB), CPU 5.7 → 5.0 s. With a copying old generation the
peak is about the old space's size at the last major collection plus what
survives it; a mark-sweep or mark-compact old generation (after the OS
threads work) would remove the to-space from the peak.

## Threads: OS threads (1:1) and green threads in the C runtime

The hxc runtime (`rt/rt_thread.c`) runs Haxe threads on **OS threads**
(pthreads, 1:1, in parallel) in gcc, clang and cosmocc builds, and as **M:1
green threads** in tcc builds (tcc has no `__thread`/`_Thread_local`;
`-DRT_GREEN_THREADS` selects them with gcc too). The wasm playground has no
threads. The C build of the port uses them through the hxc `sys.thread`
package (`std-hxc/sys/thread`, over `hxc.NativeThread`) and `haxe.atomic`
(over `hxc.NativeAtomic`): the compilation server, `--connect`/`--cmd` I/O
threads, Eval threads (`--interp`, eval.luv) and the port's parallel compiler
passes (`TaskPool`/`Parallel`: filters, DCE marking, HXB writing; run
without `-D disable-parallelism`).

### OS threads (1:1)

- Thread-local runtime state: the shadow stack (`rt_sp`, `rt_stack_base`),
  the allocation buffer (`rt_young_ptr`, `rt_young_limit`), the handler chain
  (`rt_hcur`) and the pending exception (`rt_exn`) are `__thread` variables
  with the local-exec TLS model (`rt.h` `RT_TLS`): one `%fs`-relative access,
  as cheap as the global it replaces, so generated code is unchanged and the
  sequential self-compile costs the same (bench/README.md). A thread record
  holds its 64 MB C stack (pthread attribute) and 64 MB shadow stack
  (reserved, committed as touched); the main thread keeps its 1 GB ones.
- Allocation: the nursery (`rt_young_start`..`rt_young_end`, 4 MB) is shared;
  each thread bumps through its own chunk (TLAB) taken from it with a CAS:
  with one thread the chunk is the whole free nursery (as before threads),
  with several a 16th of it (`RT_TLAB_KB`). Large objects go to the old space
  with a CAS on its bump pointer. The fast path (`rt_alloc`) is unchanged.
- Stop-the-world collections: the thread whose allocation finds the nursery
  (or old space) full sets `rt_gc_requested` and waits under the world lock
  until every other thread is stopped at a **safepoint** (the allocation slow
  path `rt_alloc_slow`, where the caller's live references are rooted) or in
  a **safe region** (`rt_blocking_enter`/`leave` around blocking calls), then
  collects on its own thread: every thread's shadow stack, pending exception,
  Tls values and entry closure are roots (`rt_threads_scan`), every thread's
  remembered slots and remembered objects are processed
  (`rt_mutators_foreach`), every TLAB is reset, and the threads resume. A
  second thread that wants to collect meanwhile waits as at a safepoint and
  retries its allocation. State changes use seq_cst atomics (Dekker-style:
  either the collector sees a thread safe, or the thread sees the request);
  the slow paths take the world lock.
- Safe regions hold no heap pointer outside the shadow stack (natives root
  what they need and read it again after leaving): waiting for a descriptor
  (`rt_wait_fd`, a `poll` in 100 ms slices so a `close` by another thread
  makes the wait fail with EBADF, as with green threads), sleeping,
  contended mutex/semaphore/condition waits, `waitpid`, `Sys.command`, host
  name resolution (serialized: `gethostbyname` is not reentrant), TLS BIO
  `send`/`recv` (`sslRead`/`sslWrite` go through a malloc'ed copy, since the
  heap buffer may move meanwhile) and libuv's backend wait in `Loop.run`.
  Leaving a safe region waits for a collection in progress.
- Write barrier: each thread appends to its own remembered set
  (`rt_mutator`), merged by the collector; a thread that ends hands its set
  to a "dead" mutator kept until the next minor collection. `rt_set_ptr`'s
  duplicate check (a slot already holding a young pointer is remembered)
  stays valid: whichever thread recorded the slot, all sets are processed.
- Shared runtime tables: field names added at run time live in chunks that
  never move (readers take no lock; adding takes a leaf lock), as does the
  eval.luv handle table. Inline caches are filled once with a CAS (0 → busy
  → type, published with release order) once a second thread exists; a miss
  on an entry filled for another type looks the field up in a per-thread
  table of immutable entries (a generated access may read its entry after
  evaluating arguments that miss again). Identity hashes are set with a CAS
  on the header; cached string hashes are a benign same-value race (relaxed
  atomics); finaliser registration/dequeuing and the native-handle list have
  leaf locks. Statics are initialized eagerly at startup (no lazy class
  init). Leaf locks (`rt_lock`, taken only once a second thread was started)
  are never held across a safepoint.
- `sys.thread` primitives are natives: `Mutex` (re-entrant, a pthread mutex
  plus owner/depth), `Condition` (its own mutex and a pthread condition on
  `CLOCK_MONOTONIC`; spurious wakeups possible as on other pthread targets),
  `Lock`/`Semaphore` (a counting semaphore), `Deque` (Haxe over a mutex and a
  condition), `Tls` (per-thread slot arrays kept with the thread record, gone
  when the thread ends). Handles are `T_NATIVE` objects freed by the collector
  once unreachable (`rt_native_new`); a thread waiting on one roots it. A
  thread blocked on a primitive is in a safe region, so a collection never
  waits for it, and the primitives' internal pthread mutexes are taken
  "safely" (try, else wait in a safe region) because a holder may wait for a
  collection when it leaves a wait. `NativeThread.park`/`unpark` remain
  (per-thread parker, never freed).
- `haxe.atomic` (`std-hxc/haxe/atomic`): `AtomicInt` is a raw cell and
  `AtomicObject` a one-slot reference array, with sequentially consistent
  `__atomic` operations (object stores go through the write barrier);
  `compareExchange` compares references. `AtomicBool` is the std's, over
  `AtomicInt`.
- `TaskPool` (`src/core/ds/TaskPool.hx`) keeps persistent worker threads on
  hxc, as on HL/C (`#if (hlc || target.name == "hxc")`), instead of starting
  threads for every `parallelFor`.
- `RT_STATS` adds a line: threads started, contended mutex acquisitions and
  their wait, stops of the world and the time until every thread had
  stopped (the self-compile in parallel mode: 3 workers, ~840 contended
  acquisitions, 0.3 s waiting, ~410 stops, 0.19 s to stop, max 6 ms on the
  loaded 4-core box).
- Limits: a loop that never allocates and never blocks delays a collection
  (there are no polls at loop back-edges; every loop in the port allocates
  or calls something that does, and time-to-safepoint stays in the
  milliseconds); a blocking call outside a safe region (a write to a full
  pipe, `accept` after another thread took the connection, file system
  calls) likewise. Racy publication of new objects between threads (no
  lock or atomic) relies on x86-64's store order, as the port mirrors
  upstream's benign races (e.g. InlineConstructors reading another field's
  expression while it is rewritten; OCaml 5 guarantees this, C does not):
  the aarch64 half of the APE build is not validated for it. Eval threads
  run in parallel (upstream: OCaml domains); `Thread.create` ignores the
  stack size; the main thread's exit ends the process (as on hl and cpp).
- Shared mutable state of Haxe code is the program's business, as on any
  threaded target: a Haxe `Array` mutated by two threads at once can lose
  elements or be copied while it is moved. Upstream's OCaml leans on
  immutable lists (`l <- x :: l` is memory safe under races) where the port
  mutates arrays in place, so such spots need a lock in the port: the
  parallel filters' inline-call recording (`Inline.hx`, `mInlineCalls`)
  takes a mutex, and shared `EReg`s (which keep their last match) were
  replaced by fresh ones (`RenameVars`, `AnalyzerTexpr`, hxc `EReg.escape`);
  hxc `Regex`'s lazily built case sets are published whole.
- ThreadSanitizer: a build with the whole program instrumented does not run
  (libtsan's fixed-size shadow call stack overflows in the port's parser,
  single-threaded too, and TSan then hangs in its signal handler). What
  works is instrumenting the runtime only: generated C compiled plainly
  with `-D__SANITIZE_THREAD__` (so `RT_TRY` uses the intercepted `setjmp`),
  `rt*.c` with `gcc -fsanitize=thread --param
  tsan-instrument-func-entry-exit=0`; it sees every access the runtime
  makes (allocation, barriers, arrays, strings, maps) and every lock, and
  found the `mInlineCalls` race (test/TESTING.md). Racy publication
  (above) shows up as occasional `Array_slice` reports.

### Green threads (tcc, M:1)

- Switching: `ucontext` (`makecontext`/`swapcontext`). A thread record holds
  its C stack and shadow stack (64 MB each, reserved), handler chain and
  pending exception; a switch saves the globals `rt_sp`, `rt_stack_base`,
  `rt_hcur` and `rt_exn` (`RT_TLS` is empty here) into the record and loads
  the next thread's. One mutator (remembered set, TLAB) serves all of them.
- Scheduling points: parking in the primitives (queues of parked threads in
  C, `rt_thread.c`: they do not allocate between looking at a primitive and
  parking, so they need no atomics), `Sys.sleep` (0 yields), waiting for a
  descriptor, and each minor collection (`rt_alloc_slow`), so a spin loop
  that allocates does not starve the others; one that never allocates does.
- I/O while other threads exist: a blocking socket (`rt_net.c`) is used
  without blocking (`MSG_DONTWAIT`, a `poll` before `accept`, a non-blocking
  `connect`) and the thread waits for the descriptor in the scheduler,
  honouring `setTimeout`; `Socket.select` waits in the scheduler, then
  selects without waiting; pipe/terminal reads and writes wait until ready;
  `Process.exitCode()` polls the child with growing sleeps; `close` makes a
  waiter fail (EBADF). When no thread can run the scheduler waits in `poll`
  up to the nearest timer; if none can ever be woken it prints `fatal:
  deadlock, every thread is blocked forever` and exits with 1. Still
  blocking the process: stdout/stderr writes, `Sys.command`, file system
  calls, host name resolution, TLS and libuv calls other than `Loop.run`.
- `haxe.atomic` operations are plain (no thread switches inside them).

### Both

- `eval.luv` threads (`EvalLuv.hx`): `Thread.create` runs the Eval function
  on a new thread with its own Eval thread context, `ThreadPool.queueWork`
  hands the work to a pool of `UV_THREADPOOL_SIZE` threads (default 4); a
  finished work signals a `uv_async_t` of its loop, whose callback (inside
  `Loop.run`) calls the after-work callback. `Mutex`, `RwLock`, `Semaphore`,
  `Condition`, `Barrier` and `Once` are Haxe over the hxc `sys.thread`
  primitives (safe regions with OS threads; libuv's `uv_mutex_t` would block
  a green scheduler). libuv's own thread pool runs file system and DNS
  requests in C.
- Exit: the process exits when the main thread's `main` returns. An uncaught
  exception ends only its thread (`Thread.onAbort` prints it). Thread ids
  are small integers (main: 1); `Thread.events` is not available (the custom
  target does not define `target.threaded`).
- Under `__EMSCRIPTEN__` there are no threads: `Thread.create` throws
  "threads are not supported", a wait that would block forever throws, and
  a timed wait sleeps and times out.

`bench/threads/Threads.hx` checks the package (`sh backend/build.sh
backend/bench/threads Threads && bin/backend/Threads/prog_c`; with
`CC="gcc -O2"` on OS threads). `sys.net.Socket`/`Host` are real
(`backend/std-hxc/sys/net`, over `rt_net.c`).

## Finalisers and regular expressions

- `rt.c` keeps OCaml's `Gc.finalise` semantics for Eval's `eval.vm.Gc`
  (`hxc.NativeGc`, used by `src/macros/eval/EvalStdLibA.hx`): a finaliser's
  function is a root and its value a root of minor collections only; a
  major collection that finds the value unreachable copies it back (it
  lives on for the call) and queues the call. Queued calls run at the next
  allocation slow path or after Eval's `Gc.minor`/`major`/`full_major`/
  `compact` (which collect). Weak references are not provided.
- `hxc.Regex` (EReg) follows PCRE2 with `PCRE2_UCP`, as Eval and HashLink:
  `\d \w \s \b` and the POSIX classes use Unicode properties and caseless
  matching uses Unicode case variants (tables from
  `tools/mkunicode.py`). It matches UTF-16 code units: `.` and classes see
  the two halves of a surrogate pair separately.

## TLS and libuv: mbedtls and libuv natives

`rt/rt_ssl.c` (mbedtls 2.28 API, behind `hxc.NativeSsl`) backs the Eval
interpreter's `sys.ssl`/`mbedtls.*` (`src/macros/eval/EvalSsl.hx`) and the
hxc target's own `sys.ssl` (`std-hxc/sys/ssl`: `Socket`, `Certificate`,
`Key`, as Eval's `_std` versions over `NativeSsl`; `setCertificate`,
`addSNICertificate` and `Digest` are missing there as in Eval).
`rt/rt_uv.c` (libuv 1.x, behind `hxc.NativeUv`) backs `eval.luv`
(`src/macros/eval/EvalLuv.hx`). `-DHXC_NO_SSL`/`-DHXC_NO_UV` build stubs that
throw when called.

- Native builds link the system's libraries: `RT_NO=
  RT_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto -luv" sh backend/build.sh port`
  (Ubuntu: `libmbedtls-dev libuv1-dev`, mbedtls 2.28, libuv 1.48).
- Cosmopolitan builds link static libraries built with cosmocc by
  `tools/cosmo-deps.sh` (fat x86-64 + aarch64 `.a` files and headers in
  `bin/cosmo-deps`; pinned mbedtls 2.28.10 and libuv 1.48.0, fetched with git
  at their tags and checked against the pinned commits, patched with
  `tools/cosmo-patches/*.patch`; about 2 minutes once). `haxelib/build.sh`
  (`hxc.com`) and `site/build.sh` (`haxe-in-haxe.com`) run it and link the
  result (`NO_DEPS=1` keeps the stubs); `backend/build.sh` links it with
  `RT_DEPS=bin/cosmo-deps`:
  `CC="cosmocc -O2" RT_DEPS=bin/cosmo-deps BIN=hih.com sh backend/build.sh port`.
  User programs built with `-D hxc.static -D hxc.ssl`/`-D hxc.uv` link the
  copy in the haxelib package (`cosmo/`, 1.6 MB zipped), so nothing is built
  or downloaded on first use besides cosmocc itself.
- mbedtls under Cosmopolitan: entropy from `getrandom()` (the patch; every
  host OS, Windows included). System CA certificates
  (`Certificate.loadDefaults`, the default CA of `sys.ssl.Socket`):
  `Sys.systemName()` is "Linux" on every OS in an APE build, so the std's
  Linux file list is read on Linux, and `hxc_NativeSsl_certLoadDefaults`
  picks the others at run time: `/etc/ssl/cert.pem` on macOS (the system
  roots; certificates added to the keychain are not seen), the std's BSD
  list on FreeBSD/OpenBSD/NetBSD, and on Windows upstream's branch (the
  system "Root" store through `crypt32.dll`, loaded with `LoadLibraryA`).
- libuv under Cosmopolitan: one binary runs on Linux, macOS, the BSDs and
  Windows, so libuv is built as its generic unix port: the `poll(2)` backend
  (`posix-poll.c`, as for GNU/Hurd and Cygwin), no file system events
  (`FsEvent` fails with ENOSYS; `FsPoll` works), interfaces through
  `getifaddrs` (no hardware addresses), memory, load and uptime through
  `sysinfo`, and `src/unix/cosmo.c` (the patch) for the executable path,
  CPU count (no model, speed or times), resident set size (the peak) and
  random bytes. Cosmopolitan's errno constants are variables holding the
  host OS's values, so libuv's `UV_E*` codes take the fixed values of its
  Windows table and system errors are translated at run time
  (`uv__cosmo_err`); interface names in IPv6 scope ids are numeric only
  (no `if_nametoindex`), and source-specific multicast is unsupported.
- `Loop.run` with one thread is `uv_run` (it blocks the process). While
  other threads exist (e.g. `eval.luv` thread pool work or a thread
  that will `Async.send`), it runs `UV_RUN_NOWAIT` iterations and waits in
  between (in the green scheduler, or in a safe region with OS threads) for
  the loop's backend descriptor
  (`uv_backend_fd`, the epoll fd) up to `uv_backend_timeout`, so the other
  threads run meanwhile and an `Async.send` from one wakes the loop. A
  thread spawned by a callback during a plain `uv_run` stops it
  (`rt_spawn_hook`) and the run continues that way; `Loop.stop` is
  remembered across those iterations. Without a pollable backend descriptor
  the loop is polled every millisecond. With green threads TLS reads and
  writes still block the process. libuv's thread pool runs file system and DNS requests on real
  threads in C only; their callbacks run on the loop's thread.
  `eval.luv.Thread`/`ThreadPool` run on hxc threads (see the threads
  section).
- Tested on Linux x86-64 only (see bench/COSMO.md): the aarch64 half is built
  but not run (no qemu-aarch64 here), and macOS, Windows and the BSDs are
  untested. Windows is the least likely to work: libuv's unix code there
  depends on Cosmopolitan's emulation of `poll` on pipes, `fork` and Unix
  sockets.

`bench/natives/Luv.hx` (timers, a TCP echo, file system requests, a child
process with a pipe, idle handles, system queries) and `bench/natives/Tls.hx`
(a local `openssl s_server`: handshakes with and without verification, host
name check, system CAs; an HTTPS GET) check a build:

```sh
sh bin/backend/hih/hih.com -cp backend/bench/natives -main Luv --interp
openssl s_server -accept 4433 -cert cert.pem -key key.pem -www &   # cert for localhost, signed by ca.pem
sh bin/backend/hih/hih.com -cp backend/bench/natives --run Tls 4433 ca.pem example.com
```

## The hxc haxelib package

`backend/haxelib/` packages the C target as a library for the user's own Haxe
(`haxe -lib hxc -main Main --custom-target hxc=bin/main`); usage is in
[haxelib/README.md](haxelib/README.md). The user's Haxe types the program;
the init macro (`hxc/Boot.hx`) makes it write the program as HXB and, after
generation, runs the bundled `bin/hxc.com` on the archive (`--hxb-lib`) and
then the C compiler. `hxc.com` is the port with the C backend, compiled by
itself to C and with cosmocc to one portable APE binary.

```sh
sh backend/haxelib/build.sh          # bin/haxelib/hxc.zip (cosmocc on PATH; about 5 min)
haxelib install bin/haxelib/hxc.zip
haxe -lib hxc -cp src -main Main --custom-target hxc=out/main
```

The archive must come from the Haxe build `hxc.com` was made from (the
pinned `haxe/`; recorded in the package's `hxc.json`). The tool runs with the
user's std path as `HAXE_STD_PATH`: DCE reruns on the loaded modules and
treats classes outside the std path as user code (kept whole).

Checked: a Map/sort/exception program and a macro/Reflect/Json program with
cc (gcc), tcc and `-D hxc.static`; `--no-output`, `-D hxc.c-only`, type
errors and `haxelib run hxc`; `bench/natives/Tls.hx` (`sys.ssl`) with
`-D hxc.static -D hxc.ssl` (the package's `cosmo/` libraries) and with tcc
and `-D hxc.ssl` (the system's), and `hxc.NativeUv` with
`-D hxc.static -D hxc.uv`. The backend tool itself built through the
package (`haxe -lib hxc ... -main backend.Main`) gives byte-identical C to
the source build (9 s: typing by the reference compiler, then `hxc.com`).
