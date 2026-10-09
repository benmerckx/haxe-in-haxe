// EXPERIMENTAL runtime for the C output of backend/: libuv behind
// hxc.NativeUv (backend/std-hxc/hxc/NativeUv.hx), standing for the OCaml luv
// library that haxe/src/macro/eval/evalLuv.ml calls (src/macros/eval/EvalLuv.hx).
//
// Loops, handles, requests and directories are integer ids into a table of
// C objects. libuv invokes its callbacks from uv_run only, so loopRun keeps
// the port's dispatcher closure on the shadow stack for its duration and the
// C callbacks report events to it: dispatch(id, event, int, value). Buffers
// stay in the GC heap on the Haxe side: data is copied into C memory for
// writes and copied out of C memory after reads. Socket addresses are Bytes
// holding a struct sockaddr_storage. Nothing is finalized: requests are freed
// when the port releases them, handles when their close completes.
//
// -DHXC_NO_UV builds stubs that fail (builds without libuv).
#define _GNU_SOURCE
#include "rt.h"
#include <stdlib.h>

#define BYTES_LEN(b) (((int32_t *)(b))[0])
#define BYTES_DATA(b) ((unsigned char *)(b) + 8)
void *haxe_io_Bytes_alloc(int32_t len);

#ifdef HXC_NO_UV

