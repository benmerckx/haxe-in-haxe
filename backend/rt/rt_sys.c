// EXPERIMENTAL runtime for the C output of backend/: operating-system
// primitives behind hxc.NativeSys (backend/std-hxc/hxc/NativeSys.hx). POSIX.
#define _GNU_SOURCE
#include "rt.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

extern int rt_argc;
extern char **rt_argv;
extern char **environ;

#define BYTES_LEN(b) (((int32_t *)(b))[0])
#define BYTES_DATA(b) ((unsigned char *)(b) + 8)
void *haxe_io_Bytes_alloc(int32_t len);

static void write_all(int fd, const char *p, size_t n) {
	while (n > 0) {
		ssize_t w = write(fd, p, n);
		if (w < 0) {
			if (errno == EINTR) continue;
			return;
		}
		p += w;
		n -= (size_t)w;
	}
}

static void print_to(int fd, void *s) {
	char *u = hx_str_to_utf8(hx_str_or_null(s));
	write_all(fd, u, strlen(u));
	free(u);
}

void hxc_NativeSys_print(void *s) { print_to(1, s); }
void hxc_NativeSys_printErr(void *s) { print_to(2, s); }

static void *str_of_c(const char *s) { return hx_str_of_utf8(s, (int32_t)strlen(s)); }

// an Array<String> of n C strings
static void *str_array(char **v, int32_t n) {
	void *a = hx_arr_new(AK_PTR, n);
	RT_ROOT(a);
	for (int32_t i = 0; i < n; i++) {
		void *s = str_of_c(v[i]);
		RT_RELOAD(a);
		rt_set_ptr(ARR_DATA(a), &FP(ARR_DATA(a), i), s);
	}
	RT_RELOAD(a);
	RT_UNROOT(1);
	return a;
}

void *hxc_NativeSys_args(void) { return str_array(rt_argv + 1, rt_argc > 0 ? rt_argc - 1 : 0); }

void *hxc_NativeSys_getEnv(void *s) {
	char *n = hx_str_to_utf8(s);
	char *v = getenv(n);
	free(n);
	return v ? str_of_c(v) : NULL;
}

void hxc_NativeSys_putEnv(void *s, void *v) {
	char *n = hx_str_to_utf8(s);
	if (v) {
		char *u = hx_str_to_utf8(v);
		setenv(n, u, 1);
		free(u);
	} else
		unsetenv(n);
	free(n);
}

void *hxc_NativeSys_environ(void) {
	int32_t n = 0;
	while (environ[n]) n++;
	return str_array(environ, n);
}

// Green threads (rt_thread.c): while other threads exist, sleeping and
// waiting for a pipe, terminal or child process let them run; regular files
// are always ready. Writes to stdout/stderr (print), Sys.command and the
// rest of the file system calls still block the process.
void hxc_NativeSys_sleep(double seconds) {
	if (RT_NTHREADS() > 1) {
		rt_sleep(seconds); // 0: give way to the other runnable threads
		return;
	}
	if (seconds <= 0) return;
	struct timespec t;
	t.tv_sec = (time_t)seconds;
	t.tv_nsec = (long)((seconds - (double)t.tv_sec) * 1e9);
	while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
}

void *hxc_NativeSys_getCwd(void) {
	char buf[PATH_MAX + 2];
	if (!getcwd(buf, PATH_MAX)) hx_throw_str("getCwd failed");
	size_t n = strlen(buf);
	if (n == 0 || buf[n - 1] != '/') {
		buf[n] = '/';
		buf[n + 1] = 0;
	}
	return str_of_c(buf);
}

int32_t hxc_NativeSys_setCwd(void *s) {
	char *n = hx_str_to_utf8(s);
	int r = chdir(n);
	free(n);
	return r == 0;
}

void *hxc_NativeSys_systemName(void) {
#if defined(__APPLE__)
	return hx_str_of_ascii("Mac");
#elif defined(_WIN32)
	return hx_str_of_ascii("Windows");
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
	return hx_str_of_ascii("BSD");
#else
	return hx_str_of_ascii("Linux");
#endif
}

