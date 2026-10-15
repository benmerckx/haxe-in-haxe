# haxe-in-haxe: builds the reference compiler, the hxc backend tool, the port
# (for development, testing and release) and the website. GNU make.
#
#   make help                 the targets and variables below
#   make reference            haxe/haxe, the reference compiler (OCaml 5, opam)
#   make dev                  bin/port/hih: the port, built in seconds (tcc)
#   make port                 bin/hxc/hih/hih_clang: the port with clang -O2
#   make release              bin/release/<TARGET>/haxe-in-haxe[.exe]: zig cc, mbedtls, libuv
#   make test                 HXB conformance of bin/hxc/hih/hih_clang
#
# Outputs go to bin/ (ignored by Git). Generated C is written in chunks and
# compiled in parallel by hxc/tools/cc-chunks.sh, which recompiles only the
# chunks whose C changed; the generators rewrite only the files whose content
# changed, so an edit costs a few compilations (hxc/README.md, "Chunked output").

# --- Variables (override on the command line: make port PORT_CC="gcc -O2") ---

# the reference compiler: compiles the JS backend tool and the site's scripts
HAXE ?= haxe/haxe
# the upstream std, for every compiler run below
export HAXE_STD_PATH ?= $(CURDIR)/haxe/std
# parallel C compilations (cc-chunks.sh, deps.sh)
export JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
NODE ?= node
# how the JS tool finds hxnodejs (without haxelib, e.g. in CI:
# TOOL_LIBS="<clone>/extraParams.hxml -cp <clone>/src")
TOOL_LIBS ?= -lib hxnodejs
# C compilers: the dev port, the native backend tool, the clang port, the fuzzer, `make program`
DEV_CC ?= tcc
TOOL_CC ?= clang -O2
PORT_CC ?= clang -O2
FUZZ_CC ?= clang -O2
PROG_CC ?= tcc
# extra arguments for the port's C (e.g. HXFLAGS="-D retain")
HXFLAGS ?=
# mbedtls and libuv in `make port`: stub (their natives throw), system
# (-lmbedtls ... -luv: Ubuntu's libmbedtls-dev libuv1-dev) or a `make deps` directory
TLS_UV ?= stub
# `make port`'s binary (used by `make test`, `make test-fuzz`)
PORT_BIN ?= bin/hxc/hih/hih_clang
# the port's C compiled by `make port`, `release` and `cosmo`; another
# directory (C generated elsewhere, e.g. in CI) is used as it is
PORT_C ?= bin/hxc/hih/prog_hxc
# the playground's C (`make wasm`), likewise
WEB_C ?= bin/hxc/hih-web/prog_hxc
# `make release`/`make deps`: a zig target (x86_64-linux-gnu.2.28,
# aarch64-linux-gnu.2.28, x86_64-macos, aarch64-macos, x86_64-windows-gnu,
# aarch64-windows-gnu), or cosmo for `make deps`
TARGET ?= x86_64-linux-gnu.2.28
ZIG ?= zig
# the cosmocc directory (default: cosmocc on PATH)
COSMOCC ?=
export ZIG COSMOCC
# the site's scripts are compiled by SITE_HAXE (the port works too)
SITE_HAXE ?= $(HAXE)
# `make site`: lix.com to publish under tools/ (none: the page links a missing file)
LIX_COM ?=
# `make program`: a program of class path CP with main class MAIN, to bin/hxc/<MAIN>/prog_c
CP ?= hxc/test
MAIN ?= Bench
# `make test-fuzz`: the lane and the number of programs
LANE ?= diff:hxb
N ?= 200
# `make smoke`: the binary to check
SMOKE_BIN ?= $(RELEASE_BIN)
# lix (tools/lix): hxcoro's checkout (fetched at HXCORO_REV unless it exists),
# its C (another directory, e.g. generated in CI, is used as it is), the C
# compiler of `make lix` and its mbedtls/libuv (system or a `make deps` directory)
HXCORO ?= bin/hxcoro
LIX_C ?= bin/lix/lix_hxc
LIX_CC ?= clang -O2
LIX_TLS_UV ?= system

# --- Sources ---

