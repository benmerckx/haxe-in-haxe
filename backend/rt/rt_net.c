// EXPERIMENTAL runtime for the C output of backend/: BSD sockets behind
// hxc.NativeNet (backend/std-hxc/hxc/NativeNet.hx), standing for the OCaml
// Unix functions the Eval natives of eval.vm.NativeSocket and sys.net.Host
// call upstream (haxe/src/macro/eval/evalStdLib.ml StdSocket, StdHost).
// -DHXC_NO_NET builds stubs that fail (targets without BSD sockets).
#define _GNU_SOURCE
#include "rt.h"
#include <errno.h>
#include <stdlib.h>

#define BYTES_LEN(b) (((int32_t *)(b))[0])
#define BYTES_DATA(b) ((unsigned char *)(b) + 8)

#ifdef HXC_NO_NET

static int32_t no_net(void) { hx_throw_str("sockets are not supported in this build of haxe-in-haxe"); }
int32_t hxc_NativeNet_errno(void) { return 0; }
void *hxc_NativeNet_strerror(int32_t err) { return hx_str_of_ascii("sockets are not supported in this build"); }
int32_t hxc_NativeNet_socket(void) { return no_net(); }
int32_t hxc_NativeNet_close(int32_t fd) { return no_net(); }
int32_t hxc_NativeNet_accept(int32_t fd) { return no_net(); }
int32_t hxc_NativeNet_bind(int32_t fd, int32_t ip, int32_t port) { return no_net(); }
int32_t hxc_NativeNet_connect(int32_t fd, int32_t ip, int32_t port) { return no_net(); }
int32_t hxc_NativeNet_listen(int32_t fd, int32_t n) { return no_net(); }
void *hxc_NativeNet_sockName(int32_t fd, int32_t peer) { no_net(); return NULL; }
int32_t hxc_NativeNet_recv(int32_t fd, void *b, int32_t pos, int32_t len) { return no_net(); }
int32_t hxc_NativeNet_send(int32_t fd, void *b, int32_t pos, int32_t len) { return no_net(); }
int32_t hxc_NativeNet_select(void *r, void *w, void *o, double t) { return no_net(); }
int32_t hxc_NativeNet_setNoDelay(int32_t fd, int32_t b) { return no_net(); }
int32_t hxc_NativeNet_setBroadcast(int32_t fd, int32_t b) { return no_net(); }
int32_t hxc_NativeNet_setReuseAddr(int32_t fd, int32_t b) { return no_net(); }
int32_t hxc_NativeNet_setTimeout(int32_t fd, double t) { return no_net(); }
int32_t hxc_NativeNet_shutdown(int32_t fd, int32_t mode) { return no_net(); }
int32_t hxc_NativeNet_setBlocking(int32_t fd, int32_t b) { return no_net(); }
int32_t hxc_NativeNet_blocked(void) { return 0; }
void *hxc_NativeNet_gethostname(void) { no_net(); return NULL; }
void *hxc_NativeNet_resolve(void *name) { no_net(); return NULL; }
void *hxc_NativeNet_reverse(int32_t ip) { no_net(); return NULL; }

#else

#include <arpa/inet.h>
#include <poll.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static RT_TLS int last_errno; // per thread, as errno

static int32_t ret(int r) {
	if (r < 0) last_errno = errno;
	return r;
}

int32_t hxc_NativeNet_errno(void) { return last_errno; }

// Green threads (rt_thread.c): while other threads exist, a blocking call on a
// socket in blocking mode must not block the process. The call is made
// without blocking (MSG_DONTWAIT, a poll first, or a non-blocking connect)
// and the thread waits for the descriptor in the scheduler. Sockets the
// program made non-blocking keep failing with EAGAIN (haxe.io.Error.Blocked).
static int cooperative(int fd) {
	if (RT_NTHREADS() <= 1) return 0;
	int flags = fcntl(fd, F_GETFL);
	return flags >= 0 && !(flags & O_NONBLOCK);
}

// SO_RCVTIMEO/SO_SNDTIMEO (setTimeout): seconds, -1 when none
static double sock_timeout(int fd, int opt) {
	struct timeval tv;
	socklen_t n = sizeof tv;
	if (getsockopt(fd, SOL_SOCKET, opt, &tv, &n) < 0 || (tv.tv_sec == 0 && tv.tv_usec == 0)) return -1;
	return (double)tv.tv_sec + (double)tv.tv_usec * 1e-6;
}

