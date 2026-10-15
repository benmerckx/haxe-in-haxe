# hxmc: the Haxe compiler ported to Haxe (haxe/src) and hxmc, its machine-code
# and WebAssembly target (hxmc/). GNU make, from the repository root; needs
# node (and git), zig only to build the runtime objects (README.md).
#
#   make help                 the targets and variables below
#   make hxmc                 bin/hxmc/hxmc, the tool (from the committed stage0 on first use)
#   make port                 bin/port/haxe: the port with every generator (seconds after an edit)
#   make quick|check|full     the tiered checks (hxmc/test/Tiers.hx)
#   make release TARGET=macos-arm64   bin/release/<TARGET>/haxe[.exe]
#
# Outputs go to bin/ (ignored by Git). hxmc keeps an object per module next to
# each output (<out>.hxmc/) and recompiles only the modules that changed.

# --- Variables (override on the command line: make release TARGET=windows-arm64) ---

# the upstream std, for every compiler run below
export HAXE_STD_PATH := $(CURDIR)/haxe/upstream/std
# the runtime objects, for every build by the tool (also as a WebAssembly module)
export HXMC_RT_DIR := $(CURDIR)/bin/hxmc/rt
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
NODE ?= node
ZIG ?= zig
export ZIG
# the machine the tool runs on (Linux or macOS; its own runtime object)
HOST ?= $(if $(filter Darwin,$(shell uname -s)),macos,linux)-$(if $(filter aarch64 arm64,$(shell uname -m)),arm64,x86_64)
# `make release`, `make lix-release`: one of the six targets
TARGET ?= $(HOST)
TARGETS := linux-x86_64 linux-arm64 windows-x86_64 windows-arm64 macos-x86_64 macos-arm64
# extra arguments of the port's build (e.g. HXFLAGS="-D retain")
HXFLAGS ?=
# the port the tests check
PORT_BIN ?= bin/port/haxe
# the reference compiler: the nightly build of the pinned upstream commit (`make reference`)
REFERENCE ?= bin/reference/haxe
# `make test-fuzz`: the lane and the number of programs
LANE ?= diff:hxb
N ?= 200
# `quick`, `check`, `full`: the corpus cases to restrict the corpus lanes to
# (CASES="Int64Gc Bench"); PORT=1 adds the port's self-compile to `check`
CASES ?=
PORT ?=
# `make site`: a directory of lix binaries to publish under tools/ (lix-<target>[.exe])
LIX_DIR ?=

# --- Sources ---

