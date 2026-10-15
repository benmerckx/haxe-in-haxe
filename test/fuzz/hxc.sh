#!/bin/sh
# The hxc target of the fuzzer: compiles a program to C with the hxc tool
# (bin/hxc/wbk.js, the port plus hxc/, built by `make tool`) and
# the C to <out>/prog with HXC_CC (default tcc).
#   sh test/fuzz/hxc.sh <out dir> <haxe arguments ...>
set -eu
OUT=$1
shift
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CC=${HXC_CC:-tcc}
# the runtime is compiled once per compiler
RT=$ROOT/bin/fuzz/rt-$(echo "$CC" | tr -c 'A-Za-z0-9\n' '_')
FLAGS="-w -fno-strict-aliasing -DHXC_NO_SSL -DHXC_NO_UV -I $ROOT/hxc/rt"
if [ ! -f "$RT/done" ]; then
	mkdir -p "$RT"
	for f in "$ROOT"/hxc/rt/rt*.c; do
		$CC $FLAGS -c "$f" -o "$RT/$(basename "$f" .c).o"
	done
	touch "$RT/done"
fi
# the hxc target's std, as the Makefile makes it
[ -d "$ROOT/bin/hxc/std" ] || (cd "$ROOT" && python3 hxc/tools/mkstd.py)
HXC_SINGLE=1 HAXE_STD_PATH=${HAXE_STD_PATH:-$ROOT/haxe/std} node --stack-size=65500 "$ROOT/bin/hxc/wbk.js" "$OUT/prog" "$@" \
	-cp "$ROOT/bin/hxc/std" --custom-target hxc
$CC $FLAGS "$OUT/prog.c" "$RT"/rt*.o -lm -lpthread -o "$OUT/prog"