int32_t hxc_NativeSys_command(void *cmd) {
	char *c = hx_str_to_utf8(cmd);
	fflush(stdout);
	int r;
	RT_BLOCKING(r = system(c)); // c is malloc'ed: no heap pointer
	free(c);
	if (r == -1) return -1;
	return WIFEXITED(r) ? WEXITSTATUS(r) : 128 + WTERMSIG(r);
}

void hxc_NativeSys_exit(int32_t code) {
	fflush(stdout);
	fflush(stderr);
	exit(code);
}

double hxc_NativeSys_time(void) {
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

double hxc_NativeSys_cpuTime(void) { return (double)clock() / CLOCKS_PER_SEC; }

void *hxc_NativeSys_programPath(void) {
	char buf[PATH_MAX + 1];
	ssize_t n = readlink("/proc/self/exe", buf, PATH_MAX);
	if (n > 0) {
		buf[n] = 0;
		return str_of_c(buf);
	}
	if (rt_argc > 0) {
		char *r = realpath(rt_argv[0], NULL);
		if (r) {
			void *s = str_of_c(r);
			free(r);
			return s;
		}
		return str_of_c(rt_argv[0]);
	}
	return hx_str_of_ascii("");
}

int32_t hxc_NativeSys_getChar(int32_t echo) {
	struct termios old, raw;
	int tty = isatty(0) && tcgetattr(0, &old) == 0;
	if (tty) {
		raw = old;
		raw.c_lflag &= ~(ICANON | (echo ? 0 : ECHO));
		tcsetattr(0, TCSANOW, &raw);
	}
	unsigned char c;
	if (RT_NTHREADS() > 1) rt_wait_fd(0, 0, -1);
	ssize_t r = read(0, &c, 1);
	if (tty) tcsetattr(0, TCSANOW, &old);
	if (r <= 0) hx_throw_str("Eof");
	return c;
}

// ---- files

int32_t hxc_NativeSys_fileOpen(void *path, int32_t mode) {
	static const int flags[] = {O_RDONLY, O_WRONLY | O_CREAT | O_TRUNC, O_WRONLY | O_CREAT | O_APPEND, O_RDWR | O_CREAT};
	if (mode < 0 || mode > 3) return -1;
	char *p = hx_str_to_utf8(path);
	int fd = open(p, flags[mode] | O_CLOEXEC, 0666);
	free(p);
	return fd;
}

int32_t hxc_NativeSys_fileRead(int32_t fd, void *b, int32_t pos, int32_t len) {
	if (pos < 0 || len < 0 || pos + len > BYTES_LEN(b)) hx_throw_str("OutsideBounds");
	if (RT_NTHREADS() > 1) {
		RT_ROOT(b);
		int w = rt_wait_fd(fd, 0, -1);
		RT_RELOAD(b);
		RT_UNROOT(1);
		if (w < 0) return -1; // closed while waiting
	}
	for (;;) {
		ssize_t r = read(fd, BYTES_DATA(b) + pos, (size_t)len);
		if (r < 0 && errno == EINTR) continue;
		return (int32_t)r;
	}
}

int32_t hxc_NativeSys_fileWrite(int32_t fd, void *b, int32_t pos, int32_t len) {
	if (pos < 0 || len < 0 || pos + len > BYTES_LEN(b)) hx_throw_str("OutsideBounds");
	if (RT_NTHREADS() > 1) {
		RT_ROOT(b);
		int w = rt_wait_fd(fd, 1, -1);
		RT_RELOAD(b);
		RT_UNROOT(1);
		if (w < 0) return -1;
	}
	for (;;) {
		ssize_t r = write(fd, BYTES_DATA(b) + pos, (size_t)len);
		if (r < 0 && errno == EINTR) continue;
		return (int32_t)r;
	}
}

void hxc_NativeSys_fileClose(int32_t fd) {
	rt_fd_closed(fd);
	close(fd);
}

void hxc_NativeSys_fileSeek(int32_t fd, int32_t p, int32_t whence) {
	static const int w[] = {SEEK_SET, SEEK_CUR, SEEK_END};
	if (lseek(fd, p, w[whence < 0 || whence > 2 ? 0 : whence]) < 0) hx_throw_str("seek failed");
}

int32_t hxc_NativeSys_fileTell(int32_t fd) { return (int32_t)lseek(fd, 0, SEEK_CUR); }

void *hxc_NativeSys_fileContent(void *path) {
	char *p = hx_str_to_utf8(path);
	int fd = open(p, O_RDONLY | O_CLOEXEC);
	free(p);
	if (fd < 0) return NULL;
	// read into malloc'ed memory first: the size may not be known (pipes)
	size_t cap = 65536, n = 0;
	struct stat st;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) cap = (size_t)st.st_size + 1;
	char *buf = (char *)malloc(cap);
	for (;;) {
		if (n == cap) buf = (char *)realloc(buf, cap *= 2);
		ssize_t r = read(fd, buf + n, cap - n);
		if (r < 0 && errno == EINTR) continue;
		if (r < 0) {
			free(buf);
			close(fd);
			return NULL;
		}
		if (r == 0) break;
		n += (size_t)r;
	}
	close(fd);
	void *b = haxe_io_Bytes_alloc((int32_t)n);
	memcpy(BYTES_DATA(b), buf, n);
	free(buf);
	return b;
}