PORT_SRC := $(shell find haxe/src -name '*.hx')
HXMC_SRC := $(shell find hxmc/src -name '*.hx')
STD_SRC := $(shell find hxmc/std -type f)
RT_SRC := $(wildcard hxmc/c/*)
LIX_SRC := $(shell find tools/lix/src -name '*.hx')
FUZZ_SRC := $(wildcard haxe/test/fuzz/*.hx haxe/test/fuzz/fuzz/*.hx)
WEB_SRC := $(wildcard hxmc/web/src/*.hx hxmc/web/*.html hxmc/web/*.css hxmc/web/data/*)

TOOL := bin/hxmc/hxmc
STAGE0 := hxmc/bootstrap/stage0.wasm.br
STD := bin/hxmc/std/.stamp
HOST_RT := bin/hxmc/rt/$(HOST)/rt.o
# node runs WebAssembly modules (a large stack for the compiler's recursion)
WASI := ulimit -s unlimited 2>/dev/null || true; $(NODE) --stack-size=65500 hxmc/bootstrap/wasi.mjs
# a Haxe script on Eval: the tool when there is one, else the stage0 module
RUN = $(if $(wildcard $(TOOL)),ulimit -s unlimited 2>/dev/null || true; $(TOOL),$(WASI) $(STAGE0))
# the test scripts (haxe/test, hxmc/test), on Eval with the tool
SCRIPT := ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test --run
# the hxmc target: bin/hxmc/std (hxmc/std merged with the Eval originals for
# macros), given last
HXMC_ARGS := -cp bin/hxmc/std --custom-target hxmc
# the tool is the port (haxe/src) with hxmc (hxmc/src) as
# its generate hook, typed against hxmc's std, without the port's other
# target generators
TOOL_CP := -cp haxe/src -cp hxmc/src -main hxmc.Main -D disable-parallelism -D hih_no_generators -cp bin/hxmc/std
TOOL_ARGS := $(TOOL_CP) --custom-target hxmc
# the port (typed with -D disable-parallelism; the binary runs its parallel
# passes unless its own invocation passes that define)
PORT_ARGS := -cp haxe/src -main haxe.Main -D disable-parallelism $(HXFLAGS) $(HXMC_ARGS)
# `haxe` with hxmc built in (the npm package's compiler: every generator)
PKG_ARGS := -cp haxe/src -cp hxmc/src -main hxmc.HaxeMain -D disable-parallelism $(HXMC_ARGS)
EXE = $(if $(findstring windows,$(1)),.exe)
RELEASE_BIN := bin/release/$(TARGET)/haxe$(call EXE,$(TARGET))
LIX_BIN := bin/release/$(TARGET)/lix$(call EXE,$(TARGET))

# $(call hxmc,<out>,<args>): a build by the tool, its log next to the output
define hxmc
@mkdir -p $(dir $(1))
ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(1) $(2) > $(1).log 2>&1 || { cat $(1).log; exit 1; }
@ls -l $(1)
endef

.DEFAULT_GOAL := help
.PHONY: help std deps rt rt-build hxmc tool bootstrap fixpoint stage0 crosshost port dev release wasm npm site fuzz \
	lix lix-release reference test test-fuzz test-display test-server test-jsonrpc test-unit-targets test-interp \
	test-haxelib test-eval-debugger smoke hxmc-test portcheck measure quick check full clean distclean

help:
	@sed -n '/^# --- Targets/,$$p' $(MAKEFILE_LIST) | sed -n 's/^## \{0,1\}//p'

# --- Targets ---
## hxmc        bin/hxmc/hxmc: the tool, built by the previous tool from source (alias: tool);
##             the first one by the stage0 module under node (bin/hxmc/boot/hxmc1)
## bootstrap   the tool from the stage0 only, then the fixpoint
## fixpoint    bin/hxmc/hxmc builds bin/hxmc/fix/a, which builds bin/hxmc/fix/b: byte-identical
## stage0      hxmc/bootstrap/stage0.wasm.br: the tool as a wasm32-wasi module, brotli (commit it
##             when the sources need a newer one)
## std         bin/hxmc/std: hxmc/std merged with the Eval originals (hxmc/src/hxmc/MkStd.hx)
## rt          the runtime objects (bin/hxmc/rt/<target>/{rt,ssl,uv}.o): the release
##             rt-<hash of hxmc/c> (hxmc/bootstrap/rt.mjs), else rt-build
## rt-build    the runtime objects with zig: mbedtls and libuv (hxmc/c/deps.sh), hxmc/c/mkrt.sh
## crosshost   the tool as a WebAssembly module (under node) builds the corpus for every target
##             and the tool itself byte-identical to the native tool (hxmc/test/Crosshost.hx)
## port        PORT_BIN (bin/port/haxe): the port for the host, built by hxmc (alias: dev)
## release     bin/release/TARGET/haxe[.exe]: the port cross-built by hxmc, with mbedtls and libuv
## wasm        bin/wasm/hih.wasm: the playground's compiler (wasm32-wasi, -D hih_no_generators),
##             and bin/wasm/hih-legacy.wasm, the same with -D hxmc.wasm-eh=legacy (browsers without exnref)
## npm         bin/npm/*.tgz: the npm package hxmc (package.json; hxmc/bootstrap) and its six
##             platform packages @hxmc/<os>-<cpu> (NPM_VERSION)
## site        bin/site: the website (hxmc/web; LIX_DIR's lix binaries under tools/)
## fuzz        bin/fuzz/fuzz: the differential fuzzer, built by hxmc
## lix         bin/lix/lix (+ haxe, haxelib, neko links): lix (tools/lix) for the host
## lix-release bin/release/TARGET/lix[.exe]: lix cross-built for TARGET
## reference   REFERENCE (bin/reference/haxe): the nightly of the pinned upstream commit, by lix
## test        HXB conformance of PORT_BIN against the reference (haxe/test/Conformance.hx;
##             CASES_FILE=haxe/test/conformance-macro-cases.txt for the macro cases)
## test-fuzz   the fuzzer on PORT_BIN: LANE (default diff:hxb), N programs
## test-display, test-server, test-jsonrpc, test-interp, test-haxelib, test-eval-debugger
##             the display requests, the compilation server, its JSON-RPC methods, --interp
##             runs, -lib, the Eval debugger: PORT_BIN against the reference (haxe/test/*.hx)
## test-unit-targets   upstream's unit suite compiled for each target by both, compared
## smoke       hxmc/test/smoke.sh on PORT_BIN: --interp, HXB, JS, sys.ssl, eval.luv
## hxmc-test   hxmc's corpus against its golden files (hxmc/test/Corpus.hx)
## portcheck   the port built by hxmc self-compiles to the reference's HXB (hxmc/test/Selfcheck.hx)
## measure     peak memory and time of the self-compile (ours, the reference) and of the
##             tool's builds (haxe/test/Measure.hx)
## quick       after every edit (under a minute): the tool, then the x64 corpus, again with
##             RT_VERIFY=1, and the wasm corpus under node (CASES restricts the corpus)
## check       before a local commit (a few minutes): quick + arm64 (qemu), wine, a 16 KB
##             nursery, the wasm corpus with legacy exception handling, ThreadNatives x30,
##             crosshost on three cases; PORT=1 adds the native port's self-compile
## full        before a push: every nursery, RT_VERIFY, wasmtime, ThreadNatives x300, the
##             port's self-compile natively and as a module, crosshost, the fixpoint
## clean       remove the build outputs (keeps the tool, the runtime objects and the reference)
## distclean   also remove bin/ entirely
##
## Variables: JOBS, NODE, ZIG, HOST, TARGET, HXFLAGS, PORT_BIN, REFERENCE, LANE, N, CASES, PORT,
## LIX_DIR (defaults and meaning: the top of the Makefile).

std: $(STD)
$(STD): hxmc/src/hxmc/MkStd.hx $(STD_SRC)
	$(RUN) -cp hxmc/src --run hxmc.MkStd

# --- hxmc: the runtime objects and the tool ---

# the published objects of this hxmc/c, else built here
rt: $(HOST_RT)
$(HOST_RT): $(RT_SRC)
	$(NODE) hxmc/bootstrap/rt.mjs fetch bin/hxmc/rt || $(MAKE) rt-build
	touch bin/hxmc/rt/*/*.o

# mbedtls and libuv per target (rebuilt only when their versions or flags change)
deps: $(foreach t,$(TARGETS),bin/hxmc/deps/$(t)/VERSIONS)
.PRECIOUS: bin/hxmc/deps/%/VERSIONS
bin/hxmc/deps/%/VERSIONS: hxmc/c/deps.sh
	sh hxmc/c/deps.sh $* bin/hxmc/deps/$*
	touch $@

# the host's object needs no tool (Linux: zig cc and ld.lld); the Windows and
# macOS ones are assembled by the tool (hxmc --mkrt)
rt-build: deps
	sh hxmc/c/mkrt.sh linux-x86_64
	$(MAKE) $(TOOL)
	for t in $(filter-out linux-x86_64,$(TARGETS)); do HXMC=$(CURDIR)/$(TOOL) sh hxmc/c/mkrt.sh $$t || exit 1; done
	$(NODE) hxmc/bootstrap/rt.mjs hash > bin/hxmc/rt/HASH

# The tool compiles its own source with the previous tool (written next to it,
# then moved: the running binary is replaced); the first one comes from the
# stage0 module under node. A change to code generation reaches the tool's own
# code on the next rebuild (`fixpoint` checks that a rebuild changes nothing).
hxmc tool: $(TOOL)
$(TOOL): $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	@if [ ! -x $@ ]; then $(MAKE) --no-print-directory bin/hxmc/boot/hxmc1; fi
	@T=$@; [ -x $$T ] || T=bin/hxmc/boot/hxmc1; \
	echo "$$T $@.new $(TOOL_ARGS)"; \
	ulimit -s unlimited 2>/dev/null || true; \
	$$T $@.new $(TOOL_ARGS) > bin/hxmc/tool.log 2>&1 || { cat bin/hxmc/tool.log; exit 1; }
	mv $@.new $@
	rm -rf $@.new.hxmc
	@ls -l $@

# the stage0 module builds the first native tool (one thread, about half a minute)
bin/hxmc/boot/hxmc1: $(STAGE0) $(STD) $(HOST_RT)
	@mkdir -p $(dir $@)
	$(WASI) $(STAGE0) $@ $(TOOL_ARGS) > $@.log 2>&1 || { cat $@.log; exit 1; }
	chmod +x $@
	@ls -l $@

bootstrap:
	rm -rf $(TOOL) bin/hxmc/boot
	$(MAKE) --no-print-directory $(TOOL)
	$(MAKE) --no-print-directory fixpoint

fixpoint: $(TOOL)
	@mkdir -p bin/hxmc/fix
	ulimit -s unlimited 2>/dev/null || true; \
	$(TOOL) bin/hxmc/fix/a $(TOOL_ARGS) > bin/hxmc/fix/a.log 2>&1 || { cat bin/hxmc/fix/a.log; exit 1; }; \
	bin/hxmc/fix/a bin/hxmc/fix/b $(TOOL_ARGS) > bin/hxmc/fix/b.log 2>&1 || { cat bin/hxmc/fix/b.log; exit 1; }
	cmp bin/hxmc/fix/a bin/hxmc/fix/b && cmp $(TOOL) bin/hxmc/fix/a && echo "fixpoint: the tool rebuilt by itself is byte-identical"
	rm -rf bin/hxmc/fix

# a new stage0 (deliberate: commit it when the sources need it)
stage0: $(TOOL)
	$(call hxmc,bin/stage0/hxmc.wasm,$(TOOL_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) -e "const z=require('zlib'),fs=require('fs'),b=fs.readFileSync('bin/stage0/hxmc.wasm');fs.writeFileSync('$(STAGE0)',z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_LGWIN]:24,[z.constants.BROTLI_PARAM_SIZE_HINT]:b.length}}))"
	@ls -l $(STAGE0)

crosshost: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Crosshost --tool $(CASES)

# --- The port ---

port dev: $(PORT_BIN)
$(PORT_BIN): $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS))

