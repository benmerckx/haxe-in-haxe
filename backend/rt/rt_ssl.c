// EXPERIMENTAL runtime for the C output of backend/: mbedtls behind
// hxc.NativeSsl (backend/std-hxc/hxc/NativeSsl.hx), mirroring the OCaml
// bindings haxe/libs/mbedtls/mbedtls_stubs.c used by
// haxe/src/macro/eval/evalSsl.ml.
//
// Contexts are T_NATIVE objects whose slot 0 holds the malloc'ed mbedtls
// context. The runtime has no finalizers, so contexts are never freed
// (upstream frees them from OCaml custom-block finalizers).
//
// Deviation: upstream's BIO callbacks call OCaml's Unix.send/Unix.recv, whose
// Unix_error escapes through mbedtls. Here the BIO is C send/recv on the
// socket descriptor; on failure it records errno and returns
// MBEDTLS_ERR_NET_SEND_FAILED/RECV_FAILED, and the port raises the Unix error
// after the call (hxc_NativeSsl_bioError).
//
// -DHXC_NO_SSL builds stubs that fail (builds without libmbedtls).
#define _GNU_SOURCE
#include "rt.h"
#include <stdlib.h>

#define BYTES_LEN(b) (((int32_t *)(b))[0])
#define BYTES_DATA(b) ((unsigned char *)(b) + 8)

#ifdef HXC_NO_SSL

static int32_t no_ssl(void) { hx_throw_str("mbedtls is not supported in this build of haxe-in-haxe"); }
#define NO_P { no_ssl(); return NULL; }
#define NO_I { return no_ssl(); }
#define NO_V { no_ssl(); }
#define NO_F { no_ssl(); return 0; }
void *hxc_NativeSsl_strerror(int32_t code) NO_P
void *hxc_NativeSsl_ctrDrbgInit(void) NO_P
int32_t hxc_NativeSsl_ctrDrbgRandom(void *ctx, void *out, int32_t len) NO_I
int32_t hxc_NativeSsl_ctrDrbgSeed(void *ctx, void *entropy) NO_I
void *hxc_NativeSsl_entropyInit(void) NO_P
void *hxc_NativeSsl_x509CrtInit(void) NO_P
void *hxc_NativeSsl_x509Next(void *crt) NO_P
int32_t hxc_NativeSsl_x509CrtParse(void *crt, void *b) NO_I
int32_t hxc_NativeSsl_x509CrtParseFile(void *crt, void *path) NO_I
int32_t hxc_NativeSsl_x509CrtParsePath(void *crt, void *path) NO_I
void *hxc_NativeSsl_certAltNames(void *crt) NO_P
void *hxc_NativeSsl_certIssuer(void *crt, void *name) NO_P
void *hxc_NativeSsl_certSubject(void *crt, void *name) NO_P
double hxc_NativeSsl_certNotAfter(void *crt) NO_F
double hxc_NativeSsl_certNotBefore(void *crt) NO_F
int32_t hxc_NativeSsl_certLoadDefaults(void *crt) NO_I
void *hxc_NativeSsl_configInit(void) NO_P
void hxc_NativeSsl_confAuthmode(void *conf, int32_t mode) NO_V
void hxc_NativeSsl_confCaChain(void *conf, void *crt) NO_V
int32_t hxc_NativeSsl_configDefaults(void *conf, int32_t e, int32_t t, int32_t p) NO_I
void hxc_NativeSsl_confRng(void *conf, void *ctr) NO_V
void *hxc_NativeSsl_pkInit(void) NO_P
int32_t hxc_NativeSsl_pkParseKey(void *pk, void *key, void *pwd, void *rng) NO_I
int32_t hxc_NativeSsl_pkParseKeyfile(void *pk, void *path, void *pwd, void *rng) NO_I
int32_t hxc_NativeSsl_pkParsePublicKey(void *pk, void *key) NO_I
int32_t hxc_NativeSsl_pkParsePublicKeyfile(void *pk, void *path) NO_I
void *hxc_NativeSsl_sslInit(void) NO_P
void *hxc_NativeSsl_sslGetPeerCert(void *ssl) NO_P
int32_t hxc_NativeSsl_sslHandshake(void *ssl) NO_I
int32_t hxc_NativeSsl_sslRead(void *ssl, void *b, int32_t pos, int32_t len) NO_I
int32_t hxc_NativeSsl_sslWrite(void *ssl, void *b, int32_t pos, int32_t len) NO_I
void hxc_NativeSsl_sslSetBio(void *ssl, int32_t fd) NO_V
int32_t hxc_NativeSsl_sslSetHostname(void *ssl, void *host) NO_I
int32_t hxc_NativeSsl_sslSetup(void *ssl, void *conf) NO_I
int32_t hxc_NativeSsl_bioError(void *ssl) NO_I
int32_t hxc_NativeSsl_bioErrorSend(void *ssl) NO_I