int32_t hxc_NativeSys_fileSave(void *path, void *b, int32_t append) {
	char *p = hx_str_to_utf8(path);
	int fd = open(p, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0666);
	free(p);
	if (fd < 0) return 0;
	const char *d = (const char *)BYTES_DATA(b);
	size_t n = (size_t)BYTES_LEN(b);
	int ok = 1;
	while (n > 0) {
		ssize_t w = write(fd, d, n);
		if (w < 0) {
			if (errno == EINTR) continue;
			ok = 0;
			break;
		}
		d += w;
		n -= (size_t)w;
	}
	return close(fd) == 0 && ok;
}

static int path_op(void *path, int (*f)(const char *)) {
	char *p = hx_str_to_utf8(path);
	int r = f(p);
	free(p);
	return r;
}
static int op_exists(const char *p) {
	struct stat st;
	return stat(p, &st) == 0;
}
static int op_isdir(const char *p) {
	struct stat st;
	return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}
static int op_mkdir(const char *p) { return mkdir(p, 0777) == 0; }
static int op_unlink(const char *p) { return unlink(p) == 0; }
static int op_rmdir(const char *p) { return rmdir(p) == 0; }

int32_t hxc_NativeSys_exists(void *path) { return path_op(path, op_exists); }
int32_t hxc_NativeSys_isDirectory(void *path) { return path_op(path, op_isdir); }
int32_t hxc_NativeSys_createDirectory(void *path) { return path_op(path, op_mkdir); }
int32_t hxc_NativeSys_deleteFile(void *path) { return path_op(path, op_unlink); }
int32_t hxc_NativeSys_deleteDirectory(void *path) { return path_op(path, op_rmdir); }

int32_t hxc_NativeSys_rename(void *path, void *newPath) {
	char *a = hx_str_to_utf8(path), *b = hx_str_to_utf8(newPath);
	int r = rename(a, b);
	free(a);
	free(b);
	return r == 0;
}

void *hxc_NativeSys_readDirectory(void *path) {
	char *p = hx_str_to_utf8(path);
	DIR *d = opendir(p);
	free(p);
	if (!d) return NULL;
	int32_t n = 0, cap = 16;
	char **names = (char **)malloc(sizeof(char *) * cap);
	struct dirent *e;
	while ((e = readdir(d))) {
		if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
		if (n == cap) names = (char **)realloc(names, sizeof(char *) * (cap *= 2));
		names[n++] = strdup(e->d_name);
	}
	closedir(d);
	void *a = str_array(names, n);
	for (int32_t i = 0; i < n; i++) free(names[i]);
	free(names);
	return a;
}