# the release binaries: cross-built from Linux, with mbedtls and libuv (ssl.o, uv.o)
release: $(RELEASE_BIN)
bin/release/%/haxe: $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS) -D hxmc.target=$*)
bin/release/%/haxe.exe: $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS) -D hxmc.target=$*)

# the playground's compiler: a wasm32-wasi module (its runtime is Haxe, no
# runtime object), without the target generators; with exnref, and with the
# legacy exception-handling instructions for browsers without exnref (the
# playground fetches one of the two)
wasm: bin/wasm/hih.wasm bin/wasm/hih-legacy.wasm
bin/wasm/hih.wasm: $(TOOL) $(PORT_SRC) $(STD)
	$(call hxmc,$@,$(PORT_ARGS) -D hih_no_generators -D hxmc.target=wasm32-wasi)
bin/wasm/hih-legacy.wasm: $(TOOL) $(PORT_SRC) $(STD)
	$(call hxmc,$@,$(PORT_ARGS) -D hih_no_generators -D hxmc.target=wasm32-wasi -D hxmc.wasm-eh=legacy)

# --- The npm package (package.json at the root) ---

# what `files` ships besides the sources: the compiler with every generator as
# a wasm32-wasi module, hxmc's merged std and the runtime objects
NPM_GEN := hxmc/bootstrap/haxe.wasm hxmc/bootstrap/hxmc-std/.stamp hxmc/bootstrap/rt/HASH
hxmc/bootstrap/haxe.wasm: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD)
	$(call hxmc,bin/npm/haxe.wasm,$(PKG_ARGS) -D hxmc.target=wasm32-wasi)
	cp bin/npm/haxe.wasm $@