PORT_SRC := $(shell find src -name '*.hx')
LIX_SRC := $(shell find tools/lix/src -name '*.hx')
TOOL_SRC := $(shell find hxc/src hxc/js -name '*.hx')
JS_SRC := $(shell find hxc/js -name '*.hx')
HXC_STD_SRC := $(shell find hxc/std -name '*.hx')
RT_SRC := $(wildcard hxc/rt/*.c hxc/rt/*.h)
FUZZ_SRC := $(wildcard test/fuzz/*.hx)

# the runtime files of the release, site and fuzz builds
# (rt_win, rt_sys_win, rt_net_win: the Windows host layer, empty elsewhere)
RT_FILES := rt rt_dyn rt_std rt_str rt_sys rt_net rt_ssl rt_uv rt_thread rt_census rt_win rt_sys_win rt_net_win
# slots are read as int32/double/pointer through casts (FI/FD/FP): no strict aliasing
CFLAGS_BASE := -w -fno-strict-aliasing
NO_TLS_UV := -DHXC_NO_SSL -DHXC_NO_UV
DEPS_LIBS := -lmbedtls -lmbedx509 -lmbedcrypto -luv
# the port's arguments (it is typed with -D disable-parallelism; the binary runs
# its parallel passes unless its own invocation passes that define)
PORT_ARGS := -cp src -main haxe.Main -cp hxc/js -D disable-parallelism
# the hxc target: bin/hxc/std (hxc/std merged with the Eval originals for
# macros, given last: the last class path wins over earlier ones, e.g. hxc/js)
HXC_ARGS := -cp bin/hxc/std --custom-target hxc
STD := bin/hxc/std/.stamp
WBK := bin/hxc/wbk.js
NATIVE_TOOL := bin/hxc-dev/tool
RELEASE_BIN := bin/release/$(TARGET)/haxe-in-haxe$(if $(findstring windows,$(TARGET)),.exe)

# $(call wbk,<out>,<args>): C by the JS tool into <out>_hxc/; files.txt marks the run
define wbk
@mkdir -p $(dir $(1))
$(NODE) --stack-size=65500 $(WBK) $(1) $(2) $(HXC_ARGS)
touch $(1)_hxc/files.txt
endef

# $(call native,<out>,<args>): the same with the native tool (bin/hxc-dev/tool)
define native
@mkdir -p $(dir $(1))
ulimit -s unlimited 2>/dev/null || true; $(NATIVE_TOOL) $(1) $(2) $(HXC_ARGS) > $(1).log 2>&1 || { cat $(1).log; exit 1; }
touch $(1)_hxc/files.txt
endef

# $(call cc,<compiler>,<cflags>,<libs>,<chunk dir>,<binary>[,<more env>])
cc = CC="$(1)" CFLAGS="$(2)" LIBS="$(3)" $(6) sh hxc/tools/cc-chunks.sh $(4) $(5)

.DEFAULT_GOAL := help
.PHONY: help reference tool dev-tool dev port-c port web-c release deps cosmo \
	wasm site fuzz program haxelib lix-c lix lix-cosmo test test-fuzz smoke clean distclean

help:
	@sed -n '/^# --- Targets/,$$p' $(MAKEFILE_LIST) | sed -n 's/^## \{0,1\}//p'

# --- Targets ---
## reference        haxe/haxe, the reference compiler (make -C haxe haxe; needs OCaml 5, opam, pcre2)
## tool             bin/hxc/wbk.js: the backend tool (port + hxc/src) for Node, built by HAXE
## dev-tool         bin/hxc-dev/tool: the backend tool compiled by itself (TOOL_CC); writes C in ~10 s
## dev              bin/port/hih: the port's C by the native tool, compiled by DEV_CC (tcc: seconds)
## port-c           PORT_C: the port's C by the JS tool (what CI generates once for every release)
## port             PORT_BIN (bin/hxc/hih/hih_clang): PORT_C by PORT_CC (TLS_UV: stub, system or a deps dir)
## web-c            WEB_C: the playground's C (-D hih_no_generators)
## deps             bin/deps/TARGET: mbedtls and libuv for TARGET (a zig target or cosmo; hxc/tools/deps.sh)
## release          bin/release/TARGET/haxe-in-haxe[.exe]: PORT_C by zig cc for TARGET, with mbedtls and libuv
## cosmo            bin/release/cosmo/haxe-in-haxe.com: the Cosmopolitan APE binary, with mbedtls and libuv
## wasm             bin/site/hih.{js,wasm,data}: the playground's compiler (Emscripten, emcc on PATH)
## site             bin/site: the website (wasm, pages, their scripts compiled by SITE_HAXE; LIX_COM under tools/)
## fuzz             bin/fuzz/fuzz: the differential fuzzer (FUZZ_CC)
## program          bin/hxc/MAIN/prog_c: class path CP, main class MAIN, by the JS tool and PROG_CC
## haxelib          bin/haxelib/hxc.zip: the hxc haxelib package (hxc/haxelib/build.sh)
## lix-c            LIX_C: the C of lix (tools/lix, with hxcoro fetched into HXCORO) by the JS tool
## lix              bin/lix/lix (+ haxe, haxelib, neko links): LIX_C by LIX_CC with LIX_TLS_UV
## lix-cosmo        bin/release/cosmo/lix.com: lix as a Cosmopolitan APE binary
## test             HXB conformance of PORT_BIN against the reference (test/conformance.py)
## test-fuzz        the fuzzer on PORT_BIN: LANE (default diff:hxb), N programs
## smoke            hxc/tools/smoke.sh on SMOKE_BIN (default: the release binary of TARGET)
## clean            remove the build outputs (keeps bin/deps, bin/hxc-dev and the reference)
## distclean        also remove bin/ entirely
##
## Variables: HAXE, HAXE_STD_PATH, JOBS, NODE, TOOL_LIBS, DEV_CC, TOOL_CC, PORT_CC,
## FUZZ_CC, PROG_CC, HXFLAGS, TLS_UV, PORT_BIN, PORT_C, WEB_C, TARGET, ZIG, COSMOCC, SITE_HAXE,
## LIX_COM, CP, MAIN, LANE, N, SMOKE_BIN, HXCORO, LIX_C, LIX_CC, LIX_TLS_UV (defaults and meaning: the top of the Makefile).

reference:
	$(MAKE) -C haxe -j$(JOBS) haxe

# bin/hxc/std: the hxc target's std
$(STD): hxc/tools/mkstd.py $(HXC_STD_SRC)
	python3 hxc/tools/mkstd.py
	touch $@

# --- The backend tool ---

tool: $(WBK)
$(WBK): $(PORT_SRC) $(TOOL_SRC)
	@mkdir -p $(dir $@)
	$(HAXE) -cp src -cp hxc/src -main backend.Main $(TOOL_LIBS) -cp hxc/js --js $@ -w -WDeprecated

# The native tool regenerates its own C with the previous tool (the JS tool
# makes the first one); a change to the lowering takes effect in what the new
# tool compiles, so the tool itself picks it up on the next rebuild (make -B
# dev-tool). It does not depend on src/: the port it carries only types the
# sources it compiles. The running tool is replaced: the new binary is written
# next to it, then moved.
TOOL_GEN_ARGS := -cp src -cp hxc/src -cp hxc/js -main backend.Main -D disable-parallelism
dev-tool: $(NATIVE_TOOL)
$(NATIVE_TOOL): $(TOOL_SRC) $(RT_SRC) $(STD)
	@mkdir -p $(dir $@)
	if [ -x $@ ]; then \
		ulimit -s unlimited 2>/dev/null || true; $@ bin/hxc-dev/tool $(TOOL_GEN_ARGS) $(HXC_ARGS) > bin/hxc-dev/gen.log 2>&1 || { cat bin/hxc-dev/gen.log; exit 1; }; \
	else \
		$(MAKE) $(WBK) && $(NODE) --stack-size=65500 $(WBK) bin/hxc-dev/tool $(TOOL_GEN_ARGS) $(HXC_ARGS); \
	fi
	$(call cc,$(TOOL_CC),$(CFLAGS_BASE) $(NO_TLS_UV) -DHXC_CONST_IDS,-lm,bin/hxc-dev/tool_hxc,$@.new)
	mv $@.new $@

# --- The port ---

# dev: the ids are const globals (no HXC_CONST_IDS), so a new name does not
# recompile every chunk
dev: bin/port/hih
bin/port/hih: $(NATIVE_TOOL) $(PORT_SRC) $(JS_SRC) $(STD) $(RT_SRC)
	$(call native,bin/port/hih,$(PORT_ARGS) $(HXFLAGS))
	$(call cc,$(DEV_CC),$(CFLAGS_BASE) $(NO_TLS_UV),-lm,bin/port/hih_hxc,$@)

port-c: bin/hxc/hih/prog_hxc/files.txt
bin/hxc/hih/prog_hxc/files.txt: $(WBK) $(PORT_SRC) $(JS_SRC) $(STD)
	$(call wbk,bin/hxc/hih/prog,$(PORT_ARGS) $(HXFLAGS))

web-c: bin/hxc/hih-web/prog_hxc/files.txt
bin/hxc/hih-web/prog_hxc/files.txt: $(WBK) $(PORT_SRC) $(JS_SRC) $(STD)
	$(call wbk,bin/hxc/hih-web/prog,$(PORT_ARGS) -D hih_no_generators $(HXFLAGS))

# HXC_CONST_IDS: the ids fold into the code as #defines (ids.h); every chunk
# then depends on ids.h (hxc/README.md)
ifeq ($(TLS_UV),stub)
PORT_TLS_UV := $(NO_TLS_UV)
PORT_LIBS := -lm
else ifeq ($(TLS_UV),system)
PORT_TLS_UV :=
PORT_LIBS := -lm $(DEPS_LIBS)
else
PORT_TLS_UV := -I$(TLS_UV)/include
PORT_LIBS := -lm -L$(TLS_UV)/lib $(DEPS_LIBS) -lpthread -ldl
endif
port: $(PORT_BIN)
$(PORT_BIN): $(PORT_C)/files.txt $(RT_SRC)
	$(call cc,$(PORT_CC),$(CFLAGS_BASE) -DHXC_CONST_IDS $(PORT_TLS_UV),$(PORT_LIBS),$(PORT_C),$@)

# --- Release builds ---

# deps: TARGET's mbedtls and libuv (the script rebuilds only when VERSIONS changes)
deps: bin/deps/$(TARGET)/VERSIONS
.PRECIOUS: bin/deps/%/VERSIONS
bin/deps/%/VERSIONS: hxc/tools/deps.sh $(wildcard hxc/tools/cosmo-patches/*)
	sh hxc/tools/deps.sh $* bin/deps/$*
	touch $@

# zig cc: glibc 2.28 for Linux (not musl: no ucontext, which rt_run_main uses
# for its 1 GB stack); macOS needs no SDK (deps.sh, rt_ssl.c load the
# frameworks they use at run time). Stripped.
ZIG_FLAGS = $(CFLAGS_BASE) -DHXC_CONST_IDS -Ibin/deps/$(TARGET)/include
release: $(RELEASE_BIN)
bin/release/%/haxe-in-haxe: $(PORT_C)/files.txt bin/deps/%/VERSIONS $(RT_SRC)
	@mkdir -p $(dir $@)
	$(call cc,$(ZIG) cc -target $* -O2,$(ZIG_FLAGS),-Lbin/deps/$*/lib $(DEPS_LIBS) -lm -lpthread -ldl,$(PORT_C),$@,LDFLAGS="$(CFLAGS_BASE) -s" RT_FILES="$(RT_FILES)")
	ls -l $@

