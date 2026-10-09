#!/bin/sh
# Formats the port's Haxe sources with haxe-formatter built by hxc (the C
# backend, backend/haxelib), using ./hxformat.json.
#
#   sh tools/format-src.sh                 format src/ in place
#   sh tools/format-src.sh --check         list the files that would change (exit 1 if any)
#   sh tools/format-src.sh --build         only (re)build the formatter
#   sh tools/format-src.sh src/typing      format other paths (files or directories)
#
# FORMATTER=<binary> uses an existing formatter build (any target: e.g.
# `node run.js` works too, the output is the same). Otherwise the formatter is
# built once into bin/formatter/hxformat:
#   - haxe-formatter and its dependencies at the pinned revisions below, in
#     test/generated/formatter (a local haxelib repository, .haxelib/);
#   - the hxc haxelib package (bin/haxelib/hxc, backend/haxelib/build.sh; with
#     NATIVE_CC=clang when cosmocc is not on PATH);
#   - `haxe/haxe ... -lib hxc --custom-target hxc=bin/formatter/hxformat`
#     (HXB is version-coupled: the pinned compiler haxe/haxe types the program).
# Needs git, curl, haxelib, node (backend/haxelib/build.sh) and clang (HXC_CC
# overrides the C compiler).
#
# Not formatted: backend/src (hand-written) and everything outside src/ unless
# named. EXCLUDE (an extended regular expression on the path, default below)
# leaves files untouched; hxformat.json "excludes" works too.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
HAXE=$ROOT/haxe/haxe
OUT=$ROOT/bin/formatter/hxformat
F=$ROOT/test/generated/formatter
L=$ROOT/test/generated/formatter-libs
# EvalBytesUnicase.hx: Unicode case tables (array literals) whose wrapping never
# reaches a fixed point (alternates between two layouts on every pass)
EXCLUDE=${EXCLUDE:-'src/macros/eval/EvalBytesUnicase\.hx$'}

# haxe-formatter 1.18.0+ (master, 2025-12-28) and the revisions of its
# haxe_libraries/*.hxml (lix pins)
FORMATTER_REV=a8f7f3284d2dd2ef974c34d8c3243559c2209d88
GIT_LIBS="
haxeparser https://github.com/HaxeCheckstyle/haxeparser a5fce2ecf5fb3bdfebfd7efd8b05329d456ec0d2
hxparse https://github.com/simn/hxparse 876070ec62a4869de60081f87763e23457a3bda8
hxargs https://github.com/simn/hxargs 1d8ec84f641833edd6f0cb2e4290b7524fd27219
json2object https://github.com/elnabo/json2object a75859de1e966c09e73591b6c9186086c143fe60
"
ZIP_LIBS="hxjsonast-1.1.0 tokentree-1.2.18"

clone() { # dir url rev
	if [ ! -d "$1/.git" ]; then
		git clone -q "$2" "$1"
	fi
	git -C "$1" checkout -q "$3"
}

build() {
	mkdir -p "$L" "$(dirname "$OUT")"
	clone "$F" https://github.com/haxecheckstyle/haxe-formatter "$FORMATTER_REV"
	echo "$GIT_LIBS" | while read -r name url rev; do
		if [ -n "$name" ]; then clone "$L/$name" "$url" "$rev"; fi
	done
	(
		cd "$F"
		[ -d .haxelib ] || haxelib newrepo > /dev/null
		echo "$GIT_LIBS" | while read -r name url rev; do
			if [ -n "$name" ]; then haxelib dev "$name" "$L/$name" > /dev/null; fi
		done
		for lib in $ZIP_LIBS; do
			zip=$L/$lib.zip
			# lib.haxe.org's file store (haxelib install can fail behind proxies)
			if [ ! -f "$zip" ]; then curl -sSLf -o "$zip" "https://haxelib-files.haxe.org/files/3.0/$(echo "$lib" | tr . ,).zip"; fi
			haxelib install "$zip" --always > /dev/null
		done
	)
	if [ ! -f "$ROOT/bin/haxelib/hxc/bin/hxc.com" ]; then
		if command -v cosmocc > /dev/null; then
			sh backend/haxelib/build.sh
		else
			NATIVE_CC=${NATIVE_CC:-clang} sh backend/haxelib/build.sh
		fi
	fi
	(
		cd "$F"
		haxelib dev hxc "$ROOT/bin/haxelib/hxc" > /dev/null
		"$HAXE" buildCommon.hxml -w -WIfDisplay -lib hxc -main formatter.Cli \
			--custom-target "hxc=$OUT" -D hxc.cc="${HXC_CC:-clang}"
	)
	ls -l "$OUT"
}

MODE=format
case "${1:-}" in
--build)
	build
	exit 0
	;;
--check)
	MODE=check
	shift
	;;
esac
if [ -z "${FORMATTER:-}" ]; then
	[ -x "$OUT" ] || build
	FORMATTER=$OUT
fi
[ $# -gt 0 ] || set -- src

# the formatter finds ./hxformat.json by walking up from each file; files are
# passed one -s each so that EXCLUDE can apply
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
find "$@" -name '*.hx' -type f | grep -Ev "$EXCLUDE" | sort > "$LIST"
set --
while read -r f; do
	set -- "$@" -s "$f"
done < "$LIST"
if [ "$MODE" = check ]; then
	exec $FORMATTER --check "$@"
fi
# one pass is not always a fixed point (wrapping decisions see the previous
# pass's line breaks): repeat until --check passes, at most 4 passes
pass=1
while :; do
	$FORMATTER "$@" | grep -v '^Formatted\|^---\|^Input\|^Output\|^$' || true
	if $FORMATTER --check "$@" > /dev/null; then
		echo "format-src: $(wc -l < "$LIST") files formatted, stable after $pass pass(es)"
		break
	fi
	pass=$((pass + 1))
	if [ $pass -gt 4 ]; then
		$FORMATTER --check "$@" | grep '^Incorrect' >&2 || true
		echo "format-src: not stable after 4 passes (files above): exclude them with EXCLUDE" >&2
		exit 1
	fi
done