// waits for fd as a blocking call would (with the socket's timeout): 0 when the
// wait failed, errno set as the blocking call would have (EAGAIN: timeout)
static int wait_sock(int fd, int write) {
	int r = rt_wait_fd(fd, write, sock_timeout(fd, write ? SO_SNDTIMEO : SO_RCVTIMEO));
	if (r > 0) return 1;
	errno = r == 0 ? EAGAIN : EBADF;
	return 0;
}

void *hxc_NativeNet_strerror(int32_t err) {
	const char *s = strerror(err);
	return hx_str_of_utf8(s, (int32_t)strlen(s));
}

int32_t hxc_NativeNet_socket(void) {
	// haxe/src/compiler/haxe.ml ignores SIGPIPE for the whole process; the
	// port's entry point does not, so the first socket does it
	static int sigpipe_ignored;
	if (!sigpipe_ignored) {
		signal(SIGPIPE, SIG_IGN);
		sigpipe_ignored = 1;
	}
	return ret(socket(PF_INET, SOCK_STREAM, 0));
}

int32_t hxc_NativeNet_close(int32_t fd) {
	rt_fd_closed(fd);
	return ret(close(fd));
}

int32_t hxc_NativeNet_accept(int32_t fd) {
	struct sockaddr_storage a;
	socklen_t n = sizeof a;
	if (cooperative(fd) && !wait_sock(fd, 0)) return ret(-1);
	return ret(accept(fd, (struct sockaddr *)&a, &n));
}

static struct sockaddr_in inet_addr_of(int32_t ip, int32_t port) {
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl((uint32_t)ip);
	a.sin_port = htons((uint16_t)port);
	return a;
}

int32_t hxc_NativeNet_bind(int32_t fd, int32_t ip, int32_t port) {
	struct sockaddr_in a = inet_addr_of(ip, port);
	return ret(bind(fd, (struct sockaddr *)&a, sizeof a));
}

int32_t hxc_NativeNet_connect(int32_t fd, int32_t ip, int32_t port) {
	struct sockaddr_in a = inet_addr_of(ip, port);
	if (cooperative(fd)) { // a non-blocking connect, then wait until it completes
		int flags = fcntl(fd, F_GETFL);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
		int r = connect(fd, (struct sockaddr *)&a, sizeof a);
		if (r < 0 && errno == EINPROGRESS) {
			if (wait_sock(fd, 1)) {
				int err = 0;
				socklen_t n = sizeof err;
				getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &n);
				r = err ? -1 : 0;
				errno = err;
			} else r = -1;
		}
		int e = errno;
		fcntl(fd, F_SETFL, flags);
		errno = e;
		return ret(r);
	}
	return ret(connect(fd, (struct sockaddr *)&a, sizeof a));
}

int32_t hxc_NativeNet_listen(int32_t fd, int32_t n) { return ret(listen(fd, n)); }

void *hxc_NativeNet_sockName(int32_t fd, int32_t peer) {
	struct sockaddr_storage s;
	socklen_t n = sizeof s;
	int r = peer ? getpeername(fd, (struct sockaddr *)&s, &n) : getsockname(fd, (struct sockaddr *)&s, &n);
	if (r < 0) {
		last_errno = errno;
		return NULL;
	}
	void *a = hx_arr_new(AK_I32, 2);
	if (s.ss_family == AF_INET) {
		struct sockaddr_in *i = (struct sockaddr_in *)&s;
		((int32_t *)ARR_DATA(a))[0] = (int32_t)ntohl(i->sin_addr.s_addr);
		((int32_t *)ARR_DATA(a))[1] = ntohs(i->sin_port);
	} else {
		((int32_t *)ARR_DATA(a))[0] = 0;
		((int32_t *)ARR_DATA(a))[1] = -1;
	}
	return a;
}