# Windows (x86_64-windows-gnu, aarch64-windows-gnu: MinGW-w64 and the UCRT):
# the runtime's Windows host layer (hxc/rt/rt_win.h), the system libraries
# of libuv, mbedtls and the runtime; stripped, without the PDB zig writes
WIN_LIBS := -lws2_32 -liphlpapi -luserenv -lpsapi -ldbghelp -lole32 -lshell32 -luser32 -ladvapi32 -lcrypt32 -lbcrypt
WIN_LDFLAGS := $(CFLAGS_BASE) -s
bin/release/%/haxe-in-haxe.exe: $(PORT_C)/files.txt bin/deps/%/VERSIONS $(RT_SRC)
	@mkdir -p $(dir $@)
	$(call cc,$(ZIG) cc -target $* -O2,$(ZIG_FLAGS),-Lbin/deps/$*/lib $(DEPS_LIBS) $(WIN_LIBS),$(PORT_C),$@,LDFLAGS="$(WIN_LDFLAGS)" RT_FILES="$(RT_FILES)")
	rm -f $(@:.exe=.pdb)
	ls -l $@

# cosmocc: `-L<dir>` in one argument (cosmocc maps it to <dir>/.aarch64 for the aarch64 half)
COSMO_PATH = $(if $(COSMOCC),PATH="$(COSMOCC)/bin:$$PATH")
cosmo: bin/release/cosmo/haxe-in-haxe.com
bin/release/cosmo/haxe-in-haxe.com: $(PORT_C)/files.txt bin/deps/cosmo/VERSIONS $(RT_SRC)
	@mkdir -p $(dir $@)
	$(call cc,cosmocc -O2,$(CFLAGS_BASE) -DHXC_CONST_IDS -Ibin/deps/cosmo/include,-lm -Lbin/deps/cosmo/lib $(DEPS_LIBS),$(PORT_C),$@,$(COSMO_PATH) RT_FILES="$(RT_FILES)")
	ls -l $@