#else

#include <errno.h>
#include <sys/socket.h>
#include <time.h>
#ifdef __TINYC__
// tcc defines neither __GNUC__ nor __clang__: skip mbedtls/check_config.h,
// which rejects the system config's MBEDTLS_DEPRECATED_WARNING
#define MBEDTLS_CHECK_CONFIG_H
#endif
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/oid.h"
#include "mbedtls/ssl.h"
#include "mbedtls/version.h"

#define PTR(o) FP(o, 0)

static void *wrap(void *p) {
	void *o = rt_alloc(1, T_NATIVE, K_RAW);
	PTR(o) = p;
	return o;
}

static void *str_of_c(const char *s, size_t n) { return hx_str_of_utf8(s, (int32_t)n); }

// a NUL-terminated copy of a Bytes (OCaml strings carry a NUL after their length)
static unsigned char *bytes_z(void *b) {
	int32_t n = BYTES_LEN(b);
	unsigned char *p = (unsigned char *)malloc((size_t)n + 1);
	memcpy(p, BYTES_DATA(b), (size_t)n);
	p[n] = 0;
	return p;
}

void *hxc_NativeSsl_strerror(int32_t code) {
	char buf[128];
	mbedtls_strerror(code, buf, sizeof(buf));
	return str_of_c(buf, strlen(buf));
}

// CtrDrbg

void *hxc_NativeSsl_ctrDrbgInit(void) {
	mbedtls_ctr_drbg_context *ctr_drbg = malloc(sizeof(mbedtls_ctr_drbg_context));
	mbedtls_ctr_drbg_init(ctr_drbg);
	return wrap(ctr_drbg);
}

int32_t hxc_NativeSsl_ctrDrbgRandom(void *ctx, void *output, int32_t len) {
	return mbedtls_ctr_drbg_random(PTR(ctx), BYTES_DATA(output), (size_t)len);
}

int32_t hxc_NativeSsl_ctrDrbgSeed(void *ctx, void *entropy) {
	return mbedtls_ctr_drbg_seed(PTR(ctx), mbedtls_entropy_func, PTR(entropy), NULL, 0);
}

// Entropy

void *hxc_NativeSsl_entropyInit(void) {
	mbedtls_entropy_context *entropy = malloc(sizeof(mbedtls_entropy_context));
	mbedtls_entropy_init(entropy);
	return wrap(entropy);
}

// Certificate

void *hxc_NativeSsl_x509CrtInit(void) {
	mbedtls_x509_crt *x509_crt = malloc(sizeof(mbedtls_x509_crt));
	mbedtls_x509_crt_init(x509_crt);
	return wrap(x509_crt);
}

void *hxc_NativeSsl_x509Next(void *chain) {
	mbedtls_x509_crt *cert = PTR(chain);
	if (cert->next == NULL) return NULL;
	return wrap(cert->next);
}