hxmc/bootstrap/hxmc-std/.stamp: hxmc/src/hxmc/MkStd.hx $(STD_SRC)
	$(RUN) -cp hxmc/src --run hxmc.MkStd hxmc/std haxe/upstream/std hxmc/bootstrap/hxmc-std
hxmc/bootstrap/rt/HASH: $(HOST_RT)
	rm -rf hxmc/bootstrap/rt
	for t in $(TARGETS); do mkdir -p hxmc/bootstrap/rt/$$t && cp bin/hxmc/rt/$$t/rt.o bin/hxmc/rt/$$t/ssl.o bin/hxmc/rt/$$t/uv.o hxmc/bootstrap/rt/$$t/ || exit 1; done
	cp bin/hxmc/rt/LICENSE.* hxmc/bootstrap/rt/ 2>/dev/null || true
	$(NODE) hxmc/bootstrap/rt.mjs hash > $@
# the native compilers of the platform packages (@hxmc/<os>-<cpu>)
NPM_NATIVES := $(foreach t,$(TARGETS),bin/npm/native/$(t)/haxe$(call EXE,$(t)))
bin/npm/native/%/haxe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
bin/npm/native/%/haxe.exe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
# NPM_VERSION: the version of all seven packages (default package.json's)
NPM_VERSION ?= $(shell $(NODE) -p "require('./package.json').version")
npm: $(NPM_GEN) $(NPM_NATIVES)
	rm -f bin/npm/*.tgz
	$(NODE) hxmc/bootstrap/pack.mjs $(NPM_VERSION) bin/npm/native bin/npm
	@ls -l bin/npm/*.tgz

# --- The website (hxmc/web) ---

# the pages, their scripts (hxmc/web/src, compiled by the port), the std
# subset the playground's compiler reads (hxmc/web/MkBundle.hx), the measured
# results (hxmc/web/data) and the build facts
mb = awk '{printf "%.1f MB", $$1 / 1048576}'
# the site's build in the addresses of the files its pages fetch (Version.hx)
SITE_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
site: wasm $(PORT_BIN) $(WEB_SRC)
	mkdir -p bin/site
	cp bin/wasm/hih.wasm bin/wasm/hih-legacy.wasm hxmc/web/index.html hxmc/web/story.html hxmc/web/style.css bin/site/
	$(PORT_BIN) -D site_version=$(SITE_VERSION) hxmc/web/build.hxml
	sed -i -e 's/\(src\|href\)="\(playground\.js\|tables\.js\|style\.css\)"/\1="\2?v=$(SITE_VERSION)"/g' bin/site/index.html bin/site/story.html
	$(RUN) -cp hxmc/web --run MkBundle $(HAXE_STD_PATH) bin/site/std.bundle
	cp hxmc/web/data/*.json bin/site/
	rm -rf bin/site/examples && cp -r hxmc/web/examples bin/site/examples
	rm -rf bin/site/tools
	if [ -n "$(LIX_DIR)" ]; then mkdir -p bin/site/tools && cp $(LIX_DIR)/lix-* bin/site/tools/; fi
	printf '{\n\t"date": "%s",\n\t"commit": "%s",\n\t"wasmSize": "%s",\n\t"wasmGz": "%s",\n\t"wasmLegacyGz": "%s",\n\t"dataGz": "%s",\n\t"lixSize": "%s"\n}\n' \
		"$$(date -u +%Y-%m-%d)" "$$(git rev-parse --short HEAD)" \
		"$$(wc -c < bin/site/hih.wasm | $(mb))" \
		"$$(gzip -9c bin/site/hih.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/hih-legacy.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/std.bundle | wc -c | $(mb))" \
		"$$(if [ -f bin/site/tools/lix-linux-x86_64 ]; then wc -c < bin/site/tools/lix-linux-x86_64 | $(mb); else echo -; fi)" > bin/site/build-info.json
	cat bin/site/build-info.json

# --- Other programs ---

fuzz: bin/fuzz/fuzz
bin/fuzz/fuzz: $(TOOL) $(FUZZ_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,-cp haxe/test/fuzz -main Fuzz $(HXMC_ARGS))

# --- lix (tools/lix) ---

HXCORO := bin/hxcoro
HXCORO_REV := 4b1a4d49542c578dc184297b75d125093ca444d2
$(HXCORO)/.rev:
	rm -rf $(HXCORO) && git init -q $(HXCORO)
	git -C $(HXCORO) fetch -q --depth 1 https://github.com/HaxeFoundation/hxcoro.git $(HXCORO_REV)
	git -C $(HXCORO) checkout -q FETCH_HEAD
	echo $(HXCORO_REV) > $@

# Mozilla's CA certificates (curl's extract), trusted besides the system's
# (Windows' preinstalled roots lack common ones), as a generated module
CACERT := cacert-2026-09-25.pem
CACERT_SHA256 := a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
bin/lix/gen/shim/CaBundle.hx: tools/lix/CaBundle.hx
	@mkdir -p bin/lix
	curl -sSfL --retry 3 -o bin/lix/$(CACERT) https://curl.se/ca/$(CACERT)
	$(RUN) -cp tools/lix --run CaBundle bin/lix/$(CACERT) $(CACERT_SHA256) bin/lix/gen

LIX_ARGS := -cp tools/lix/src -cp bin/lix/gen -cp $(HXCORO)/src -main lix.cli.Main -D no-deprecation-warnings $(HXMC_ARGS)
LIX_DEPS := $(TOOL) $(LIX_SRC) $(STD) $(HXCORO)/.rev bin/lix/gen/shim/CaBundle.hx $(HOST_RT)
lix: bin/lix/lix
bin/lix/lix: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS))
	for cmd in haxe haxelib neko; do ln -sf lix bin/lix/$$cmd; done

lix-release: $(LIX_BIN)
bin/release/%/lix: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS) -D hxmc.target=$*)
bin/release/%/lix.exe: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS) -D hxmc.target=$*)

# --- The reference compiler ---

# the official nightly (build.haxe.org) of the pinned upstream commit,
# downloaded by lix into bin/reference/lix (HAXESHIM_ROOT); the pin must be a
# commit with a nightly
UPSTREAM_REV = $(shell git rev-parse --short=7 HEAD:haxe/upstream)
reference: $(REFERENCE)
$(REFERENCE): bin/lix/lix
	mkdir -p bin/reference
	cd bin/reference && HAXESHIM_ROOT=$(CURDIR)/bin/reference/lix $(CURDIR)/bin/lix/lix download haxe $(UPSTREAM_REV)
	ln -sf lix/versions/$(UPSTREAM_REV)/haxe $@
	$@ -version

# --- Tests (README.md, "Testing") ---

CASES_FILE ?= haxe/test/conformance-cases.txt
TEST_ENV = HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT=$(abspath $(PORT_BIN))
test: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Conformance -j $(JOBS) --cases $(CASES_FILE)
test-display: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Display -j $(JOBS)
test-server: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Server -j $(JOBS)
test-jsonrpc: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) ServerJsonRpc
test-interp: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Interp -j $(JOBS)
test-haxelib: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Haxelib
test-eval-debugger: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) EvalDebugger
test-unit-targets: $(PORT_BIN) $(REFERENCE) bin/lix/lix
	$(TEST_ENV) $(SCRIPT) UpstreamTargets -j $(JOBS)

test-fuzz: bin/fuzz/fuzz $(PORT_BIN) $(REFERENCE)
	HAXE_REFERENCE=$(abspath $(REFERENCE)) bin/fuzz/fuzz -j $(JOBS) -n $(N) --port $(abspath $(PORT_BIN)) --lane $(LANE)

smoke:
	sh hxmc/test/smoke.sh $(PORT_BIN)

hxmc-test: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Corpus -v $(CASES)

portcheck: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE)
	$(SCRIPT) Selfcheck --local --small

measure: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE)
	$(SCRIPT) Measure

quick: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers quick $(CASES)

check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers check $(if $(PORT),--port) $(CASES)

full: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers full $(CASES)

clean:
	rm -rf bin/port bin/release bin/site bin/wasm bin/fuzz bin/lix bin/npm bin/stage0 bin/test \
		bin/hxmc/boot bin/hxmc/fix bin/hxmc-t bin/hxmc-fuzz $(NPM_GEN) hxmc/bootstrap/hxmc-std hxmc/bootstrap/rt

distclean: clean
	rm -rf bin