void *hxc_NativeSys_fullPath(void *path) {
	char *p = hx_str_to_utf8(path);
	char *r = realpath(p, NULL);
	free(p);
	if (!r) return NULL;
	void *s = str_of_c(r);
	free(r);
	return s;
}

void *hxc_NativeSys_stat(void *path) {
	char *p = hx_str_to_utf8(path);
	struct stat st;
	int r = stat(p, &st);
	free(p);
	if (r != 0) return NULL;
	double v[11] = {(double)st.st_gid, (double)st.st_uid, (double)st.st_atime, (double)st.st_mtime, (double)st.st_ctime, (double)st.st_dev,
		(double)st.st_ino, (double)st.st_nlink, (double)st.st_rdev, (double)st.st_size, (double)st.st_mode};
	void *a = hx_arr_new(AK_F64, 11);
	memcpy(ARR_DATA(a), v, sizeof v);
	return a;
}

// ---- processes

int32_t hxc_NativeSys_processRun(void *cmd, void *args, void *fds) {
	// argv in malloc'ed C strings before forking
	int32_t n = args ? ARR_LEN(args) : 0;
	char **argv = (char **)malloc(sizeof(char *) * (n + 4));
	if (args) {
		argv[0] = hx_str_to_utf8(cmd);
		for (int32_t i = 0; i < n; i++) argv[i + 1] = hx_str_to_utf8(hx_aget_p_slow(args, i));
		argv[n + 1] = NULL;
	} else {
		argv[0] = strdup("/bin/sh");
		argv[1] = strdup("-c");
		argv[2] = hx_str_to_utf8(cmd);
		argv[3] = NULL;
		n = 2;
	}
	int pin[2], pout[2], perr[2];
	if (pipe(pin) || pipe(pout) || pipe(perr)) hx_throw_str("Process creation failure");
	fflush(stdout);
	fflush(stderr);
	pid_t pid = fork();
	if (pid == 0) {
		dup2(pin[0], 0);
		dup2(pout[1], 1);
		dup2(perr[1], 2);
		close(pin[0]), close(pin[1]), close(pout[0]), close(pout[1]), close(perr[0]), close(perr[1]);
		execvp(argv[0], argv);
		_exit(127);
	}
	close(pin[0]), close(pout[1]), close(perr[1]);
	for (int32_t i = 0; i <= n; i++) free(argv[i]);
	free(argv);
	if (pid < 0) {
		close(pin[1]), close(pout[0]), close(perr[0]);
		hx_throw_str("Process creation failure");
	}
	fcntl(pin[1], F_SETFD, FD_CLOEXEC);
	fcntl(pout[0], F_SETFD, FD_CLOEXEC);
	fcntl(perr[0], F_SETFD, FD_CLOEXEC);
	int32_t v[3] = {pin[1], pout[0], perr[0]};
	RT_ROOT(fds); // the slot hx_aset_slow may grow through
	for (int i = 0; i < 3; i++) hx_aset_slow(fds_root, i, AK_I32, (uint64_t)(uint32_t)v[i]);
	RT_UNROOT(1);
	return pid;
}

int32_t hxc_NativeSys_processWait(int32_t pid, int32_t block) {
	int st;
#if RT_MT
	// OS threads: wait in a safe region
	for (;;) {
		pid_t r;
		RT_BLOCKING(r = waitpid(pid, &st, block ? 0 : WNOHANG));
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) return -1;
		break;
	}
#else
	double pause = 0.001;
	for (;;) {
		int coop = block && RT_NTHREADS() > 1; // green threads: poll the child, sleeping in between
		pid_t r = waitpid(pid, &st, block && !coop ? 0 : WNOHANG);
		if (r < 0 && errno == EINTR) continue;
		if (r == 0 && coop) {
			rt_sleep(pause);
			if (pause < 0.02) pause *= 2;
			continue;
		}
		if (r == 0) return -1;
		if (r < 0) return -1;
		break;
	}
#endif
	if (WIFEXITED(st)) return WEXITSTATUS(st);
	if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
	return -1;
}

void hxc_NativeSys_processKill(int32_t pid) { kill(pid, SIGKILL); }
