#!/bin/sh
# Builds the runtime object of an hxmc target (hxmc/README.md, "Runtime"):
# hxmc/rt compiled by zig cc -O2 for the target, partially linked (ld -r) with
# the parts of the C library it and generated code use, into one relocatable
# object bin/hxmc/rt/<target>/rt.o, which hxmc's linker then links with the
# program (and lays out once, see Link.hx).
#   sh hxmc/tools/mkrt.sh linux-x86_64
set -eu
target=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ZIG=${ZIG:-zig}
case $target in
linux-x86_64) triple=x86_64-linux-musl ;;
linux-arm64) triple=aarch64-linux-musl ;;
windows-x86_64) triple=x86_64-windows-gnu ;;
windows-arm64) triple=aarch64-windows-gnu ;;
macos-x86_64) triple=x86_64-macos ;;
macos-arm64) triple=aarch64-macos ;;
*) echo "mkrt: unknown target $target" >&2; exit 1 ;;
esac
out=$ROOT/bin/hxmc/rt/$target
mkdir -p "$out/obj"
CFLAGS="-O2 -g0 -w -fno-strict-aliasing -fno-pie -fno-pic -ffunction-sections -fdata-sections -DHXMC_NO_SSL -DHXMC_NO_UV -DRT_CALL_ON_STACK -I $ROOT/hxmc/rt"
files="rt rt_dyn rt_str rt_ssl rt_uv rt_thread rt_census rt_frames"
case $target in
windows-*)
	CFLAGS="-O2 -g0 -w -fno-strict-aliasing -DHXMC_NO_SSL -DHXMC_NO_UV -I $ROOT/hxmc/rt"
	files="$files rt_win" ;;
macos-*)
	# position-independent (macOS executables are), against libSystem;
	# arm64 macOS calls main on its own stack without ucontext already
	CFLAGS="-O2 -g0 -w -fno-strict-aliasing -mmacosx-version-min=$([ $target = macos-arm64 ] && echo 11.0 || echo 10.15) -DHXMC_NO_SSL -DHXMC_NO_UV -I $ROOT/hxmc/rt" ;;
esac
objs=
for f in $files; do
	$ZIG cc -target $triple $CFLAGS -c "$ROOT/hxmc/rt/$f.c" -o "$out/obj/$f.o" &
	objs="$objs $out/obj/$f.o"
done
# the slow paths of generated code (rthxmc.c)
$ZIG cc -target $triple $CFLAGS -c "$ROOT/hxmc/rt/rthxmc.c" -o "$out/obj/rthxmc.o" &
objs="$objs $out/obj/rthxmc.o"
wait
# what generated code calls in the C library besides the runtime (MirBuild),
# and what the runtime's Haxe code calls (hxmc/std/hxmc/unsafe/LibC.hx)
libm="memset memcpy fmod floor ceil sin cos tan asin acos atan atan2 exp log pow sqrt"
libm="$libm memmove memcmp strlen strcmp malloc free strtod rand clock_gettime mktime"
case $target in
windows-*)
	libm="$libm _mktime64 _localtime64_s _gmtime64_s"
	# hxmc/std/hxmc/unsafe/Win32.hx (the UCRT's part; kernel32's are imports)
	libm="$libm _write _read _close _wopen _lseeki64 _telli64 _fstat64 _wstat64 _wgetenv _wputenv_s _wgetcwd _wchdir"
	libm="$libm _wsystem _wmkdir _wunlink _wrmdir _getch _getche _errno _open_osfhandle _get_osfhandle fflush exit realloc"
	libm="$libm GetEnvironmentStringsW FreeEnvironmentStringsW Sleep GetSystemTimePreciseAsFileTime GetProcessTimes"
	libm="$libm GetCurrentProcess GetModuleFileNameW GetStdHandle GetFileType GetFileAttributesW SetFileAttributesW MoveFileExW"
	libm="$libm RemoveDirectoryW FindFirstFileW FindNextFileW FindClose GetLastError GetFullPathNameW DuplicateHandle CloseHandle"
	libm="$libm SearchPathW CreateFileW CreatePipe CreateProcessW WaitForSingleObject GetExitCodeProcess TerminateProcess"
	# hxmc/std/hxmc/unsafe/Winsock.hx
	libm="$libm socket closesocket accept bind connect listen getsockname getpeername getsockopt setsockopt recv send"
	libm="$libm select shutdown ioctlsocket gethostname gethostbyname gethostbyaddr WSAGetLastError SetHandleInformation"
	libm="$libm strerror _strdup rt_win_sock_errno rt_win_sockets_init" ;;