// OCaml's Unix.recv/send check the range (Invalid_argument "Unix.recv")
int32_t hxc_NativeNet_recv(int32_t fd, void *b, int32_t pos, int32_t len) {
	if (pos < 0 || len < 0 || pos > BYTES_LEN(b) - len) hx_throw_str("Unix.recv");
	if (cooperative(fd)) {
		RT_ROOT(b); // the wait lets other threads run (and collect)
		ssize_t r;
		while ((r = recv(fd, BYTES_DATA(*b_root) + pos, (size_t)len, MSG_DONTWAIT)) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
			if (errno != EINTR && !wait_sock(fd, 0)) break;
		RT_UNROOT(1);
		return ret((int)r);
	}
	return ret((int)recv(fd, BYTES_DATA(b) + pos, (size_t)len, 0));
}

int32_t hxc_NativeNet_send(int32_t fd, void *b, int32_t pos, int32_t len) {
	if (pos < 0 || len < 0 || pos > BYTES_LEN(b) - len) hx_throw_str("Unix.send");
	if (cooperative(fd)) { // may send part of the buffer, as a signal-interrupted send does
		RT_ROOT(b);
		ssize_t r;
		while ((r = send(fd, BYTES_DATA(*b_root) + pos, (size_t)len, MSG_DONTWAIT)) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
			if (errno != EINTR && !wait_sock(fd, 1)) break;
		RT_UNROOT(1);
		return ret((int)r);
	}
	return ret((int)send(fd, BYTES_DATA(b) + pos, (size_t)len, 0));
}

static int to_fdset(void *a, fd_set *s, int *maxfd) {
	FD_ZERO(s);
	int32_t n = a ? ARR_LEN(a) : 0;
	for (int32_t i = 0; i < n; i++) {
		int32_t fd = hx_aget_i_slow(a, i);
		if (fd < 0 || fd >= FD_SETSIZE) return -1;
		FD_SET(fd, s);
		if (fd > *maxfd) *maxfd = fd;
	}
	return 0;
}

static void from_fdset(void **slot, fd_set *s) {
	int32_t n = *slot ? ARR_LEN(*slot) : 0;
	for (int32_t i = 0; i < n; i++) {
		int32_t fd = hx_aget_i_slow(*slot, i);
		if (!FD_ISSET(fd, s)) hx_aset_slow(slot, i, AK_I32, (uint64_t)(uint32_t)-1);
	}
}

// Unix.select (otherlib/unix/select_unix.c): a negative timeout waits forever
int32_t hxc_NativeNet_select(void *r, void *w, void *o, double timeout) {
	fd_set rs, ws, os;
	int maxfd = -1;
	if (to_fdset(r, &rs, &maxfd) || to_fdset(w, &ws, &maxfd) || to_fdset(o, &os, &maxfd)) {
		last_errno = EINVAL;
		return -1;
	}
	struct timeval tv, *tvp = NULL;
	if (RT_NTHREADS() > 1 && timeout != 0) {
		// other threads run until a descriptor is ready or the timeout passes,
		// then select looks without waiting
		int32_t nr = r ? ARR_LEN(r) : 0, nw = w ? ARR_LEN(w) : 0, no = o ? ARR_LEN(o) : 0;
		struct pollfd *p = (struct pollfd *)malloc((nr + nw + no + 1) * sizeof(struct pollfd));
		int k = 0;
		for (int32_t i = 0; i < nr; i++, k++) p[k].fd = hx_aget_i_slow(r, i), p[k].events = POLLIN;
		for (int32_t i = 0; i < nw; i++, k++) p[k].fd = hx_aget_i_slow(w, i), p[k].events = POLLOUT;
		for (int32_t i = 0; i < no; i++, k++) p[k].fd = hx_aget_i_slow(o, i), p[k].events = POLLPRI;
		RT_ROOT(r);
		RT_ROOT(w);
		RT_ROOT(o);
		rt_wait_fds(p, k, timeout);
		RT_RELOAD(r);
		RT_RELOAD(w);
		RT_RELOAD(o);
		RT_UNROOT(3);
		free(p);
		if (to_fdset(r, &rs, &maxfd) || to_fdset(w, &ws, &maxfd) || to_fdset(o, &os, &maxfd)) {
			last_errno = EBADF;
			return -1;
		}
		timeout = 0;
	}
	if (timeout >= 0) {
		tv.tv_sec = (long)timeout;
		tv.tv_usec = (long)(1e6 * (timeout - (double)tv.tv_sec));
		tvp = &tv;
	}
	int n = select(maxfd + 1, &rs, &ws, &os, tvp);
	if (n < 0) {
		last_errno = errno;
		return -1;
	}
	RT_ROOT(r);
	RT_ROOT(w);
	RT_ROOT(o);
	from_fdset(r_root, &rs);
	from_fdset(w_root, &ws);
	from_fdset(o_root, &os);
	RT_UNROOT(3);
	return n;
}

static int32_t set_bool(int fd, int level, int opt, int32_t b) {
	int v = b ? 1 : 0;
	return ret(setsockopt(fd, level, opt, &v, sizeof v));
}

int32_t hxc_NativeNet_setNoDelay(int32_t fd, int32_t b) { return set_bool(fd, IPPROTO_TCP, TCP_NODELAY, b); }
int32_t hxc_NativeNet_setBroadcast(int32_t fd, int32_t b) { return set_bool(fd, SOL_SOCKET, SO_BROADCAST, b); }
int32_t hxc_NativeNet_setReuseAddr(int32_t fd, int32_t b) { return set_bool(fd, SOL_SOCKET, SO_REUSEADDR, b); }

// Unix.setsockopt_float SO_RCVTIMEO, then SO_SNDTIMEO
int32_t hxc_NativeNet_setTimeout(int32_t fd, double t) {
	struct timeval tv;
	tv.tv_sec = (time_t)t;
	tv.tv_usec = (suseconds_t)((t - (double)tv.tv_sec) * 1e6);
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0) return ret(-1);
	return ret(setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv));
}