smoke:
	SMOKE_STRICT=$(SMOKE_STRICT) sh hxc/tools/smoke.sh $(SMOKE_BIN)

# --- The website ---

# The playground's WebAssembly, compiled as C++ so RT_TRY is a native
# try/catch (wasm exception handling): Emscripten's setjmp lowering multiplies
# the code of functions with many try blocks past V8's 7.6 MB function size
# limit. wasm64: the runtime lays objects out in 8-byte slots holding 64-bit
# pointers. The runtime's sockets, mbedtls and libuv are stubs that throw.
# The std subset the compiler needs for --interp, macros and HXB is preloaded.
WASM_FLAGS := -O2 $(CFLAGS_BASE) -fwasm-exceptions -sMEMORY64=1 -I hxc/rt
WASM_LDFLAGS := $(WASM_FLAGS) -sMODULARIZE=1 -sEXPORT_NAME=createHih -sENVIRONMENT=web,worker,node \
	-sEXIT_RUNTIME=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -sMAXIMUM_MEMORY=8GB -sSTACK_SIZE=8MB \
	-sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=callMain,FS,ENV \
	--preload-file bin/site-build/std@/lib/haxe/std
wasm: bin/site/hih.js
bin/site/hih.js: $(WEB_C)/files.txt $(RT_SRC)
	@mkdir -p bin/site
	rm -rf bin/site-build/std && mkdir -p bin/site-build/std
	cp $(HAXE_STD_PATH)/*.hx bin/site-build/std/
	cp -r $(HAXE_STD_PATH)/haxe $(HAXE_STD_PATH)/sys $(HAXE_STD_PATH)/eval bin/site-build/std/
	$(call cc,em++,-x c++ $(WASM_FLAGS) -DHXC_CONST_IDS -DHXC_NO_NET $(NO_TLS_UV),,$(WEB_C),$@,LDFLAGS="$(WASM_LDFLAGS)" RT_FILES="$(RT_FILES)")

# the pages, their scripts (site/src, site/build.hxml), the benchmark results
# (site/bench/README.md) and the build facts
mb = awk '{printf "%.1f MB", $$1 / 1048576}'
site: wasm
	cp site/index.html site/story.html site/style.css bin/site/
	$(SITE_HAXE) site/build.hxml
	cp site/bench/results.json bin/site/bench.json
	cp site/bench/targets-results.json bin/site/targets.json
	rm -rf bin/site/examples && cp -r site/examples bin/site/examples
	if [ -n "$(LIX_COM)" ]; then mkdir -p bin/site/tools && cp $(LIX_COM) bin/site/tools/lix.com; fi
	printf '{\n\t"date": "%s",\n\t"commit": "%s",\n\t"wasmSize": "%s",\n\t"wasmGz": "%s",\n\t"dataGz": "%s",\n\t"lixSize": "%s"\n}\n' \
		"$$(date -u +%Y-%m-%d)" "$$(git rev-parse --short HEAD)" \
		"$$(stat -c %s bin/site/hih.wasm | $(mb))" \
		"$$(gzip -9c bin/site/hih.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/hih.data | wc -c | $(mb))" \
		"$$(if [ -f bin/site/tools/lix.com ]; then stat -c %s bin/site/tools/lix.com | $(mb); else echo -; fi)" > bin/site/build-info.json
	cat bin/site/build-info.json

# --- Other programs ---

# the fuzzer: clang's OS threads let -j N run workers in parallel (with tcc
# the green threads serialize them)
fuzz: bin/fuzz/fuzz
bin/fuzz/fuzz: $(WBK) $(FUZZ_SRC) $(STD) $(RT_SRC)
	$(call wbk,bin/hxc/Fuzz/prog,-cp test/fuzz -main Fuzz)
	@mkdir -p bin/fuzz
	$(call cc,$(FUZZ_CC),$(CFLAGS_BASE) $(NO_TLS_UV) -DHXC_CONST_IDS,-lm,bin/hxc/Fuzz/prog_hxc,$@)

# any program (e.g. make program CP=hxc/test/threads MAIN=Threads); always regenerated
program: $(WBK) $(STD)
	$(call wbk,bin/hxc/$(MAIN)/prog,-cp $(CP) -main $(MAIN) $(HXFLAGS))
	$(call cc,$(PROG_CC),$(CFLAGS_BASE) $(NO_TLS_UV) $(if $(filter tcc%,$(PROG_CC)),,-DHXC_CONST_IDS),-lm,bin/hxc/$(MAIN)/prog_hxc,bin/hxc/$(MAIN)/prog_c)

haxelib:
	sh hxc/haxelib/build.sh

# --- lix (tools/lix/README.md) ---

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
bin/lix/gen/shim/CaBundle.hx: tools/lix/cabundle.py
	@mkdir -p bin/lix
	curl -sSfL --retry 3 -o bin/lix/$(CACERT) https://curl.se/ca/$(CACERT)
	python3 tools/lix/cabundle.py bin/lix/$(CACERT) $(CACERT_SHA256) bin/lix/gen

LIX_ARGS := -cp tools/lix/src -cp bin/lix/gen -cp $(HXCORO)/src -main lix.cli.Main -D no-deprecation-warnings
lix-c: bin/lix/lix_hxc/files.txt
bin/lix/lix_hxc/files.txt: $(WBK) $(LIX_SRC) $(STD) $(HXCORO)/.rev bin/lix/gen/shim/CaBundle.hx
	$(call wbk,bin/lix/lix,$(LIX_ARGS))

ifeq ($(LIX_TLS_UV),system)
LIX_INC :=
LIX_LIBS := -lm $(DEPS_LIBS)
else
LIX_INC := -I$(LIX_TLS_UV)/include
LIX_LIBS := -lm -L$(LIX_TLS_UV)/lib $(DEPS_LIBS) -lpthread -ldl
endif
lix: bin/lix/lix
bin/lix/lix: $(LIX_C)/files.txt $(RT_SRC)
	$(call cc,$(LIX_CC),$(CFLAGS_BASE) -DHXC_CONST_IDS $(LIX_INC),$(LIX_LIBS),$(LIX_C),$@)
	for cmd in haxe haxelib neko; do ln -sf lix bin/lix/$$cmd; done
	ls -l $@

lix-cosmo: bin/release/cosmo/lix.com
bin/release/cosmo/lix.com: $(LIX_C)/files.txt bin/deps/cosmo/VERSIONS $(RT_SRC)
	@mkdir -p $(dir $@)
	$(call cc,cosmocc -O2,$(CFLAGS_BASE) -DHXC_CONST_IDS -Ibin/deps/cosmo/include,-lm -Lbin/deps/cosmo/lib $(DEPS_LIBS),$(LIX_C),$@,$(COSMO_PATH) RT_FILES="$(RT_FILES)")
	ls -l $@

# --- Tests (test/README.md has the other harnesses) ---

test: $(PORT_BIN)
	HAXE_REFERENCE=$(CURDIR)/haxe/haxe HAXE_IN_HAXE_PORT=$(abspath $(PORT_BIN)) \
		python3 test/conformance.py -j $(JOBS)

test-fuzz: bin/fuzz/fuzz $(PORT_BIN)
	HAXE_REFERENCE=$(CURDIR)/haxe/haxe bin/fuzz/fuzz -j $(JOBS) -n $(N) --port $(abspath $(PORT_BIN)) --lane $(LANE)

clean:
	rm -rf bin/hxc bin/port bin/release bin/site bin/site-build bin/fuzz bin/haxelib bin/lix

distclean:
	rm -rf bin