*)
	libm="$libm localtime_r gmtime_r"
	# hxmc/std/hxmc/unsafe/Posix.hx
	libm="$libm write read open close lseek fcntl pipe dup2 isatty tcgetattr tcsetattr getenv setenv unsetenv getcwd chdir"
	libm="$libm nanosleep gettimeofday clock readlink realpath system fork execvp _exit exit fflush waitpid kill mkdir"
	libm="$libm unlink rmdir rename stat fstat opendir readdir closedir realloc environ"
	libm="$libm socket bind connect accept listen getsockname getpeername getsockopt setsockopt recv send select"
	libm="$libm shutdown signal strerror gethostname gethostbyname gethostbyaddr strdup sched_yield"
	case $target in linux-*) libm="$libm __errno_location" ;; esac ;;
esac
case $target in
macos-*)
	# the runtime's Mach-O objects merged into one (hxmc --mkrt-macho); the
	# C library is libSystem, bound at load time
	"${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt-macho "$out/rt.o" $objs
	ls -l "$out/rt.o"
	exit 0 ;;
windows-*)
	# the runtime's own COFF objects, the C runtime's startup object and the
	# archives zig links (the MinGW-w64 libraries, compiler-rt, the import
	# libraries of the UCRT and the Windows DLLs the runtime uses), selected
	# and resolved by hxmc itself (hxmc --mkrt)
	printf 'int main(void){return 0;}\n' > "$out/obj/stub.c"
	WINLIBS="-lws2_32 -liphlpapi -luserenv -lpsapi -ldbghelp -lole32 -lshell32 -luser32 -ladvapi32 -lcrypt32 -lbcrypt"
	$ZIG cc -target $triple -O2 "$out/obj/stub.c" -o "$out/obj/stub.exe" $WINLIBS
	line=$($ZIG cc -target $triple -O2 -v "$out/obj/stub.c" -o "$out/obj/stub.exe" $WINLIBS 2>&1 | grep 'lld-link' | head -1)
	inputs=$(echo "$line" | tr ' ' '\n' | grep -E '\.(obj|lib)$' | grep -v '^-' | grep -v '/stub.obj$' | tr '\n' ' ')
	sj=_setjmp; [ $target = windows-arm64 ] && sj=__mingw_setjmp
	undef="-u mainCRTStartup -u $sj -u _tls_index -u _tls_used -x main"
	for f in $libm; do undef="$undef -u $f"; done
	"${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt "$out/rt.o" $objs $inputs $undef
	ls -l "$out/rt.o"
	exit 0 ;;
esac
# the C library: zig builds it on first use; a static link of a stub tells where
printf 'int main(void){return 0;}\n' > "$out/obj/stub.c"
# (twice: the first run may build the C library and name temporary paths)
$ZIG cc -target $triple -static -O2 "$out/obj/stub.c" -o "$out/obj/stub"
line=$($ZIG cc -target $triple -static -O2 -v "$out/obj/stub.c" -o "$out/obj/stub" 2>&1 | grep 'ld.lld' | head -1)
crt1=$(echo "$line" | tr ' ' '\n' | grep '/crt1.o$')
libs=$(echo "$line" | tr ' ' '\n' | grep -E '/lib(c|zigc|compiler_rt)\.a$' | tr '\n' ' ')
undef="-u _setjmp"
for f in $libm; do undef="$undef -u $f"; done
# word-at-a-time memcmp and bcmp in place of musl's byte loops (rtlibc.c)
$ZIG cc -target $triple -O2 -g0 -ffreestanding -fno-builtin -ffunction-sections -c "$ROOT/hxmc/rt/rtlibc.c" -o "$out/obj/rtlibc.o"
objs="$objs $out/obj/rtlibc.o"
ld.lld -r --strip-debug -o "$out/rt.o" $undef "$crt1" $objs --start-group $libs --end-group
ls -l "$out/rt.o"