int32_t hxc_NativeNet_shutdown(int32_t fd, int32_t mode) {
	int how = mode == 0 ? SHUT_RD : mode == 1 ? SHUT_WR : SHUT_RDWR;
	return ret(shutdown(fd, how));
}

// for sys.net.Socket.setBlocking (hxc std; the Eval socket natives are blocking)
int32_t hxc_NativeNet_setBlocking(int32_t fd, int32_t b) {
	int flags = fcntl(fd, F_GETFL);
	if (flags < 0) return ret(-1);
	return ret(fcntl(fd, F_SETFL, b ? flags & ~O_NONBLOCK : flags | O_NONBLOCK));
}

// whether the last failure was EAGAIN/EWOULDBLOCK (a non-blocking socket not ready)
int32_t hxc_NativeNet_blocked(void) { return last_errno == EAGAIN || last_errno == EWOULDBLOCK; }

void *hxc_NativeNet_gethostname(void) {
	char buf[4096];
	if (gethostname(buf, sizeof buf - 1) < 0) {
		last_errno = errno;
		return NULL;
	}
	buf[sizeof buf - 1] = 0;
	return hx_str_of_utf8(buf, (int32_t)strlen(buf));
}

// gethostbyname/gethostbyaddr return static data: one thread at a time, in a
// safe region (they may block on the network), results copied out under the lock
static rt_lock_t resolver_lock = RT_LOCK_INIT;

void *hxc_NativeNet_resolve(void *name) {
	char *n = hx_str_to_utf8(name);
	uint32_t ip;
	int found = 0;
	rt_blocking_enter();
	rt_lock(&resolver_lock);
	struct hostent *h = gethostbyname(n);
	if (h && h->h_addrtype == AF_INET && h->h_addr_list[0]) {
		memcpy(&ip, h->h_addr_list[0], 4);
		found = 1;
	}
	rt_unlock(&resolver_lock);
	rt_blocking_leave();
	free(n);
	last_errno = 0;
	if (!found) return NULL;
	void *a = hx_arr_new(AK_I32, 1);
	((int32_t *)ARR_DATA(a))[0] = (int32_t)ntohl(ip);
	return a;
}

void *hxc_NativeNet_reverse(int32_t ip) {
	uint32_t a = htonl((uint32_t)ip);
	char *name = NULL;
	rt_blocking_enter();
	rt_lock(&resolver_lock);
	struct hostent *h = gethostbyaddr(&a, 4, AF_INET);
	if (h && h->h_name) name = strdup(h->h_name);
	rt_unlock(&resolver_lock);
	rt_blocking_leave();
	last_errno = 0;
	if (!name) return NULL;
	void *s = hx_str_of_utf8(name, (int32_t)strlen(name));
	free(name);
	return s;
}

#endif