int32_t hxc_NativeSsl_x509CrtParse(void *chain, void *bytes) {
	int32_t len = BYTES_LEN(bytes);
	unsigned char *buf = bytes_z(bytes);
	int r = mbedtls_x509_crt_parse(PTR(chain), buf, (size_t)len + 1);
	free(buf);
	return r;
}

int32_t hxc_NativeSsl_x509CrtParseFile(void *chain, void *path) {
	char *p = hx_str_to_utf8(path);
	int r = mbedtls_x509_crt_parse_file(PTR(chain), p);
	free(p);
	return r;
}

int32_t hxc_NativeSsl_x509CrtParsePath(void *chain, void *path) {
	char *p = hx_str_to_utf8(path);
	int r = mbedtls_x509_crt_parse_path(PTR(chain), p);
	free(p);
	return r;
}

// Certificate Haxe API

void *hxc_NativeSsl_certAltNames(void *chain) {
	mbedtls_x509_crt *cert = PTR(chain);
#if MBEDTLS_VERSION_MAJOR >= 3
	if (!mbedtls_x509_crt_has_ext_type(cert, MBEDTLS_X509_EXT_SUBJECT_ALT_NAME)) {
#else
	if ((cert->ext_types & MBEDTLS_X509_EXT_SUBJECT_ALT_NAME) == 0) {
#endif
		return hx_arr_new(AK_PTR, 0);
	}
	mbedtls_asn1_sequence *cur = &cert->subject_alt_names;
	int32_t i = 0;
	while (cur != NULL) {
		++i;
		cur = cur->next;
	}
	void *obj = hx_arr_new(AK_PTR, i);
	RT_ROOT(obj);
	cur = &cert->subject_alt_names;
	i = 0;
	while (cur != NULL) {
		void *s = str_of_c((const char *)cur->buf.p, cur->buf.len);
		RT_RELOAD(obj);
		rt_set_ptr(ARR_DATA(obj), &FP(ARR_DATA(obj), i), s);
		++i;
		cur = cur->next;
	}
	RT_RELOAD(obj);
	RT_UNROOT(1);
	return obj;
}

static void *find_name(mbedtls_x509_name *obj, void *objname) {
	char *rname = hx_str_to_utf8(objname);
	const char *oname;
	while (obj != NULL) {
		int r = mbedtls_oid_get_attr_short_name(&obj->oid, &oname);
		if (r == 0 && strcmp(oname, rname) == 0) {
			free(rname);
			return str_of_c((const char *)obj->val.p, obj->val.len);
		}
		obj = obj->next;
	}
	free(rname);
	return NULL;
}

void *hxc_NativeSsl_certSubject(void *chain, void *objname) { return find_name(&((mbedtls_x509_crt *)PTR(chain))->subject, objname); }
void *hxc_NativeSsl_certIssuer(void *chain, void *objname) { return find_name(&((mbedtls_x509_crt *)PTR(chain))->issuer, objname); }

// upstream leaves the other fields of `info` (tm_isdst) uninitialized
static time_t time_to_time_t(mbedtls_x509_time *t) {
	struct tm info;
	memset(&info, 0, sizeof info);
	info.tm_year = t->year - 1900;
	info.tm_mon = t->mon - 1;
	info.tm_mday = t->day;
	info.tm_hour = t->hour;
	info.tm_min = t->min;
	info.tm_sec = t->sec;
	return mktime(&info);
}

double hxc_NativeSsl_certNotAfter(void *chain) { return (double)time_to_time_t(&((mbedtls_x509_crt *)PTR(chain))->valid_to); }
double hxc_NativeSsl_certNotBefore(void *chain) { return (double)time_to_time_t(&((mbedtls_x509_crt *)PTR(chain))->valid_from); }

// hx_cert_load_defaults: 0 when the system store was loaded; otherwise
// sys.ssl.Mbedtls.loadDefaultCertificates reads the CA files of
// Sys.systemName(). Upstream's Windows (system "Root" store) and macOS
// (Security framework) branches are compile-time; native POSIX builds have
// neither (1, as upstream on Linux and the BSDs).
#ifdef __COSMOPOLITAN__
// One Cosmopolitan binary runs on every OS, so the branches are taken at run
// time. Sys.systemName() says "Linux" on every OS there (rt_sys.c), so the
// macOS and BSD CA files are read here.
#include <cosmo.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <libc/nt/dll.h>
// upstream's Windows branch, through crypt32.dll (Cosmopolitan has no import
// library for it; GetProcAddress functions use the Microsoft x64 ABI)
typedef struct {
	uint32_t dwCertEncodingType;
	unsigned char *pbCertEncoded;
	uint32_t cbCertEncoded;
	void *pCertInfo;
	void *hCertStore;
} nt_cert_context;
typedef void *(__attribute__((__ms_abi__)) * nt_open_store)(intptr_t, const char *);
typedef const nt_cert_context *(__attribute__((__ms_abi__)) * nt_enum_certs)(void *, const nt_cert_context *);
typedef int32_t(__attribute__((__ms_abi__)) * nt_close_store)(void *, uint32_t);

static int load_windows_roots(mbedtls_x509_crt *chain) {
	int r = 1;
	int64_t lib = LoadLibraryA("crypt32.dll");
	if (!lib) return r;
	nt_open_store open_store = (nt_open_store)GetProcAddress(lib, "CertOpenSystemStoreA");
	nt_enum_certs enum_certs = (nt_enum_certs)GetProcAddress(lib, "CertEnumCertificatesInStore");
	nt_close_store close_store = (nt_close_store)GetProcAddress(lib, "CertCloseStore");
	void *store;
	if (open_store && enum_certs && close_store && (store = open_store(0, "Root"))) {
		const nt_cert_context *cert = NULL;
		while ((cert = enum_certs(store, cert))) {
			r = mbedtls_x509_crt_parse_der(chain, cert->pbCertEncoded, cert->cbCertEncoded);
			if (r != 0) return r; // as upstream (which leaves the store open)
		}
		close_store(store, 0);
	}
	return r;
}
#endif

// the first of these files that holds certificates
static int load_ca_files(mbedtls_x509_crt *chain, const char *const *paths) {
	for (; *paths; paths++) {
		if (access(*paths, R_OK) != 0) continue;
		if (mbedtls_x509_crt_parse_file(chain, *paths) >= 0 && chain->version != 0) return 0;
	}
	return 1;
}
#endif

int32_t hxc_NativeSsl_certLoadDefaults(void *certificate) {
#ifdef __COSMOPOLITAN__
	mbedtls_x509_crt *chain = PTR(certificate);
#if defined(__x86_64__)
	if (IsWindows()) return load_windows_roots(chain);
#endif
	// macOS: the system roots as a PEM bundle (not the keychain's user additions)
	static const char *const mac[] = {"/etc/ssl/cert.pem", NULL};
	if (IsXnu()) return load_ca_files(chain, mac);
	// the "BSD" list of sys.ssl.Mbedtls
	static const char *const bsd[] = {"/usr/local/share/certs/ca-root-nss.crt", "/etc/ssl/cert.pem",
		"/etc/openssl/certs/ca-certificates.crt", NULL};
	if (IsBsd()) return load_ca_files(chain, bsd);
#endif
	return 1;
}

// Config

void *hxc_NativeSsl_configInit(void) {
	mbedtls_ssl_config *ssl_config = malloc(sizeof(mbedtls_ssl_config));
	mbedtls_ssl_config_init(ssl_config);
	return wrap(ssl_config);
}

void hxc_NativeSsl_confAuthmode(void *conf, int32_t authmode) { mbedtls_ssl_conf_authmode(PTR(conf), authmode); }
void hxc_NativeSsl_confCaChain(void *conf, void *ca_chain) { mbedtls_ssl_conf_ca_chain(PTR(conf), PTR(ca_chain), NULL); }

int32_t hxc_NativeSsl_configDefaults(void *conf, int32_t endpoint, int32_t transport, int32_t preset) {
	return mbedtls_ssl_config_defaults(PTR(conf), endpoint, transport, preset);
}

void hxc_NativeSsl_confRng(void *conf, void *p_rng) { mbedtls_ssl_conf_rng(PTR(conf), mbedtls_ctr_drbg_random, PTR(p_rng)); }

// Pk: ml_mbedtls_pk_parse_* return the C int without Val_int, so OCaml reads
// the result as an immediate (r asr 1); the error codes Eval sees are halved.
#define CAML_RAW_INT(r) ((int32_t)((r) >> 1))

void *hxc_NativeSsl_pkInit(void) {
	mbedtls_pk_context *pk_context = malloc(sizeof(mbedtls_pk_context));
	mbedtls_pk_init(pk_context);
	return wrap(pk_context);
}

int32_t hxc_NativeSsl_pkParseKey(void *ctx, void *key, void *password, void *rng) {
	char *pwd = password ? hx_str_to_utf8(password) : NULL;
	size_t pwdlen = pwd ? strlen(pwd) : 0;
	int32_t len = BYTES_LEN(key);
	unsigned char *k = bytes_z(key);
#if MBEDTLS_VERSION_MAJOR >= 3
	int r = mbedtls_pk_parse_key(PTR(ctx), k, (size_t)len + 1, (const unsigned char *)pwd, pwdlen, mbedtls_ctr_drbg_random, NULL);
#else
	int r = mbedtls_pk_parse_key(PTR(ctx), k, (size_t)len + 1, (const unsigned char *)pwd, pwdlen);
#endif
	free(k);
	free(pwd);
	return CAML_RAW_INT(r);
}

int32_t hxc_NativeSsl_pkParseKeyfile(void *ctx, void *path, void *password, void *rng) {
	char *pwd = password ? hx_str_to_utf8(password) : NULL;
	char *p = hx_str_to_utf8(path);
#if MBEDTLS_VERSION_MAJOR >= 3
	int r = mbedtls_pk_parse_keyfile(PTR(ctx), p, pwd, mbedtls_ctr_drbg_random, PTR(rng));
#else
	int r = mbedtls_pk_parse_keyfile(PTR(ctx), p, pwd);
#endif
	free(p);
	free(pwd);
	return CAML_RAW_INT(r);
}

int32_t hxc_NativeSsl_pkParsePublicKey(void *ctx, void *key) {
	int32_t len = BYTES_LEN(key);
	unsigned char *k = bytes_z(key);
	int r = mbedtls_pk_parse_public_key(PTR(ctx), k, (size_t)len + 1);
	free(k);
	return CAML_RAW_INT(r);
}

int32_t hxc_NativeSsl_pkParsePublicKeyfile(void *ctx, void *path) {
	char *p = hx_str_to_utf8(path);
	int r = mbedtls_pk_parse_public_keyfile(PTR(ctx), p);
	free(p);
	return CAML_RAW_INT(r);
}

// Ssl: the context and its BIO state

typedef struct {
	mbedtls_ssl_context ssl;
	int fd;
	int bio_errno; // 0: no failure
	int bio_send; // the failure was in send (else recv)
} hx_ssl;

void *hxc_NativeSsl_sslInit(void) {
	hx_ssl *s = calloc(1, sizeof(hx_ssl));
	mbedtls_ssl_init(&s->ssl);
	s->fd = -1;
	return wrap(s);
}

void *hxc_NativeSsl_sslGetPeerCert(void *ssl) {
	hx_ssl *s = PTR(ssl);
	mbedtls_x509_crt *crt = (mbedtls_x509_crt *)mbedtls_ssl_get_peer_cert(&s->ssl);
	if (crt == NULL) return NULL;
	return wrap(crt);
}

int32_t hxc_NativeSsl_sslHandshake(void *ssl) {
	hx_ssl *s = PTR(ssl);
	s->bio_errno = 0;
	return mbedtls_ssl_handshake(&s->ssl);
}

// OS threads: the BIO callbacks wait in safe regions (a collection may move
// `buf` meanwhile), so mbedtls reads and writes a malloc'ed copy
int32_t hxc_NativeSsl_sslRead(void *ssl, void *buf, int32_t pos, int32_t len) {
	hx_ssl *s = PTR(ssl);
	s->bio_errno = 0;
#if RT_MT
	unsigned char *tmp = (unsigned char *)malloc(len > 0 ? (size_t)len : 1);
	RT_ROOT(buf);
	int r = mbedtls_ssl_read(&s->ssl, tmp, (size_t)len);
	RT_RELOAD(buf);
	RT_UNROOT(1);
	if (r > 0) memcpy(BYTES_DATA(buf) + pos, tmp, (size_t)r);
	free(tmp);
	return r;
#else
	return mbedtls_ssl_read(&s->ssl, BYTES_DATA(buf) + pos, (size_t)len);
#endif
}

int32_t hxc_NativeSsl_sslWrite(void *ssl, void *buf, int32_t pos, int32_t len) {
	hx_ssl *s = PTR(ssl);
	s->bio_errno = 0;
#if RT_MT
	unsigned char *tmp = (unsigned char *)malloc(len > 0 ? (size_t)len : 1);
	if (len > 0) memcpy(tmp, BYTES_DATA(buf) + pos, (size_t)len);
	int r = mbedtls_ssl_write(&s->ssl, tmp, (size_t)len);
	free(tmp);
	return r;
#else
	return mbedtls_ssl_write(&s->ssl, BYTES_DATA(buf) + pos, (size_t)len);
#endif
}

// Unix.send socket bytes 0 (Bytes.length bytes) []
static int bio_write_cb(void *ctx, const unsigned char *buf, size_t len) {
	hx_ssl *s = ctx;
	ssize_t r;
	RT_BLOCKING(r = send(s->fd, buf, len, 0));
	if (r < 0) {
		s->bio_errno = errno;
		s->bio_send = 1;
		return MBEDTLS_ERR_NET_SEND_FAILED;
	}
	return (int)r;
}

// Unix.recv socket bytes 0 (Bytes.length bytes) []
static int bio_read_cb(void *ctx, unsigned char *buf, size_t len) {
	hx_ssl *s = ctx;
	ssize_t r;
	RT_BLOCKING(r = recv(s->fd, buf, len, 0));
	if (r < 0) {
		s->bio_errno = errno;
		s->bio_send = 0;
		return MBEDTLS_ERR_NET_RECV_FAILED;
	}
	return (int)r;
}

void hxc_NativeSsl_sslSetBio(void *ssl, int32_t fd) {
	hx_ssl *s = PTR(ssl);
	s->fd = fd;
	mbedtls_ssl_set_bio(&s->ssl, s, bio_write_cb, bio_read_cb, NULL);
}

int32_t hxc_NativeSsl_sslSetHostname(void *ssl, void *hostname) {
	hx_ssl *s = PTR(ssl);
	char *h = hx_str_to_utf8(hostname);
	int r = mbedtls_ssl_set_hostname(&s->ssl, h);
	free(h);
	return r;
}

int32_t hxc_NativeSsl_sslSetup(void *ssl, void *conf) {
	hx_ssl *s = PTR(ssl);
	return mbedtls_ssl_setup(&s->ssl, PTR(conf));
}

int32_t hxc_NativeSsl_bioError(void *ssl) { return ((hx_ssl *)PTR(ssl))->bio_errno; }
int32_t hxc_NativeSsl_bioErrorSend(void *ssl) { return ((hx_ssl *)PTR(ssl))->bio_send; }

#endif