static int32_t no_uv(void) { hx_throw_str("libuv (eval.luv) is not supported in this build of haxe-in-haxe"); }
int32_t hxc_NativeUv_available(void) { return 0; }
int32_t hxc_NativeUv_lastError(void) { return no_uv(); }
int32_t hxc_NativeUv_i64Hi(void) { return no_uv(); }
int32_t hxc_NativeUv_i64Lo(void) { return no_uv(); }
int32_t hxc_NativeUv_errIndex(int32_t code) { return no_uv(); }
int32_t hxc_NativeUv_errCode(int32_t index) { return no_uv(); }
void *hxc_NativeUv_strerror(int32_t code) { no_uv(); return NULL; }
void *hxc_NativeUv_errName(int32_t code) { no_uv(); return NULL; }
int32_t hxc_NativeUv_translateSysError(int32_t e) { return no_uv(); }
int32_t hxc_NativeUv_constant(int32_t group, int32_t index) { return 0; } // evaluated while EvalLuv's field lists are built
void *hxc_NativeUv_versionString(void) { return hx_str_of_ascii(""); }
void *hxc_NativeUv_versionSuffix(void) { return hx_str_of_ascii(""); }
int32_t hxc_NativeUv_loopDefault(void) { return no_uv(); }
int32_t hxc_NativeUv_loopInit(void) { return no_uv(); }
int32_t hxc_NativeUv_loopRun(int32_t id, int32_t mode, void *dispatcher) { return no_uv(); }
void hxc_NativeUv_loopStop(int32_t id) { no_uv(); }
int32_t hxc_NativeUv_loopClose(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_loopAlive(int32_t id) { return no_uv(); }
void hxc_NativeUv_loopNow(int32_t id) { no_uv(); }
void hxc_NativeUv_loopUpdateTime(int32_t id) { no_uv(); }
void hxc_NativeUv_libraryShutdown(void) { no_uv(); }
void hxc_NativeUv_metricsIdleTime(int32_t id) { no_uv(); }
int32_t hxc_NativeUv_handleInit(int32_t kind, int32_t loopId, int32_t arg, int32_t arg2) { return no_uv(); }
int32_t hxc_NativeUv_handleClose(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_handleIsActive(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_handleIsClosing(int32_t id) { return no_uv(); }
void hxc_NativeUv_handleRef(int32_t id) { no_uv(); }
void hxc_NativeUv_handleUnref(int32_t id) { no_uv(); }
int32_t hxc_NativeUv_handleHasRef(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_bufferSize(int32_t id, int32_t send, int32_t size) { return no_uv(); }
int32_t hxc_NativeUv_watcherStart(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_watcherStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_timerStart(int32_t id, int32_t timeout, int32_t repeat) { return no_uv(); }
int32_t hxc_NativeUv_timerStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_timerAgain(int32_t id) { return no_uv(); }
void hxc_NativeUv_timerSetRepeat(int32_t id, int32_t repeat) { no_uv(); }
int32_t hxc_NativeUv_timerGetRepeat(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_timerGetDueIn(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_asyncSend(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_signalStart(int32_t id, int32_t signum, int32_t oneshot) { return no_uv(); }
int32_t hxc_NativeUv_signalStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_signalSignum(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_reqNew(void) { return no_uv(); }
void hxc_NativeUv_reqFree(int32_t id) { no_uv(); }
int32_t hxc_NativeUv_reqCancel(int32_t id) { return no_uv(); }
void hxc_NativeUv_reqCopyOut(int32_t id, void *b, int32_t pos, int32_t src, int32_t len) { no_uv(); }
int32_t hxc_NativeUv_sockaddrSize(void) { return no_uv(); }
int32_t hxc_NativeUv_sockaddrIp(void *host, int32_t port, int32_t v6, void *out) { return no_uv(); }
int32_t hxc_NativeUv_sockaddrPort(void *sa) { return no_uv(); }
void *hxc_NativeUv_sockaddrToString(void *sa) { no_uv(); return NULL; }
int32_t hxc_NativeUv_tcpNoDelay(int32_t id, int32_t b) { return no_uv(); }
int32_t hxc_NativeUv_tcpKeepAlive(int32_t id, int32_t enable, int32_t delay) { return no_uv(); }
int32_t hxc_NativeUv_tcpSimultaneousAccepts(int32_t id, int32_t b) { return no_uv(); }
int32_t hxc_NativeUv_tcpBind(int32_t id, void *sa, int32_t ipv6only) { return no_uv(); }
int32_t hxc_NativeUv_sockName(int32_t id, int32_t peer, void *out) { return no_uv(); }
int32_t hxc_NativeUv_tcpConnect(int32_t id, void *sa, int32_t rid) { return no_uv(); }
int32_t hxc_NativeUv_tcpCloseReset(int32_t id, int32_t rid) { return no_uv(); }
void hxc_NativeUv_allocSize(int32_t n) { no_uv(); }
int32_t hxc_NativeUv_streamShutdown(int32_t id, int32_t rid) { return no_uv(); }
int32_t hxc_NativeUv_streamListen(int32_t id, int32_t backlog) { return no_uv(); }
int32_t hxc_NativeUv_streamAccept(int32_t server, int32_t client) { return no_uv(); }
int32_t hxc_NativeUv_readStart(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_readStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_streamWrite(int32_t id, int32_t rid, void *data, void *sizes, int32_t sendHandle) { return no_uv(); }
int32_t hxc_NativeUv_streamTryWrite(int32_t id, void *data, void *sizes) { return no_uv(); }
int32_t hxc_NativeUv_streamWriteQueueSize(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_streamIsReadable(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_streamIsWritable(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_streamSetBlocking(int32_t id, int32_t b) { return no_uv(); }
int32_t hxc_NativeUv_pipeBind(int32_t id, void *name) { return no_uv(); }
void hxc_NativeUv_pipeConnect(int32_t id, void *name, int32_t rid) { no_uv(); }
void *hxc_NativeUv_pipeName(int32_t id, int32_t peer) { no_uv(); return NULL; }
void hxc_NativeUv_pipePendingInstances(int32_t id, int32_t n) { no_uv(); }
int32_t hxc_NativeUv_pipePendingType(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_pipeChmod(int32_t id, int32_t mode) { return no_uv(); }
int32_t hxc_NativeUv_ttySetMode(int32_t id, int32_t mode) { return no_uv(); }
int32_t hxc_NativeUv_ttyResetMode(void) { return no_uv(); }
void *hxc_NativeUv_ttyGetWinSize(int32_t id) { no_uv(); return NULL; }
void hxc_NativeUv_ttySetVTermState(int32_t s) { no_uv(); }
int32_t hxc_NativeUv_ttyGetVTermState(void) { return no_uv(); }
int32_t hxc_NativeUv_udpBind(int32_t id, void *sa, int32_t flags) { return no_uv(); }
int32_t hxc_NativeUv_udpConnect(int32_t id, void *sa) { return no_uv(); }
int32_t hxc_NativeUv_udpSetMembership(int32_t id, void *group, void *iface, void *source, int32_t join) { return no_uv(); }
int32_t hxc_NativeUv_udpSetOption(int32_t id, int32_t opt, int32_t v) { return no_uv(); }
int32_t hxc_NativeUv_udpSetMulticastInterface(int32_t id, void *iface) { return no_uv(); }
int32_t hxc_NativeUv_udpSend(int32_t id, int32_t rid, void *data, void *sizes, void *sa) { return no_uv(); }
int32_t hxc_NativeUv_udpTrySend(int32_t id, void *data, void *sizes, void *sa) { return no_uv(); }
int32_t hxc_NativeUv_udpRecvStart(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_udpRecvStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_udpSendQueue(int32_t id, int32_t count) { return no_uv(); }
int32_t hxc_NativeUv_processSpawn(int32_t loopId, void *cmd, void *args, void *env, void *cwd, int32_t flags, int32_t uid, int32_t gid, void *redirect, int32_t onExit) { return no_uv(); }
void hxc_NativeUv_disableStdioInheritance(void) { no_uv(); }
int32_t hxc_NativeUv_killPid(int32_t pid, int32_t sig) { return no_uv(); }
int32_t hxc_NativeUv_processPid(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_getAddrInfo(int32_t loopId, int32_t rid, void *node, void *service, int32_t family, int32_t socktype, int32_t protocol, int32_t flags, int32_t hasHints) { return no_uv(); }
void *hxc_NativeUv_addrInfoResult(int32_t rid) { no_uv(); return NULL; }
int32_t hxc_NativeUv_getNameInfo(int32_t loopId, int32_t rid, void *sa, int32_t flags) { return no_uv(); }
void *hxc_NativeUv_nameInfoResult(int32_t rid) { no_uv(); return NULL; }
int32_t hxc_NativeUv_fs(int32_t op, int32_t loopId, int32_t rid, void *p1, void *p2, int32_t i1, int32_t i2, int32_t i3, double f1, double f2, void *data, void *sizes) { return no_uv(); }
int32_t hxc_NativeUv_fsResult(int32_t rid) { return no_uv(); }
void hxc_NativeUv_fsCleanup(int32_t rid) { no_uv(); }
void *hxc_NativeUv_fsPath(int32_t rid) { no_uv(); return NULL; }
void *hxc_NativeUv_fsPtrString(int32_t rid) { no_uv(); return NULL; }
void hxc_NativeUv_fsStat(int32_t rid, void *out) { no_uv(); }
void hxc_NativeUv_fsStatfs(int32_t rid, void *out) { no_uv(); }
int32_t hxc_NativeUv_fsDir(int32_t rid) { return no_uv(); }
void *hxc_NativeUv_fsDirents(int32_t rid) { no_uv(); return NULL; }
void *hxc_NativeUv_fsScandirNext(int32_t rid) { no_uv(); return NULL; }
int32_t hxc_NativeUv_fsEventStart(int32_t id, void *path, int32_t flags) { return no_uv(); }
int32_t hxc_NativeUv_fsEventStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_fsPollStart(int32_t id, void *path, int32_t interval) { return no_uv(); }
int32_t hxc_NativeUv_fsPollStop(int32_t id) { return no_uv(); }
int32_t hxc_NativeUv_random(int32_t loopId, int32_t rid, int32_t len) { return no_uv(); }
void *hxc_NativeUv_getEnv(void *name) { no_uv(); return NULL; }
int32_t hxc_NativeUv_setEnv(void *name, void *value) { return no_uv(); }
void *hxc_NativeUv_environ(void) { no_uv(); return NULL; }
int32_t hxc_NativeUv_getTimeOfDay(void) { return no_uv(); }
void hxc_NativeUv_hrTime(void) { no_uv(); }
void hxc_NativeUv_sleep(int32_t ms) { no_uv(); }
void *hxc_NativeUv_path(int32_t which) { no_uv(); return NULL; }
int32_t hxc_NativeUv_chdir(void *dir) { return no_uv(); }
void *hxc_NativeUv_interfaceAddresses(void) { no_uv(); return NULL; }
void *hxc_NativeUv_netName(int32_t which, int32_t index) { no_uv(); return NULL; }
double hxc_NativeUv_uptime(void) { no_uv(); return 0; }
void *hxc_NativeUv_loadAvg(void) { no_uv(); return NULL; }
void hxc_NativeUv_memory(int32_t which) { no_uv(); }
int32_t hxc_NativeUv_getPriority(int32_t pid) { return no_uv(); }
int32_t hxc_NativeUv_setPriority(int32_t pid, int32_t p) { return no_uv(); }
int32_t hxc_NativeUv_getRUsage(void *out) { return no_uv(); }
void *hxc_NativeUv_cpuInfo(void) { no_uv(); return NULL; }
void *hxc_NativeUv_uname(void) { no_uv(); return NULL; }
int32_t hxc_NativeUv_getPid(void) { return no_uv(); }
int32_t hxc_NativeUv_getPPid(void) { return no_uv(); }
void *hxc_NativeUv_getPasswd(void) { no_uv(); return NULL; }

#else

#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <uv.h>

int32_t hxc_NativeUv_available(void) { return 1; }

// ---- object table (id 0 is unused)

// Threads: chunks that never move, so lookups need no lock (adding one does);
// results passed back through globals are per thread.
#define OBJ_CHUNK 1024
static void **obj_chunks[65536];
static int32_t nobjs = 1;
static rt_lock_t objs_lock = RT_LOCK_INIT;
#define OBJ(id) obj_chunks[(id) / OBJ_CHUNK][(id) % OBJ_CHUNK]
static RT_TLS int32_t last_err;
static RT_TLS int64_t i64_out;

static int32_t obj_add(void *p) {
	rt_lock(&objs_lock);
	int32_t id = nobjs;
	if (id / OBJ_CHUNK >= 65536) {
		rt_unlock(&objs_lock);
		hx_throw_str("eval.luv: too many handles");
	}
	if (!obj_chunks[id / OBJ_CHUNK]) obj_chunks[id / OBJ_CHUNK] = calloc(OBJ_CHUNK, sizeof(void *));
	OBJ(id) = p;
#if RT_MT
	__atomic_store_n(&nobjs, id + 1, __ATOMIC_RELEASE);
#else
	nobjs = id + 1;
#endif
	rt_unlock(&objs_lock);
	return id;
}

static void *obj_get(int32_t id) {
#if RT_MT
	int32_t n = __atomic_load_n(&nobjs, __ATOMIC_ACQUIRE);
#else
	int32_t n = nobjs;
#endif
	if (id <= 0 || id >= n || !OBJ(id)) hx_throw_str("eval.luv: invalid or closed handle");
	return OBJ(id);
}

int32_t hxc_NativeUv_lastError(void) { return last_err; }
int32_t hxc_NativeUv_i64Hi(void) { return (int32_t)(i64_out >> 32); }
int32_t hxc_NativeUv_i64Lo(void) { return (int32_t)(uint32_t)i64_out; }

static char *bytes_z(void *b) {
	if (!b) return NULL;
	int32_t n = BYTES_LEN(b);
	char *p = malloc((size_t)n + 1);
	memcpy(p, BYTES_DATA(b), (size_t)n);
	p[n] = 0;
	return p;
}

static void *bytes_of(const void *p, size_t n) {
	void *b = haxe_io_Bytes_alloc((int32_t)n);
	if (n) memcpy(BYTES_DATA(b), p, n);
	return b;
}

static void *bytes_of_c(const char *s) { return s ? bytes_of(s, strlen(s)) : NULL; }
static void *str_of_c(const char *s) { return hx_str_of_utf8(s, (int32_t)strlen(s)); }

// an Array<Dynamic> of n elements, filled by set_elem (rooted by the caller)
static void set_elem(void **arr_root, int32_t i, void *v) {
	void *a = *arr_root;
	rt_set_ptr(ARR_DATA(a), &FP(ARR_DATA(a), i), v);
}

// ---- errors: luv's Error.t, in evalLuv.ml's encode_uv_error order

static const int err_table[82] = {
	UV_E2BIG, UV_EACCES, UV_EADDRINUSE, UV_EADDRNOTAVAIL, UV_EAFNOSUPPORT, UV_EAGAIN, UV_EAI_ADDRFAMILY, UV_EAI_AGAIN, UV_EAI_BADFLAGS,
	UV_EAI_BADHINTS, UV_EAI_CANCELED, UV_EAI_FAIL, UV_EAI_FAMILY, UV_EAI_MEMORY, UV_EAI_NODATA, UV_EAI_NONAME, UV_EAI_OVERFLOW,
	UV_EAI_PROTOCOL, UV_EAI_SERVICE, UV_EAI_SOCKTYPE, UV_EALREADY, UV_EBADF, UV_EBUSY, UV_ECANCELED, 0 /* ECHARSET */, UV_ECONNABORTED,
	UV_ECONNREFUSED, UV_ECONNRESET, UV_EDESTADDRREQ, UV_EEXIST, UV_EFAULT, UV_EFBIG, UV_EHOSTUNREACH, UV_EINTR, UV_EINVAL, UV_EIO,
	UV_EISCONN, UV_EISDIR, UV_ELOOP, UV_EMFILE, UV_EMSGSIZE, UV_ENAMETOOLONG, UV_ENETDOWN, UV_ENETUNREACH, UV_ENFILE, UV_ENOBUFS,
	UV_ENODEV, UV_ENOENT, UV_ENOMEM, UV_ENONET, UV_ENOPROTOOPT, UV_ENOSPC, UV_ENOSYS, UV_ENOTCONN, UV_ENOTDIR, UV_ENOTEMPTY,
	UV_ENOTSOCK, UV_ENOTSUP, UV_EPERM, UV_EPIPE, UV_EPROTO, UV_EPROTONOSUPPORT, UV_EPROTOTYPE, UV_ERANGE, UV_EROFS, UV_ESHUTDOWN,
	UV_ESPIPE, UV_ESRCH, UV_ETIMEDOUT, UV_ETXTBSY, UV_EXDEV, UV_UNKNOWN, UV_EOF, UV_ENXIO, UV_EMLINK, UV_ENOTTY, UV_EFTYPE, UV_EILSEQ,
	UV_EOVERFLOW, UV_ESOCKTNOSUPPORT, UV_ENODATA, UV_EUNATCH};

// Error.from_c: unknown codes are `UNKNOWN (71)
int32_t hxc_NativeUv_errIndex(int32_t code) {
	for (int i = 0; i < 82; i++)
		if (i != 24 && err_table[i] == code) return i;
	return 71;
}

int32_t hxc_NativeUv_errCode(int32_t index) { return index >= 0 && index < 82 ? err_table[index] : UV_UNKNOWN; }

// Error.strerror / err_name: the _r variants into a 256-byte buffer
void *hxc_NativeUv_strerror(int32_t code) {
	char buf[256];
	uv_strerror_r(code, buf, sizeof buf);
	return str_of_c(buf);
}

void *hxc_NativeUv_errName(int32_t code) {
	char buf[256];
	uv_err_name_r(code, buf, sizeof buf);
	return str_of_c(buf);
}

int32_t hxc_NativeUv_translateSysError(int32_t e) { return uv_translate_sys_error(e); }

// constants: group, index -> C value (luv's to_c tables)
int32_t hxc_NativeUv_constant(int32_t group, int32_t index) {
	switch (group) {
	case 0: { // File.Open_flag
		static const int t[] = {O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_EXCL, 0 /* EXLOCK */, O_NOCTTY, O_NOFOLLOW, 0 /* TEMPORARY */,
			O_TRUNC, O_APPEND,
#ifdef O_DIRECT
			O_DIRECT,
#else
			0,
#endif
			O_DSYNC, 0 /* FILEMAP */,
#ifdef O_NOATIME
			O_NOATIME,
#else
			0,
#endif
			O_NONBLOCK, 0 /* RANDOM */, 0 /* SEQUENTIAL */, 0 /* SHORT_LIVED */, 0 /* SYMLINK */, O_SYNC};
		return index >= 0 && index < (int)(sizeof t / sizeof t[0]) ? t[index] : 0;
	}
	case 1: { // File.Mode
		static const int t[] = {S_IRWXU, S_IRUSR, S_IWUSR, S_IXUSR, S_IRWXG, S_IRGRP, S_IWGRP, S_IXGRP, S_IRWXO, S_IROTH, S_IWOTH,
			S_IXOTH, S_ISUID, S_ISGID, S_ISVTX, S_IFMT, S_IFREG, S_IFDIR, S_IFBLK, S_IFCHR, S_IFLNK, S_IFIFO};
		return index >= 0 && index < (int)(sizeof t / sizeof t[0]) ? t[index] : 0;
	}
	case 2: { // File.Access_flag
		static const int t[] = {F_OK, R_OK, W_OK, X_OK};
		return t[index & 3];
	}
	case 3: // address family: unspec, inet, inet6
		return index == 0 ? AF_UNSPEC : index == 1 ? AF_INET : AF_INET6;
	case 4: // socket type: stream, dgram, raw
		return index == 0 ? SOCK_STREAM : index == 1 ? SOCK_DGRAM : SOCK_RAW;
	case 5: { // signals: SIGABRT SIGFPE SIGHUP SIGILL SIGINT SIGKILL SIGSEGV SIGTERM SIGWINCH SIGPROF
		static const int t[] = {SIGABRT, SIGFPE, SIGHUP, SIGILL, SIGINT, SIGKILL, SIGSEGV, SIGTERM, SIGWINCH, SIGPROF};
		return t[index];
	}
	case 6: { // getaddrinfo flags: PASSIVE CANONNAME NUMERICHOST NUMERICSERV V4MAPPED ALL ADDRCONFIG
		static const int t[] = {AI_PASSIVE, AI_CANONNAME, AI_NUMERICHOST, AI_NUMERICSERV, AI_V4MAPPED, AI_ALL, AI_ADDRCONFIG};
		return t[index];
	}
	case 7: { // getnameinfo flags: NAMEREQD DGRAM NOFQDN NUMERICHOST NUMERICSERV
		static const int t[] = {NI_NAMEREQD, NI_DGRAM, NI_NOFQDN, NI_NUMERICHOST, NI_NUMERICSERV};
		return t[index];
	}
	case 8: { // copyfile excl, ficlone, ficlone_force; symlink dir, junction
		static const int t[] = {UV_FS_COPYFILE_EXCL, UV_FS_COPYFILE_FICLONE, UV_FS_COPYFILE_FICLONE_FORCE, UV_FS_SYMLINK_DIR,
			UV_FS_SYMLINK_JUNCTION};
		return t[index];
	}
	case 9: // version: major, minor, patch, is_release, hex
		return index == 0 ? UV_VERSION_MAJOR : index == 1 ? UV_VERSION_MINOR : index == 2 ? UV_VERSION_PATCH : index == 3 ? UV_VERSION_IS_RELEASE : UV_VERSION_HEX;
	case 10: { // dirent types: UNKNOWN FILE DIR LINK FIFO SOCKET CHAR BLOCK
		static const int t[] = {UV_DIRENT_UNKNOWN, UV_DIRENT_FILE, UV_DIRENT_DIR, UV_DIRENT_LINK, UV_DIRENT_FIFO, UV_DIRENT_SOCKET,
			UV_DIRENT_CHAR, UV_DIRENT_BLOCK};
		for (int i = 0; i < 8; i++)
			if (t[i] == index) return i;
		return 0;
	}
	case 11: // UDP flags: partial, mmsg_chunk, mmsg_free; udp init flag recvmmsg; ipv6only; reuseaddr
		return index == 0 ? UV_UDP_PARTIAL : index == 1 ? UV_UDP_MMSG_CHUNK : index == 2 ? UV_UDP_MMSG_FREE : index == 3 ? UV_UDP_RECVMMSG
			: index == 4 ? UV_UDP_IPV6ONLY : UV_UDP_REUSEADDR;
	case 12: // fs event: rename, change; flags watch_entry, stat, recursive
		return index == 0 ? UV_RENAME : index == 1 ? UV_CHANGE : index == 2 ? UV_FS_EVENT_WATCH_ENTRY : index == 3 ? UV_FS_EVENT_STAT
			: UV_FS_EVENT_RECURSIVE;
	}
	return 0;
}

void *hxc_NativeUv_versionString(void) { return str_of_c(uv_version_string()); }
void *hxc_NativeUv_versionSuffix(void) { return str_of_c(UV_VERSION_SUFFIX); }

// ---- dispatching events to the port (during loopRun)

enum { EV_CLOSE, EV_CB, EV_REQ, EV_CONNECTION, EV_ALLOC, EV_READ, EV_EXIT, EV_UDP_RECV, EV_FS_EVENT, EV_FS_POLL };
static RT_TLS void **disp_slot; // the shadow-stack slot holding the dispatcher (of the thread's running loop)

static RT_TLS unsigned long dispatch_count; // events reported (hxc_NativeUv_loopRun, UV_RUN_ONCE)

static void dispatch(int32_t id, int32_t ev, int32_t a, void *b) {
	if (!disp_slot) return;
	dispatch_count++;
	RT_ROOT(b);
	void *args = hx_arr_new(AK_PTR, 4);
	RT_ROOT(args);
	int32_t iv[3] = {id, ev, a};
	for (int i = 0; i < 3; i++) {
		void *x = hx_box_int(iv[i]);
		set_elem(args_root, i, x);
	}
	set_elem(args_root, 3, *b_root);
	void *f = *disp_slot;
	hx_dyn_call(f, *args_root);
	RT_UNROOT(2);
}

// ---- loops

typedef struct {
	uv_loop_t *loop;
	int user_stop; // Loop.stop since the current run began (see hxc_NativeUv_loopRun)
} hx_loop;

void hxc_NativeThread_yield(void);

static int32_t default_loop_id;

static uv_loop_t *LOOP(int32_t id) { return ((hx_loop *)obj_get(id))->loop; }

static rt_lock_t default_loop_lock = RT_LOCK_INIT;
int32_t hxc_NativeUv_loopDefault(void) {
	rt_lock(&default_loop_lock);
	if (!default_loop_id) {
		hx_loop *l = calloc(1, sizeof *l);
		l->loop = uv_default_loop();
		default_loop_id = obj_add(l);
	}
	int32_t id = default_loop_id;
	rt_unlock(&default_loop_lock);
	return id;
}

int32_t hxc_NativeUv_loopInit(void) {
	hx_loop *l = calloc(1, sizeof *l);
	l->loop = malloc(sizeof(uv_loop_t));
	int r = uv_loop_init(l->loop);
	if (r < 0) {
		free(l->loop);
		free(l);
		return r;
	}
	return obj_add(l);
}

// Loop.run and green threads (rt_thread.c): uv_run blocks the OS thread, so
// while other green threads exist (eval.luv thread pool work, threads that
// signal an Async, ...) the loop is run without blocking in libuv: one
// UV_RUN_NOWAIT iteration at a time, waiting in between in the scheduler for
// the loop's backend descriptor (or its next timer), so the other threads run
// meanwhile. UV_RUN_ONCE ends after an iteration that reported an event.
// libuv registers new watchers with the backend only at its next poll, so
// while some are queued the next iteration follows without waiting. With one
// thread uv_run is called as is; a thread spawned by a callback meanwhile
// stops it (rt_spawn_hook) and the run goes on giving way.
static uv_loop_t *plain_loop; // the loop in a plain uv_run, if any
static int plain_spawned;

static void plain_on_spawn(void) {
	if (plain_loop && !plain_spawned) {
		plain_spawned = 1;
		uv_stop(plain_loop);
	}
}

// whether watchers wait to be added to the backend (libuv's private
// watcher_queue, a struct uv__queue or void *[2]: empty when it points to itself)
static int watchers_queued(uv_loop_t *loop) {
	void **q = (void **)&loop->watcher_queue;
	return q[0] != (void *)q;
}

// waits, letting the other green threads run, until the loop has work
static void coop_wait(uv_loop_t *loop) {
	if (!uv_loop_alive(loop)) return;
	if (watchers_queued(loop)) {
		hxc_NativeThread_yield();
		return;
	}
	uv_update_time(loop);
	int t = uv_backend_timeout(loop);
	if (t == 0) {
		hxc_NativeThread_yield();
		return;
	}
	int fd = uv_backend_fd(loop);
	if (fd >= 0) rt_wait_fd(fd, 0, t < 0 ? -1.0 : t / 1000.0);
	else rt_sleep(t < 0 || t > 1 ? 0.001 : t / 1000.0); // no pollable backend: poll every millisecond
}

int32_t hxc_NativeUv_loopRun(int32_t id, int32_t mode, void *dispatcher) {
	hx_loop *hl = (hx_loop *)obj_get(id);
	uv_loop_t *loop = hl->loop;
	void **saved = disp_slot;
	RT_ROOT(dispatcher);
	disp_slot = dispatcher_root;
	uv_run_mode m = mode == 0 ? UV_RUN_DEFAULT : mode == 1 ? UV_RUN_ONCE : UV_RUN_NOWAIT;
	int r;
	int coop = m != UV_RUN_NOWAIT && RT_NTHREADS() > 1;
	if (!coop) {
		uv_loop_t *saved_loop = plain_loop;
		int saved_spawned = plain_spawned;
		void (*saved_hook)(void) = rt_spawn_hook;
		plain_loop = loop;
		plain_spawned = 0;
		rt_spawn_hook = plain_on_spawn;
		r = uv_run(loop, m);
		coop = plain_spawned && r && m == UV_RUN_DEFAULT && !hl->user_stop;
		plain_loop = saved_loop;
		plain_spawned = saved_spawned;
		rt_spawn_hook = saved_hook;
	}
	if (coop) {
		for (;;) {
			unsigned long n = dispatch_count;
			r = uv_run(loop, UV_RUN_NOWAIT);
			if (!r || hl->user_stop || (m == UV_RUN_ONCE && dispatch_count != n)) break;
			coop_wait(loop);
		}
	}
	hl->user_stop = 0;
	disp_slot = saved;
	RT_UNROOT(1);
	return r != 0;
}

void hxc_NativeUv_loopStop(int32_t id) {
	hx_loop *hl = (hx_loop *)obj_get(id);
	hl->user_stop = 1;
	uv_stop(hl->loop);
}

int32_t hxc_NativeUv_loopClose(int32_t id) { return uv_loop_close(LOOP(id)); }
int32_t hxc_NativeUv_loopAlive(int32_t id) { return uv_loop_alive(LOOP(id)) != 0; }
void hxc_NativeUv_loopNow(int32_t id) { i64_out = (int64_t)uv_now(LOOP(id)); }
void hxc_NativeUv_loopUpdateTime(int32_t id) { uv_update_time(LOOP(id)); }
void hxc_NativeUv_libraryShutdown(void) { uv_library_shutdown(); }
void hxc_NativeUv_metricsIdleTime(int32_t id) { i64_out = (int64_t)uv_metrics_idle_time(LOOP(id)); }

// ---- handles

enum { HK_IDLE, HK_PREPARE, HK_CHECK, HK_TIMER, HK_ASYNC, HK_TCP, HK_UDP, HK_PIPE, HK_TTY, HK_SIGNAL, HK_PROCESS, HK_FS_EVENT, HK_FS_POLL };

typedef struct {
	int32_t id;
	int32_t kind;
	char *rbuf; // memory of the last allocation for reads
	size_t rlen;
	union {
		uv_handle_t h;
		uv_stream_t stream;
		uv_idle_t idle;
		uv_prepare_t prepare;
		uv_check_t check;
		uv_timer_t timer;
		uv_async_t async;
		uv_tcp_t tcp;
		uv_udp_t udp;
		uv_pipe_t pipe;
		uv_tty_t tty;
		uv_signal_t signal;
		uv_process_t process;
		uv_fs_event_t fs_event;
		uv_fs_poll_t fs_poll;
	} u;
} hx_h;

static hx_h *H(int32_t id) {
	hx_h *h = obj_get(id);
	return h;
}

static hx_h *new_handle(int32_t kind) {
	hx_h *h = calloc(1, sizeof(hx_h));
	h->kind = kind;
	h->u.h.data = h;
	h->id = obj_add(h);
	return h;
}

static void free_handle(hx_h *h) {
	OBJ(h->id) = NULL;
	free(h->rbuf);
	free(h);
}

static void async_cb(uv_async_t *a);

// init: returns the handle id, or a negative error. arg: a domain (tcp, udp),
// ipc (pipe), fd (tty), udp flags
int32_t hxc_NativeUv_handleInit(int32_t kind, int32_t loopId, int32_t arg, int32_t arg2) {
	uv_loop_t *loop = LOOP(loopId);
	hx_h *h = new_handle(kind);
	int r;
	switch (kind) {
	case HK_IDLE: r = uv_idle_init(loop, &h->u.idle); break;
	case HK_PREPARE: r = uv_prepare_init(loop, &h->u.prepare); break;
	case HK_CHECK: r = uv_check_init(loop, &h->u.check); break;
	case HK_TIMER: r = uv_timer_init(loop, &h->u.timer); break;
	case HK_ASYNC: r = uv_async_init(loop, &h->u.async, async_cb); break;
	case HK_TCP: r = arg < 0 ? uv_tcp_init(loop, &h->u.tcp) : uv_tcp_init_ex(loop, &h->u.tcp, (unsigned)arg); break;
	case HK_UDP: r = uv_udp_init_ex(loop, &h->u.udp, (unsigned)((arg < 0 ? AF_UNSPEC : arg) | arg2)); break;
	case HK_PIPE: r = uv_pipe_init(loop, &h->u.pipe, arg); break;
	case HK_TTY: r = uv_tty_init(loop, &h->u.tty, arg, 0); break;
	case HK_SIGNAL: r = uv_signal_init(loop, &h->u.signal); break;
	case HK_FS_EVENT: r = uv_fs_event_init(loop, &h->u.fs_event); break;
	case HK_FS_POLL: r = uv_fs_poll_init(loop, &h->u.fs_poll); break;
	default: r = UV_EINVAL;
	}
	h->u.h.data = h;
	if (r < 0) {
		free_handle(h);
		return r;
	}
	return h->id;
}

static void close_cb(uv_handle_t *uh) {
	hx_h *h = uh->data;
	int32_t id = h->id;
	free_handle(h);
	dispatch(id, EV_CLOSE, 0, NULL);
}

static void close_silent_cb(uv_handle_t *uh) { free_handle(uh->data); }

// Handle.close: nothing when already closing
int32_t hxc_NativeUv_handleClose(int32_t id) {
	hx_h *h = H(id);
	if (uv_is_closing(&h->u.h)) return 0;
	uv_close(&h->u.h, close_cb);
	return 1;
}

int32_t hxc_NativeUv_handleIsActive(int32_t id) { return uv_is_active(&H(id)->u.h) != 0; }
int32_t hxc_NativeUv_handleIsClosing(int32_t id) { return uv_is_closing(&H(id)->u.h) != 0; }
void hxc_NativeUv_handleRef(int32_t id) { uv_ref(&H(id)->u.h); }
void hxc_NativeUv_handleUnref(int32_t id) { uv_unref(&H(id)->u.h); }
int32_t hxc_NativeUv_handleHasRef(int32_t id) { return uv_has_ref(&H(id)->u.h) != 0; }

// send/recv buffer size: size 0 reads it (into lastError when >= 0)
int32_t hxc_NativeUv_bufferSize(int32_t id, int32_t send, int32_t size) {
	int v = size;
	int r = send ? uv_send_buffer_size(&H(id)->u.h, &v) : uv_recv_buffer_size(&H(id)->u.h, &v);
	return r < 0 ? r : v;
}

// ---- idle, prepare, check, timer, async, signal

static void watcher_cb_idle(uv_idle_t *w) { dispatch(((hx_h *)w->data)->id, EV_CB, 0, NULL); }
static void watcher_cb_prepare(uv_prepare_t *w) { dispatch(((hx_h *)w->data)->id, EV_CB, 0, NULL); }
static void watcher_cb_check(uv_check_t *w) { dispatch(((hx_h *)w->data)->id, EV_CB, 0, NULL); }
static void timer_cb(uv_timer_t *t) { dispatch(((hx_h *)t->data)->id, EV_CB, 0, NULL); }
static void async_cb(uv_async_t *a) { dispatch(((hx_h *)a->data)->id, EV_CB, 0, NULL); }
static void signal_cb(uv_signal_t *s, int signum) { dispatch(((hx_h *)s->data)->id, EV_CB, signum, NULL); }

int32_t hxc_NativeUv_watcherStart(int32_t id) {
	hx_h *h = H(id);
	switch (h->kind) {
	case HK_IDLE: return uv_idle_start(&h->u.idle, watcher_cb_idle);
	case HK_PREPARE: return uv_prepare_start(&h->u.prepare, watcher_cb_prepare);
	default: return uv_check_start(&h->u.check, watcher_cb_check);
	}
}

int32_t hxc_NativeUv_watcherStop(int32_t id) {
	hx_h *h = H(id);
	switch (h->kind) {
	case HK_IDLE: return uv_idle_stop(&h->u.idle);
	case HK_PREPARE: return uv_prepare_stop(&h->u.prepare);
	default: return uv_check_stop(&h->u.check);
	}
}

int32_t hxc_NativeUv_timerStart(int32_t id, int32_t timeout, int32_t repeat) {
	return uv_timer_start(&H(id)->u.timer, timer_cb, (uint64_t)(uint32_t)timeout, (uint64_t)(uint32_t)repeat);
}
int32_t hxc_NativeUv_timerStop(int32_t id) { return uv_timer_stop(&H(id)->u.timer); }
int32_t hxc_NativeUv_timerAgain(int32_t id) { return uv_timer_again(&H(id)->u.timer); }
void hxc_NativeUv_timerSetRepeat(int32_t id, int32_t repeat) { uv_timer_set_repeat(&H(id)->u.timer, (uint64_t)(uint32_t)repeat); }
int32_t hxc_NativeUv_timerGetRepeat(int32_t id) { return (int32_t)uv_timer_get_repeat(&H(id)->u.timer); }
int32_t hxc_NativeUv_timerGetDueIn(int32_t id) { return (int32_t)uv_timer_get_due_in(&H(id)->u.timer); }
int32_t hxc_NativeUv_asyncSend(int32_t id) { return uv_async_send(&H(id)->u.async); }

int32_t hxc_NativeUv_signalStart(int32_t id, int32_t signum, int32_t oneshot) {
	hx_h *h = H(id);
	return oneshot ? uv_signal_start_oneshot(&h->u.signal, signal_cb, signum) : uv_signal_start(&h->u.signal, signal_cb, signum);
}
int32_t hxc_NativeUv_signalStop(int32_t id) { return uv_signal_stop(&H(id)->u.signal); }
int32_t hxc_NativeUv_signalSignum(int32_t id) { return H(id)->u.signal.signum; }

// ---- requests

typedef struct {
	int32_t id;
	char *scratch; // copied data (writes) or data to copy out (reads)
	size_t scratch_len;
	uv_buf_t *bufs;
	struct addrinfo *ai;
	uv_dirent_t *dirents; // readdir
	int32_t dir_id;
	union {
		uv_req_t req;
		uv_fs_t fs;
		uv_connect_t connect;
		uv_write_t write;
		uv_shutdown_t shutdown;
		uv_getaddrinfo_t gai;
		uv_getnameinfo_t gni;
		uv_random_t random;
		uv_udp_send_t udp_send;
	} u;
} hx_r;

static hx_r *R(int32_t id) { return obj_get(id); }

int32_t hxc_NativeUv_reqNew(void) {
	hx_r *r = calloc(1, sizeof(hx_r));
	r->u.req.data = r;
	r->id = obj_add(r);
	return r->id;
}

static void req_clear(hx_r *r) {
	free(r->scratch);
	r->scratch = NULL;
	r->scratch_len = 0;
	free(r->bufs);
	r->bufs = NULL;
	if (r->ai) uv_freeaddrinfo(r->ai);
	r->ai = NULL;
}

void hxc_NativeUv_reqFree(int32_t id) {
	hx_r *r = R(id);
	req_clear(r);
	OBJ(id) = NULL;
	free(r);
}

int32_t hxc_NativeUv_reqCancel(int32_t id) { return uv_cancel(&R(id)->u.req); }

static void status_cb(hx_r *r, int status) { dispatch(r->id, EV_REQ, status, NULL); }
static void connect_cb(uv_connect_t *c, int status) { status_cb(c->data, status); }
static void write_cb(uv_write_t *w, int status) { status_cb(w->data, status); }
static void shutdown_cb(uv_shutdown_t *s, int status) { status_cb(s->data, status); }
static void udp_send_cb(uv_udp_send_t *s, int status) { status_cb(s->data, status); }
static void random_cb(uv_random_t *q, int status, void *buf, size_t len) { status_cb(q->data, status); }

// copies `data` into the request's scratch and splits it into `sizes` buffers
static void req_bufs(hx_r *r, void *data, void *sizes, unsigned *count) {
	int32_t n = sizes ? ARR_LEN(sizes) : 0;
	size_t total = 0;
	if (data)
		total = (size_t)BYTES_LEN(data);
	else
		for (int32_t i = 0; i < n; i++) total += (size_t)hx_aget_i_slow(sizes, i);
	req_clear(r);
	r->scratch = malloc(total ? total : 1);
	r->scratch_len = total;
	if (data && total) memcpy(r->scratch, BYTES_DATA(data), total);
	r->bufs = malloc(sizeof(uv_buf_t) * (n ? n : 1));
	size_t off = 0;
	for (int32_t i = 0; i < n; i++) {
		size_t len = (size_t)hx_aget_i_slow(sizes, i);
		r->bufs[i] = uv_buf_init(r->scratch + off, (unsigned)len);
		off += len;
	}
	*count = (unsigned)n;
}

// copies len bytes at offset src of the request's scratch into b[pos]
void hxc_NativeUv_reqCopyOut(int32_t id, void *b, int32_t pos, int32_t src, int32_t len) {
	hx_r *r = R(id);
	if (len > 0 && (size_t)src + (size_t)len <= r->scratch_len) memcpy(BYTES_DATA(b) + pos, r->scratch + src, (size_t)len);
}

// ---- socket addresses (Bytes of sizeof(struct sockaddr_storage))

int32_t hxc_NativeUv_sockaddrSize(void) { return (int32_t)sizeof(struct sockaddr_storage); }

int32_t hxc_NativeUv_sockaddrIp(void *host, int32_t port, int32_t v6, void *out) {
	char *h = hx_str_to_utf8(host);
	memset(BYTES_DATA(out), 0, sizeof(struct sockaddr_storage));
	int r = v6 ? uv_ip6_addr(h, port, (struct sockaddr_in6 *)BYTES_DATA(out)) : uv_ip4_addr(h, port, (struct sockaddr_in *)BYTES_DATA(out));
	free(h);
	return r;
}

// Sockaddr.port: -1 for None
int32_t hxc_NativeUv_sockaddrPort(void *sa) {
	struct sockaddr *s = (struct sockaddr *)BYTES_DATA(sa);
	if (s->sa_family == AF_INET) return ntohs(((struct sockaddr_in *)s)->sin_port);
	if (s->sa_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)s)->sin6_port);
	return -1;
}

// Sockaddr.to_string: null for None
void *hxc_NativeUv_sockaddrToString(void *sa) {
	struct sockaddr *s = (struct sockaddr *)BYTES_DATA(sa);
	char buf[64];
	memset(buf, 0, sizeof buf);
	if (s->sa_family == AF_INET)
		uv_ip4_name((struct sockaddr_in *)s, buf, sizeof buf);
	else if (s->sa_family == AF_INET6)
		uv_ip6_name((struct sockaddr_in6 *)s, buf, sizeof buf);
	else
		return NULL;
	return str_of_c(buf);
}

static void *sockaddr_bytes(const struct sockaddr *s, size_t len) {
	void *b = haxe_io_Bytes_alloc((int32_t)sizeof(struct sockaddr_storage));
	memset(BYTES_DATA(b), 0, sizeof(struct sockaddr_storage));
	if (s) memcpy(BYTES_DATA(b), s, len);
	return b;
}

// ---- TCP

int32_t hxc_NativeUv_tcpNoDelay(int32_t id, int32_t b) { return uv_tcp_nodelay(&H(id)->u.tcp, b); }
int32_t hxc_NativeUv_tcpKeepAlive(int32_t id, int32_t enable, int32_t delay) { return uv_tcp_keepalive(&H(id)->u.tcp, enable, (unsigned)delay); }
int32_t hxc_NativeUv_tcpSimultaneousAccepts(int32_t id, int32_t b) { return uv_tcp_simultaneous_accepts(&H(id)->u.tcp, b); }

int32_t hxc_NativeUv_tcpBind(int32_t id, void *sa, int32_t ipv6only) {
	return uv_tcp_bind(&H(id)->u.tcp, (struct sockaddr *)BYTES_DATA(sa), ipv6only ? UV_TCP_IPV6ONLY : 0);
}

// getsockname/getpeername (tcp, udp) into out
int32_t hxc_NativeUv_sockName(int32_t id, int32_t peer, void *out) {
	hx_h *h = H(id);
	int len = sizeof(struct sockaddr_storage);
	memset(BYTES_DATA(out), 0, sizeof(struct sockaddr_storage));
	struct sockaddr *s = (struct sockaddr *)BYTES_DATA(out);
	if (h->kind == HK_UDP) return peer ? uv_udp_getpeername(&h->u.udp, s, &len) : uv_udp_getsockname(&h->u.udp, s, &len);
	return peer ? uv_tcp_getpeername(&h->u.tcp, s, &len) : uv_tcp_getsockname(&h->u.tcp, s, &len);
}

int32_t hxc_NativeUv_tcpConnect(int32_t id, void *sa, int32_t rid) {
	return uv_tcp_connect(&R(rid)->u.connect, &H(id)->u.tcp, (struct sockaddr *)BYTES_DATA(sa), connect_cb);
}

// TCP.close_reset: the request id stands for the callback (EV_REQ with status 0)
static void close_reset_cb(uv_handle_t *uh) {
	hx_h *h = uh->data;
	int32_t rid = (int32_t)(intptr_t)h->rbuf;
	h->rbuf = NULL;
	free_handle(h);
	dispatch(rid, EV_REQ, 0, NULL);
}

int32_t hxc_NativeUv_tcpCloseReset(int32_t id, int32_t rid) {
	hx_h *h = H(id);
	free(h->rbuf);
	h->rbuf = (char *)(intptr_t)rid;
	h->rlen = 0;
	return uv_tcp_close_reset(&h->u.tcp, close_reset_cb);
}

// ---- streams

static RT_TLS int32_t alloc_size;
void hxc_NativeUv_allocSize(int32_t n) { alloc_size = n; }

static void alloc_cb(uv_handle_t *uh, size_t suggested, uv_buf_t *buf) {
	hx_h *h = uh->data;
	alloc_size = 0;
	dispatch(h->id, EV_ALLOC, (int32_t)suggested, NULL);
	size_t n = alloc_size > 0 ? (size_t)alloc_size : 0;
	if (h->rlen < n || !h->rbuf) {
		h->rbuf = realloc(h->rbuf, n ? n : 1);
		h->rlen = n;
	}
	*buf = uv_buf_init(h->rbuf, (unsigned)n);
}

static void read_cb(uv_stream_t *s, ssize_t nread, const uv_buf_t *buf) {
	hx_h *h = s->data;
	void *b = nread > 0 ? bytes_of(buf->base, (size_t)nread) : NULL;
	dispatch(h->id, EV_READ, (int32_t)nread, b);
}

static void connection_cb(uv_stream_t *s, int status) { dispatch(((hx_h *)s->data)->id, EV_CONNECTION, status, NULL); }

int32_t hxc_NativeUv_streamShutdown(int32_t id, int32_t rid) { return uv_shutdown(&R(rid)->u.shutdown, &H(id)->u.stream, shutdown_cb); }
int32_t hxc_NativeUv_streamListen(int32_t id, int32_t backlog) { return uv_listen(&H(id)->u.stream, backlog, connection_cb); }
int32_t hxc_NativeUv_streamAccept(int32_t server, int32_t client) { return uv_accept(&H(server)->u.stream, &H(client)->u.stream); }
int32_t hxc_NativeUv_readStart(int32_t id) { return uv_read_start(&H(id)->u.stream, alloc_cb, read_cb); }
int32_t hxc_NativeUv_readStop(int32_t id) { return uv_read_stop(&H(id)->u.stream); }

int32_t hxc_NativeUv_streamWrite(int32_t id, int32_t rid, void *data, void *sizes, int32_t sendHandle) {
	hx_h *h = H(id);
	hx_r *r = R(rid);
	unsigned n;
	req_bufs(r, data, sizes, &n);
	uv_stream_t *send = sendHandle > 0 ? &H(sendHandle)->u.stream : NULL;
	return uv_write2(&r->u.write, &h->u.stream, r->bufs, n, send, write_cb);
}

int32_t hxc_NativeUv_streamTryWrite(int32_t id, void *data, void *sizes) {
	int32_t rid = hxc_NativeUv_reqNew();
	hx_r *r = R(rid);
	unsigned n;
	req_bufs(r, data, sizes, &n);
	int res = uv_try_write(&H(id)->u.stream, r->bufs, n);
	hxc_NativeUv_reqFree(rid);
	return res;
}

int32_t hxc_NativeUv_streamWriteQueueSize(int32_t id) { return (int32_t)uv_stream_get_write_queue_size(&H(id)->u.stream); }
int32_t hxc_NativeUv_streamIsReadable(int32_t id) { return uv_is_readable(&H(id)->u.stream) != 0; }
int32_t hxc_NativeUv_streamIsWritable(int32_t id) { return uv_is_writable(&H(id)->u.stream) != 0; }
int32_t hxc_NativeUv_streamSetBlocking(int32_t id, int32_t b) { return uv_stream_set_blocking(&H(id)->u.stream, b); }

// ---- pipes, ttys

int32_t hxc_NativeUv_pipeBind(int32_t id, void *name) {
	char *n = bytes_z(name);
	int r = uv_pipe_bind(&H(id)->u.pipe, n);
	free(n);
	return r;
}

void hxc_NativeUv_pipeConnect(int32_t id, void *name, int32_t rid) {
	char *n = bytes_z(name);
	uv_pipe_connect(&R(rid)->u.connect, &H(id)->u.pipe, n, connect_cb);
	free(n);
}

// getsockname/getpeername: Bytes, null on failure (lastError)
void *hxc_NativeUv_pipeName(int32_t id, int32_t peer) {
	char buf[4096];
	size_t len = sizeof buf;
	int r = peer ? uv_pipe_getpeername(&H(id)->u.pipe, buf, &len) : uv_pipe_getsockname(&H(id)->u.pipe, buf, &len);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	return bytes_of(buf, len);
}

void hxc_NativeUv_pipePendingInstances(int32_t id, int32_t n) { uv_pipe_pending_instances(&H(id)->u.pipe, n); }

// 0 none, 1 tcp, 2 pipe
int32_t hxc_NativeUv_pipePendingType(int32_t id) {
	hx_h *h = H(id);
	if (uv_pipe_pending_count(&h->u.pipe) <= 0) return 0;
	uv_handle_type t = uv_pipe_pending_type(&h->u.pipe);
	return t == UV_TCP ? 1 : t == UV_NAMED_PIPE ? 2 : 0;
}

int32_t hxc_NativeUv_pipeChmod(int32_t id, int32_t mode) {
	int flags = mode == 0 ? UV_READABLE : mode == 1 ? UV_WRITABLE : (UV_READABLE | UV_WRITABLE);
	return uv_pipe_chmod(&H(id)->u.pipe, flags);
}

int32_t hxc_NativeUv_ttySetMode(int32_t id, int32_t mode) {
	return uv_tty_set_mode(&H(id)->u.tty, mode == 0 ? UV_TTY_MODE_NORMAL : mode == 1 ? UV_TTY_MODE_RAW : UV_TTY_MODE_IO);
}
int32_t hxc_NativeUv_ttyResetMode(void) { return uv_tty_reset_mode(); }

// [width, height], null on failure
void *hxc_NativeUv_ttyGetWinSize(int32_t id) {
	int w, hh;
	int r = uv_tty_get_winsize(&H(id)->u.tty, &w, &hh);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	void *a = hx_arr_new(AK_I32, 2);
	((int32_t *)ARR_DATA(a))[0] = w;
	((int32_t *)ARR_DATA(a))[1] = hh;
	return a;
}

void hxc_NativeUv_ttySetVTermState(int32_t s) { uv_tty_set_vterm_state(s == 0 ? UV_TTY_SUPPORTED : UV_TTY_UNSUPPORTED); }
int32_t hxc_NativeUv_ttyGetVTermState(void) {
	uv_tty_vtermstate_t s;
	int r = uv_tty_get_vterm_state(&s);
	return r < 0 ? r : (s == UV_TTY_SUPPORTED ? 0 : 1);
}

// ---- UDP

int32_t hxc_NativeUv_udpBind(int32_t id, void *sa, int32_t flags) { return uv_udp_bind(&H(id)->u.udp, (struct sockaddr *)BYTES_DATA(sa), (unsigned)flags); }
int32_t hxc_NativeUv_udpConnect(int32_t id, void *sa) { return uv_udp_connect(&H(id)->u.udp, sa ? (struct sockaddr *)BYTES_DATA(sa) : NULL); }

int32_t hxc_NativeUv_udpSetMembership(int32_t id, void *group, void *iface, void *source, int32_t join) {
	char *g = hx_str_to_utf8(group), *i = hx_str_to_utf8(iface), *s = source ? hx_str_to_utf8(source) : NULL;
	uv_membership m = join ? UV_JOIN_GROUP : UV_LEAVE_GROUP;
	int r = s ? uv_udp_set_source_membership(&H(id)->u.udp, g, i, s, m) : uv_udp_set_membership(&H(id)->u.udp, g, i, m);
	free(g);
	free(i);
	free(s);
	return r;
}

// 0 multicast loop, 1 multicast ttl, 2 broadcast, 3 ttl
int32_t hxc_NativeUv_udpSetOption(int32_t id, int32_t opt, int32_t v) {
	uv_udp_t *u = &H(id)->u.udp;
	switch (opt) {
	case 0: return uv_udp_set_multicast_loop(u, v);
	case 1: return uv_udp_set_multicast_ttl(u, v);
	case 2: return uv_udp_set_broadcast(u, v);
	default: return uv_udp_set_ttl(u, v);
	}
}

int32_t hxc_NativeUv_udpSetMulticastInterface(int32_t id, void *iface) {
	char *i = hx_str_to_utf8(iface);
	int r = uv_udp_set_multicast_interface(&H(id)->u.udp, i);
	free(i);
	return r;
}

int32_t hxc_NativeUv_udpSend(int32_t id, int32_t rid, void *data, void *sizes, void *sa) {
	hx_r *r = R(rid);
	unsigned n;
	req_bufs(r, data, sizes, &n);
	return uv_udp_send(&r->u.udp_send, &H(id)->u.udp, r->bufs, n, sa ? (struct sockaddr *)BYTES_DATA(sa) : NULL, udp_send_cb);
}

int32_t hxc_NativeUv_udpTrySend(int32_t id, void *data, void *sizes, void *sa) {
	int32_t rid = hxc_NativeUv_reqNew();
	hx_r *r = R(rid);
	unsigned n;
	req_bufs(r, data, sizes, &n);
	int res = uv_udp_try_send(&H(id)->u.udp, r->bufs, n, sa ? (struct sockaddr *)BYTES_DATA(sa) : NULL);
	hxc_NativeUv_reqFree(rid);
	return res;
}

// [data or null, address or null, flags]
static void udp_recv_cb(uv_udp_t *u, ssize_t nread, const uv_buf_t *buf, const struct sockaddr *addr, unsigned flags) {
	hx_h *h = u->data;
	if (nread < 0) {
		dispatch(h->id, EV_UDP_RECV, (int32_t)nread, NULL);
		return;
	}
	void *a = hx_arr_new(AK_PTR, 3);
	RT_ROOT(a);
	void *d = bytes_of(buf->base, (size_t)nread);
	set_elem(a_root, 0, d);
	if (addr) {
		void *s = sockaddr_bytes(addr, addr->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in));
		set_elem(a_root, 1, s);
	}
	void *f = hx_box_int((int32_t)flags);
	set_elem(a_root, 2, f);
	RT_RELOAD(a);
	RT_UNROOT(1);
	dispatch(h->id, EV_UDP_RECV, (int32_t)nread, a);
}

int32_t hxc_NativeUv_udpRecvStart(int32_t id) { return uv_udp_recv_start(&H(id)->u.udp, alloc_cb, udp_recv_cb); }
int32_t hxc_NativeUv_udpRecvStop(int32_t id) { return uv_udp_recv_stop(&H(id)->u.udp); }
int32_t hxc_NativeUv_udpSendQueue(int32_t id, int32_t count) {
	uv_udp_t *u = &H(id)->u.udp;
	return (int32_t)(count ? uv_udp_get_send_queue_count(u) : uv_udp_get_send_queue_size(u));
}

// ---- processes

static void exit_cb(uv_process_t *p, int64_t exit_status, int term_signal) {
	hx_h *h = p->data;
	void *sig = hx_box_int(term_signal);
	i64_out = exit_status;
	dispatch(h->id, EV_EXIT, (int32_t)exit_status, sig);
}

// redirections: per entry child fd, kind (0 ignore, 1 create pipe, 2 inherit fd,
// 3 inherit stream), pipe flags (1 readable, 2 writable, 4 overlapped), fd or stream
// handle id. flags: 1 setuid, 2 setgid, 4 windows_verbatim_arguments, 8 detached,
// 16 windows_hide, 32 windows_hide_console, 64 windows_hide_gui
int32_t hxc_NativeUv_processSpawn(int32_t loopId, void *cmd, void *args, void *env, void *cwd, int32_t flags, int32_t uid,
	int32_t gid, void *redirect, int32_t onExit) {
	uv_loop_t *loop = LOOP(loopId);
	uv_process_options_t o;
	memset(&o, 0, sizeof o);
	int32_t nargs = args ? ARR_LEN(args) : 0;
	char **argv = calloc((size_t)nargs + 1, sizeof(char *));
	for (int32_t i = 0; i < nargs; i++) argv[i] = bytes_z(hx_aget_p_slow(args, i));
	int32_t nenv = env ? ARR_LEN(env) : 0;
	char **envp = NULL;
	if (env) {
		envp = calloc((size_t)nenv + 1, sizeof(char *));
		for (int32_t i = 0; i < nenv; i++) envp[i] = bytes_z(hx_aget_p_slow(env, i));
	}
	char *file = bytes_z(cmd);
	char *dir = bytes_z(cwd);
	// at least 3 entries (stdin, stdout, stderr); missing ones are ignored
	int32_t nred = redirect ? ARR_LEN(redirect) / 4 : 0;
	int count = 3;
	for (int32_t i = 0; i < nred; i++) {
		int fd = hx_aget_i_slow(redirect, 4 * i);
		if (fd + 1 > count) count = fd + 1;
	}
	uv_stdio_container_t *stdio = calloc((size_t)count, sizeof(uv_stdio_container_t));
	for (int i = 0; i < count; i++) stdio[i].flags = UV_IGNORE;
	for (int32_t i = 0; i < nred; i++) {
		int fd = hx_aget_i_slow(redirect, 4 * i), kind = hx_aget_i_slow(redirect, 4 * i + 1), pf = hx_aget_i_slow(redirect, 4 * i + 2),
			v = hx_aget_i_slow(redirect, 4 * i + 3);
		if (fd < 0) continue;
		// List.find: the first redirection for a descriptor wins
		int seen = 0;
		for (int32_t j = 0; j < i; j++)
			if (hx_aget_i_slow(redirect, 4 * j) == fd) seen = 1;
		if (seen) continue;
		switch (kind) {
		case 1:
			stdio[fd].flags = UV_CREATE_PIPE | (pf & 1 ? UV_READABLE_PIPE : 0) | (pf & 2 ? UV_WRITABLE_PIPE : 0) | (pf & 4 ? UV_OVERLAPPED_PIPE : 0);
			stdio[fd].data.stream = &H(v)->u.stream;
			break;
		case 2:
			stdio[fd].flags = UV_INHERIT_FD;
			stdio[fd].data.fd = v;
			break;
		case 3:
			stdio[fd].flags = UV_INHERIT_STREAM;
			stdio[fd].data.stream = &H(v)->u.stream;
			break;
		}
	}
	o.file = file;
	o.args = argv;
	o.env = envp;
	o.cwd = dir;
	o.stdio_count = count;
	o.stdio = stdio;
	o.uid = (uv_uid_t)uid;
	o.gid = (uv_gid_t)gid;
	o.flags = (flags & 1 ? UV_PROCESS_SETUID : 0) | (flags & 2 ? UV_PROCESS_SETGID : 0) | (flags & 4 ? UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS : 0)
		| (flags & 8 ? UV_PROCESS_DETACHED : 0) | (flags & 16 ? UV_PROCESS_WINDOWS_HIDE : 0) | (flags & 32 ? UV_PROCESS_WINDOWS_HIDE_CONSOLE : 0)
		| (flags & 64 ? UV_PROCESS_WINDOWS_HIDE_GUI : 0);
	o.exit_cb = onExit ? exit_cb : NULL;
	hx_h *h = new_handle(HK_PROCESS);
	int r = uv_spawn(loop, &h->u.process, &o);
	h->u.h.data = h;
	for (int32_t i = 0; i < nargs; i++) free(argv[i]);
	free(argv);
	if (envp) {
		for (int32_t i = 0; i < nenv; i++) free(envp[i]);
		free(envp);
	}
	free(file);
	free(dir);
	free(stdio);
	if (r < 0) {
		// luv: Handle.close process ignore
		uv_close(&h->u.h, close_silent_cb);
		return r;
	}
	return h->id;
}

void hxc_NativeUv_disableStdioInheritance(void) { uv_disable_stdio_inheritance(); }
int32_t hxc_NativeUv_killPid(int32_t pid, int32_t sig) { return uv_kill(pid, sig); }
int32_t hxc_NativeUv_processPid(int32_t id) { return uv_process_get_pid(&H(id)->u.process); }

// ---- DNS

static void gai_cb(uv_getaddrinfo_t *q, int status, struct addrinfo *res) {
	hx_r *r = q->data;
	r->ai = res;
	dispatch(r->id, EV_REQ, status, NULL);
}

static void gni_cb(uv_getnameinfo_t *q, int status, const char *host, const char *service) {
	hx_r *r = q->data;
	dispatch(r->id, EV_REQ, status, NULL);
}

// hints: family, socktype, protocol, flags; -1: not given (no hints at all when all are)
int32_t hxc_NativeUv_getAddrInfo(int32_t loopId, int32_t rid, void *node, void *service, int32_t family, int32_t socktype,
	int32_t protocol, int32_t flags, int32_t hasHints) {
	struct addrinfo hints;
	memset(&hints, 0, sizeof hints);
	hints.ai_family = family < 0 ? AF_UNSPEC : family;
	hints.ai_socktype = socktype < 0 ? 0 : socktype;
	hints.ai_protocol = protocol < 0 ? 0 : protocol;
	hints.ai_flags = flags < 0 ? 0 : flags;
	char *n = node ? hx_str_to_utf8(node) : NULL, *s = service ? hx_str_to_utf8(service) : NULL;
	hx_r *r = R(rid);
	req_clear(r);
	int res = uv_getaddrinfo(LOOP(loopId), &r->u.gai, gai_cb, n, s, hasHints ? &hints : NULL);
	free(n);
	free(s);
	return res;
}

// per entry: family, socktype, protocol, address (Bytes), canonical name (String or null); frees the list
void *hxc_NativeUv_addrInfoResult(int32_t rid) {
	hx_r *r = R(rid);
	int32_t n = 0;
	for (struct addrinfo *a = r->ai; a; a = a->ai_next) n++;
	void *arr = hx_arr_new(AK_PTR, 5 * n);
	RT_ROOT(arr);
	int32_t i = 0;
	for (struct addrinfo *a = r->ai; a; a = a->ai_next, i++) {
		void *x = hx_box_int(a->ai_family);
		set_elem(arr_root, 5 * i, x);
		x = hx_box_int(a->ai_socktype);
		set_elem(arr_root, 5 * i + 1, x);
		x = hx_box_int(a->ai_protocol);
		set_elem(arr_root, 5 * i + 2, x);
		x = sockaddr_bytes(a->ai_addr, a->ai_addrlen);
		set_elem(arr_root, 5 * i + 3, x);
		if (a->ai_canonname) {
			x = str_of_c(a->ai_canonname);
			set_elem(arr_root, 5 * i + 4, x);
		}
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	if (r->ai) uv_freeaddrinfo(r->ai);
	r->ai = NULL;
	return arr;
}

int32_t hxc_NativeUv_getNameInfo(int32_t loopId, int32_t rid, void *sa, int32_t flags) {
	return uv_getnameinfo(LOOP(loopId), &R(rid)->u.gni, gni_cb, (struct sockaddr *)BYTES_DATA(sa), flags);
}

// [host, service]
void *hxc_NativeUv_nameInfoResult(int32_t rid) {
	hx_r *r = R(rid);
	void *arr = hx_arr_new(AK_PTR, 2);
	RT_ROOT(arr);
	void *x = str_of_c(r->u.gni.host);
	set_elem(arr_root, 0, x);
	x = str_of_c(r->u.gni.service);
	set_elem(arr_root, 1, x);
	RT_RELOAD(arr);
	RT_UNROOT(1);
	return arr;
}

// ---- files

enum { FS_OPEN, FS_CLOSE, FS_READ, FS_WRITE, FS_UNLINK, FS_MKDIR, FS_MKDTEMP, FS_MKSTEMP, FS_RMDIR, FS_OPENDIR, FS_CLOSEDIR, FS_READDIR,
	FS_SCANDIR, FS_STAT, FS_LSTAT, FS_FSTAT, FS_STATFS, FS_RENAME, FS_FSYNC, FS_FDATASYNC, FS_FTRUNCATE, FS_COPYFILE, FS_SENDFILE,
	FS_ACCESS, FS_CHMOD, FS_FCHMOD, FS_UTIME, FS_LUTIME, FS_FUTIME, FS_LINK, FS_SYMLINK, FS_READLINK, FS_REALPATH, FS_CHOWN, FS_LCHOWN,
	FS_FCHOWN };

typedef struct {
	uv_dir_t *dir;
} hx_dir;

static void fs_cb(uv_fs_t *q) {
	hx_r *r = q->data;
	dispatch(r->id, EV_REQ, (int32_t)q->result, NULL);
}

// one entry point for luv's File functions: loop < 0 runs synchronously
// (luv's File.Sync: the default loop, no callback). p1, p2: paths (Bytes);
// i1..i3: ints (file, flags, mode, uid, gid, dir id, number of entries);
// f1, f2: floats (offsets, lengths, times); data/sizes: buffers
int32_t hxc_NativeUv_fs(int32_t op, int32_t loopId, int32_t rid, void *p1, void *p2, int32_t i1, int32_t i2, int32_t i3, double f1,
	double f2, void *data, void *sizes) {
	uv_loop_t *loop = loopId < 0 ? uv_default_loop() : LOOP(loopId);
	uv_fs_cb cb = loopId < 0 ? NULL : fs_cb;
	hx_r *r = R(rid);
	uv_fs_t *q = &r->u.fs;
	char *a = bytes_z(p1), *b = bytes_z(p2);
	unsigned n = 0;
	int res;
	switch (op) {
	case FS_OPEN: res = uv_fs_open(loop, q, a, i1, i2, cb); break;
	case FS_CLOSE: res = uv_fs_close(loop, q, i1, cb); break;
	case FS_READ:
	case FS_WRITE:
		req_bufs(r, data, sizes, &n);
		res = op == FS_READ ? uv_fs_read(loop, q, i1, r->bufs, n, (int64_t)f1, cb) : uv_fs_write(loop, q, i1, r->bufs, n, (int64_t)f1, cb);
		break;
	case FS_UNLINK: res = uv_fs_unlink(loop, q, a, cb); break;
	case FS_MKDIR: res = uv_fs_mkdir(loop, q, a, i1, cb); break;
	case FS_MKDTEMP: res = uv_fs_mkdtemp(loop, q, a, cb); break;
	case FS_MKSTEMP: res = uv_fs_mkstemp(loop, q, a, cb); break;
	case FS_RMDIR: res = uv_fs_rmdir(loop, q, a, cb); break;
	case FS_OPENDIR: res = uv_fs_opendir(loop, q, a, cb); break;
	case FS_CLOSEDIR: res = uv_fs_closedir(loop, q, ((hx_dir *)obj_get(i1))->dir, cb); break;
	case FS_READDIR: {
		uv_dir_t *dir = ((hx_dir *)obj_get(i1))->dir;
		free(r->dirents);
		r->dirents = calloc((size_t)(i2 > 0 ? i2 : 1), sizeof(uv_dirent_t));
		dir->dirents = r->dirents;
		dir->nentries = (size_t)(i2 > 0 ? i2 : 0);
		r->dir_id = i1;
		res = uv_fs_readdir(loop, q, dir, cb);
		break;
	}
	case FS_SCANDIR: res = uv_fs_scandir(loop, q, a, 0, cb); break;
	case FS_STAT: res = uv_fs_stat(loop, q, a, cb); break;
	case FS_LSTAT: res = uv_fs_lstat(loop, q, a, cb); break;
	case FS_FSTAT: res = uv_fs_fstat(loop, q, i1, cb); break;
	case FS_STATFS: res = uv_fs_statfs(loop, q, a, cb); break;
	case FS_RENAME: res = uv_fs_rename(loop, q, a, b, cb); break;
	case FS_FSYNC: res = uv_fs_fsync(loop, q, i1, cb); break;
	case FS_FDATASYNC: res = uv_fs_fdatasync(loop, q, i1, cb); break;
	case FS_FTRUNCATE: res = uv_fs_ftruncate(loop, q, i1, (int64_t)f1, cb); break;
	case FS_COPYFILE: res = uv_fs_copyfile(loop, q, a, b, i1, cb); break;
	case FS_SENDFILE: res = uv_fs_sendfile(loop, q, i2, i1, (int64_t)f1, (size_t)f2, cb); break; // (to, from)
	case FS_ACCESS: res = uv_fs_access(loop, q, a, i1, cb); break;
	case FS_CHMOD: res = uv_fs_chmod(loop, q, a, i1, cb); break;
	case FS_FCHMOD: res = uv_fs_fchmod(loop, q, i1, i2, cb); break;
	case FS_UTIME: res = uv_fs_utime(loop, q, a, f1, f2, cb); break;
	case FS_LUTIME: res = uv_fs_lutime(loop, q, a, f1, f2, cb); break;
	case FS_FUTIME: res = uv_fs_futime(loop, q, i1, f1, f2, cb); break;
	case FS_LINK: res = uv_fs_link(loop, q, a, b, cb); break;
	case FS_SYMLINK: res = uv_fs_symlink(loop, q, a, b, i1, cb); break;
	case FS_READLINK: res = uv_fs_readlink(loop, q, a, cb); break;
	case FS_REALPATH: res = uv_fs_realpath(loop, q, a, cb); break;
	case FS_CHOWN: res = uv_fs_chown(loop, q, a, (uv_uid_t)i1, (uv_gid_t)i2, cb); break;
	case FS_LCHOWN: res = uv_fs_lchown(loop, q, a, (uv_uid_t)i1, (uv_gid_t)i2, cb); break;
	case FS_FCHOWN: res = uv_fs_fchown(loop, q, i1, (uv_uid_t)i2, (uv_gid_t)i3, cb); break;
	default: res = UV_EINVAL;
	}
	free(a);
	free(b);
	return res;
}

int32_t hxc_NativeUv_fsResult(int32_t rid) { return (int32_t)R(rid)->u.fs.result; }
void hxc_NativeUv_fsCleanup(int32_t rid) { uv_fs_req_cleanup(&R(rid)->u.fs); }
void *hxc_NativeUv_fsPath(int32_t rid) { return bytes_of_c(R(rid)->u.fs.path); }
void *hxc_NativeUv_fsPtrString(int32_t rid) { return bytes_of_c((const char *)R(rid)->u.fs.ptr); }

static void put64(unsigned char *p, int i, int64_t v) { memcpy(p + 8 * i, &v, 8); }

static void stat_into(unsigned char *p, const uv_stat_t *s) {
	uint64_t v[12] = {s->st_dev, s->st_mode, s->st_nlink, s->st_uid, s->st_gid, s->st_rdev, s->st_ino, s->st_size, s->st_blksize,
		s->st_blocks, s->st_flags, s->st_gen};
	for (int i = 0; i < 12; i++) put64(p, i, (int64_t)v[i]);
	const uv_timespec_t *t[4] = {&s->st_atim, &s->st_mtim, &s->st_ctim, &s->st_birthtim};
	for (int i = 0; i < 4; i++) {
		put64(p, 12 + 2 * i, (int64_t)t[i]->tv_sec);
		put64(p, 13 + 2 * i, (int64_t)t[i]->tv_nsec);
	}
}

// 20 int64: dev mode nlink uid gid rdev ino size blksize blocks flags gen, then sec/nsec of atim mtim ctim birthtim
void hxc_NativeUv_fsStat(int32_t rid, void *out) { stat_into(BYTES_DATA(out), &R(rid)->u.fs.statbuf); }

// 11 int64: type bsize blocks bfree bavail files ffree f_spare[4]
void hxc_NativeUv_fsStatfs(int32_t rid, void *out) {
	uv_statfs_t *s = R(rid)->u.fs.ptr;
	uint64_t v[11] = {s->f_type, s->f_bsize, s->f_blocks, s->f_bfree, s->f_bavail, s->f_files, s->f_ffree, s->f_spare[0], s->f_spare[1],
		s->f_spare[2], s->f_spare[3]};
	for (int i = 0; i < 11; i++) put64(BYTES_DATA(out), i, (int64_t)v[i]);
}

int32_t hxc_NativeUv_fsDir(int32_t rid) {
	hx_dir *d = malloc(sizeof *d);
	d->dir = R(rid)->u.fs.ptr;
	return obj_add(d);
}

// readdir: per entry, type then name (Bytes)
void *hxc_NativeUv_fsDirents(int32_t rid) {
	hx_r *r = R(rid);
	int32_t n = (int32_t)r->u.fs.result;
	if (n < 0) n = 0;
	void *arr = hx_arr_new(AK_PTR, 2 * n);
	RT_ROOT(arr);
	for (int32_t i = 0; i < n; i++) {
		void *x = hx_box_int(hxc_NativeUv_constant(10, r->dirents[i].type));
		set_elem(arr_root, 2 * i, x);
		x = bytes_of_c(r->dirents[i].name);
		set_elem(arr_root, 2 * i + 1, x);
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	return arr;
}

// scandir_next: [type, name] or null at the end
void *hxc_NativeUv_fsScandirNext(int32_t rid) {
	uv_dirent_t ent;
	if (uv_fs_scandir_next(&R(rid)->u.fs, &ent) < 0) return NULL;
	void *arr = hx_arr_new(AK_PTR, 2);
	RT_ROOT(arr);
	void *x = hx_box_int(hxc_NativeUv_constant(10, ent.type));
	set_elem(arr_root, 0, x);
	x = bytes_of_c(ent.name);
	set_elem(arr_root, 1, x);
	RT_RELOAD(arr);
	RT_UNROOT(1);
	return arr;
}

// ---- fs events and polls

static void fs_event_cb(uv_fs_event_t *e, const char *filename, int events, int status) {
	hx_h *h = e->data;
	void *a = hx_arr_new(AK_PTR, 2);
	RT_ROOT(a);
	if (filename) {
		void *f = bytes_of_c(filename);
		set_elem(a_root, 0, f);
	}
	void *ev = hx_box_int(events);
	set_elem(a_root, 1, ev);
	RT_RELOAD(a);
	RT_UNROOT(1);
	dispatch(h->id, EV_FS_EVENT, status, a);
}

int32_t hxc_NativeUv_fsEventStart(int32_t id, void *path, int32_t flags) {
	char *p = bytes_z(path);
	int r = uv_fs_event_start(&H(id)->u.fs_event, fs_event_cb, p, (unsigned)flags);
	free(p);
	return r;
}
int32_t hxc_NativeUv_fsEventStop(int32_t id) { return uv_fs_event_stop(&H(id)->u.fs_event); }

static void fs_poll_cb(uv_fs_poll_t *p, int status, const uv_stat_t *prev, const uv_stat_t *curr) {
	hx_h *h = p->data;
	if (status < 0) {
		dispatch(h->id, EV_FS_POLL, status, NULL);
		return;
	}
	void *a = hx_arr_new(AK_PTR, 2);
	RT_ROOT(a);
	void *b = haxe_io_Bytes_alloc(160);
	stat_into(BYTES_DATA(b), prev);
	set_elem(a_root, 0, b);
	b = haxe_io_Bytes_alloc(160);
	stat_into(BYTES_DATA(b), curr);
	set_elem(a_root, 1, b);
	RT_RELOAD(a);
	RT_UNROOT(1);
	dispatch(h->id, EV_FS_POLL, status, a);
}

int32_t hxc_NativeUv_fsPollStart(int32_t id, void *path, int32_t interval) {
	char *p = bytes_z(path);
	int r = uv_fs_poll_start(&H(id)->u.fs_poll, fs_poll_cb, p, (unsigned)interval);
	free(p);
	return r;
}
int32_t hxc_NativeUv_fsPollStop(int32_t id) { return uv_fs_poll_stop(&H(id)->u.fs_poll); }

// ---- random

int32_t hxc_NativeUv_random(int32_t loopId, int32_t rid, int32_t len) {
	hx_r *r = R(rid);
	req_clear(r);
	r->scratch = malloc(len > 0 ? (size_t)len : 1);
	r->scratch_len = (size_t)(len > 0 ? len : 0);
	if (loopId < 0) return uv_random(NULL, NULL, r->scratch, r->scratch_len, 0, NULL);
	return uv_random(LOOP(loopId), &r->u.random, r->scratch, r->scratch_len, 0, random_cb);
}

// ---- environment, time, paths, system

void *hxc_NativeUv_getEnv(void *name) {
	char *n = hx_str_to_utf8(name);
	size_t len = 256;
	char *buf = malloc(len);
	int r = uv_os_getenv(n, buf, &len);
	if (r == UV_ENOBUFS) {
		buf = realloc(buf, len);
		r = uv_os_getenv(n, buf, &len);
	}
	free(n);
	void *res = NULL;
	if (r < 0)
		last_err = r;
	else
		res = bytes_of(buf, len);
	free(buf);
	return res;
}

int32_t hxc_NativeUv_setEnv(void *name, void *value) {
	char *n = hx_str_to_utf8(name);
	char *v = value ? bytes_z(value) : NULL;
	int r = v ? uv_os_setenv(n, v) : uv_os_unsetenv(n);
	free(n);
	free(v);
	return r;
}

// name (String), value (Bytes), ...; null on failure
void *hxc_NativeUv_environ(void) {
	uv_env_item_t *items;
	int count;
	int r = uv_os_environ(&items, &count);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	void *arr = hx_arr_new(AK_PTR, 2 * count);
	RT_ROOT(arr);
	for (int i = 0; i < count; i++) {
		void *x = str_of_c(items[i].name);
		set_elem(arr_root, 2 * i, x);
		x = bytes_of_c(items[i].value);
		set_elem(arr_root, 2 * i + 1, x);
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	uv_os_free_environ(items, count);
	return arr;
}

// sec into i64_out, usec returned; negative error
int32_t hxc_NativeUv_getTimeOfDay(void) {
	uv_timeval64_t tv;
	int r = uv_gettimeofday(&tv);
	if (r < 0) return r;
	i64_out = tv.tv_sec;
	return tv.tv_usec;
}

void hxc_NativeUv_hrTime(void) { i64_out = (int64_t)uv_hrtime(); }
void hxc_NativeUv_sleep(int32_t ms) { uv_sleep((unsigned)ms); }

// 0 exepath, 1 cwd, 2 homedir, 3 tmpdir: Bytes, null on failure
void *hxc_NativeUv_path(int32_t which) {
	char buf[4096];
	size_t len = sizeof buf;
	int r = which == 0 ? uv_exepath(buf, &len) : which == 1 ? uv_cwd(buf, &len) : which == 2 ? uv_os_homedir(buf, &len) : uv_os_tmpdir(buf, &len);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	return bytes_of(buf, len);
}

int32_t hxc_NativeUv_chdir(void *dir) {
	char *d = bytes_z(dir);
	int r = uv_chdir(d);
	free(d);
	return r;
}

// name, is_internal, physical (Bytes), address, netmask per interface; null on failure
void *hxc_NativeUv_interfaceAddresses(void) {
	uv_interface_address_t *a;
	int count;
	int r = uv_interface_addresses(&a, &count);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	void *arr = hx_arr_new(AK_PTR, 5 * count);
	RT_ROOT(arr);
	for (int i = 0; i < count; i++) {
		void *x = str_of_c(a[i].name);
		set_elem(arr_root, 5 * i, x);
		x = hx_box_bool(a[i].is_internal);
		set_elem(arr_root, 5 * i + 1, x);
		x = bytes_of(a[i].phys_addr, 6);
		set_elem(arr_root, 5 * i + 2, x);
		x = sockaddr_bytes((struct sockaddr *)&a[i].address, sizeof a[i].address);
		set_elem(arr_root, 5 * i + 3, x);
		x = sockaddr_bytes((struct sockaddr *)&a[i].netmask, sizeof a[i].netmask);
		set_elem(arr_root, 5 * i + 4, x);
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	uv_free_interface_addresses(a, count);
	return arr;
}

// 0 if_indextoname, 1 if_indextoiid, 2 gethostname: String, null on failure
void *hxc_NativeUv_netName(int32_t which, int32_t index) {
	char buf[1024];
	size_t len = sizeof buf;
	int r = which == 0 ? uv_if_indextoname((unsigned)index, buf, &len) : which == 1 ? uv_if_indextoiid((unsigned)index, buf, &len) : uv_os_gethostname(buf, &len);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	return hx_str_of_utf8(buf, (int32_t)len);
}

double hxc_NativeUv_uptime(void) {
	double t = 0;
	int r = uv_uptime(&t);
	last_err = r;
	return t;
}

void *hxc_NativeUv_loadAvg(void) {
	double avg[3];
	uv_loadavg(avg);
	void *a = hx_arr_new(AK_F64, 3);
	memcpy(ARR_DATA(a), avg, sizeof avg);
	return a;
}

// 0 free, 1 total, 2 constrained, 3 resident set (lastError): into i64_out
void hxc_NativeUv_memory(int32_t which) {
	if (which == 3) {
		size_t rss = 0;
		last_err = uv_resident_set_memory(&rss);
		i64_out = (int64_t)rss;
		return;
	}
	i64_out = (int64_t)(which == 0 ? uv_get_free_memory() : which == 1 ? uv_get_total_memory() : uv_get_constrained_memory());
}

int32_t hxc_NativeUv_getPriority(int32_t pid) {
	int p = 0;
	int r = uv_os_getpriority(pid, &p);
	last_err = r;
	return p;
}
int32_t hxc_NativeUv_setPriority(int32_t pid, int32_t p) { return uv_os_setpriority(pid, p); }

// 18 int64: utime sec usec, stime sec usec, maxrss ixrss idrss isrss minflt majflt nswap inblock oublock msgsnd msgrcv nsignals nvcsw nivcsw
int32_t hxc_NativeUv_getRUsage(void *out) {
	uv_rusage_t u;
	int r = uv_getrusage(&u);
	if (r < 0) return r;
	int64_t v[18] = {u.ru_utime.tv_sec, u.ru_utime.tv_usec, u.ru_stime.tv_sec, u.ru_stime.tv_usec, (int64_t)u.ru_maxrss, (int64_t)u.ru_ixrss,
		(int64_t)u.ru_idrss, (int64_t)u.ru_isrss, (int64_t)u.ru_minflt, (int64_t)u.ru_majflt, (int64_t)u.ru_nswap, (int64_t)u.ru_inblock,
		(int64_t)u.ru_oublock, (int64_t)u.ru_msgsnd, (int64_t)u.ru_msgrcv, (int64_t)u.ru_nsignals, (int64_t)u.ru_nvcsw, (int64_t)u.ru_nivcsw};
	for (int i = 0; i < 18; i++) put64(BYTES_DATA(out), i, v[i]);
	return 0;
}

// per cpu: model (String), speed, then times user nice sys idle irq in a Bytes (5 int64); null on failure
void *hxc_NativeUv_cpuInfo(void) {
	uv_cpu_info_t *c;
	int count;
	int r = uv_cpu_info(&c, &count);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	void *arr = hx_arr_new(AK_PTR, 3 * count);
	RT_ROOT(arr);
	for (int i = 0; i < count; i++) {
		void *x = str_of_c(c[i].model);
		set_elem(arr_root, 3 * i, x);
		x = hx_box_int(c[i].speed);
		set_elem(arr_root, 3 * i + 1, x);
		x = haxe_io_Bytes_alloc(40);
		int64_t t[5] = {(int64_t)c[i].cpu_times.user, (int64_t)c[i].cpu_times.nice, (int64_t)c[i].cpu_times.sys, (int64_t)c[i].cpu_times.idle,
			(int64_t)c[i].cpu_times.irq};
		for (int k = 0; k < 5; k++) put64(BYTES_DATA(x), k, t[k]);
		set_elem(arr_root, 3 * i + 2, x);
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	uv_free_cpu_info(c, count);
	return arr;
}

// [sysname, release, version, machine]; null on failure
void *hxc_NativeUv_uname(void) {
	uv_utsname_t u;
	int r = uv_os_uname(&u);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	const char *s[4] = {u.sysname, u.release, u.version, u.machine};
	void *arr = hx_arr_new(AK_PTR, 4);
	RT_ROOT(arr);
	for (int i = 0; i < 4; i++) {
		void *x = str_of_c(s[i]);
		set_elem(arr_root, i, x);
	}
	RT_RELOAD(arr);
	RT_UNROOT(1);
	return arr;
}

int32_t hxc_NativeUv_getPid(void) { return uv_os_getpid(); }
int32_t hxc_NativeUv_getPPid(void) { return uv_os_getppid(); }

// [username, uid, gid, shell or null, homedir (Bytes)]; null on failure
void *hxc_NativeUv_getPasswd(void) {
	uv_passwd_t p;
	int r = uv_os_get_passwd(&p);
	if (r < 0) {
		last_err = r;
		return NULL;
	}
	void *arr = hx_arr_new(AK_PTR, 5);
	RT_ROOT(arr);
	void *x = str_of_c(p.username);
	set_elem(arr_root, 0, x);
	x = hx_box_int((int32_t)p.uid);
	set_elem(arr_root, 1, x);
	x = hx_box_int((int32_t)p.gid);
	set_elem(arr_root, 2, x);
	if (p.shell) {
		x = str_of_c(p.shell);
		set_elem(arr_root, 3, x);
	}
	x = bytes_of_c(p.homedir);
	set_elem(arr_root, 4, x);
	RT_RELOAD(arr);
	RT_UNROOT(1);
	uv_os_free_passwd(&p);
	return arr;
}

#endif
