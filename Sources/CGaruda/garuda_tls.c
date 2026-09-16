/* TLS over the existing non-blocking socket loop.
 *
 * OpenSSL is handed the descriptor directly (SSL_set_fd) rather than driven
 * through memory BIOs. With a non-blocking socket that gives exactly the
 * behaviour the rest of the server already handles: a short read or write, or
 * EAGAIN. The wrappers below translate SSL_ERROR_WANT_* into errno so the
 * connection loop needs no TLS-specific error handling.
 *
 * Partial writes are enabled deliberately. Without SSL_MODE_ENABLE_PARTIAL_WRITE
 * a write that cannot be completed must be retried with the identical buffer,
 * which a ring of connection buffers cannot promise; with it, and with
 * SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, SSL_write behaves like write(2).
 */

#define _GNU_SOURCE 1

#include "garuda_tls.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#if defined(__has_include)
#  if !__has_include(<openssl/ssl.h>)
#    define PG_NO_OPENSSL 1
#  endif
#endif

#ifdef PG_NO_OPENSSL

int pg_tls_available(void) { return 0; }
pg_tls_ctx *pg_tls_ctx_new(const char *cert_path, const char *key_path,
                           const char *alpn, const char *ciphers,
                           char *err, size_t err_len) {
    (void)cert_path; (void)key_path; (void)alpn; (void)ciphers;
    if (err && err_len) {
        snprintf(err, err_len, "this binary was built without OpenSSL");
    }
    return NULL;
}
int pg_tls_ctx_add(pg_tls_ctx *ctx, const char *cert_path, const char *key_path,
                   const char *ciphers, char *err, size_t err_len) {
    (void)ctx; (void)cert_path; (void)key_path; (void)ciphers;
    if (err && err_len) snprintf(err, err_len, "this binary was built without OpenSSL");
    return 0;
}
int pg_tls_ctx_host_count(pg_tls_ctx *ctx) { (void)ctx; return 0; }
int pg_tls_ctx_names(pg_tls_ctx *ctx, int host_index, int name_index,
                     char *out, size_t out_len) {
    (void)ctx; (void)host_index; (void)name_index; (void)out; (void)out_len;
    return 0;
}
void pg_tls_ctx_free(pg_tls_ctx *ctx) { (void)ctx; }
pg_tls *pg_tls_new(pg_tls_ctx *ctx, int fd) { (void)ctx; (void)fd; return NULL; }
pg_tls_ctx *pg_tls_client_ctx_new(const char *ca_file, const char *alpn,
                                  char *err, size_t err_len) {
    (void)ca_file; (void)alpn; (void)err; (void)err_len; return NULL;
}
pg_tls *pg_tls_client_new(pg_tls_ctx *ctx, int fd, const char *hostname) {
    (void)ctx; (void)fd; (void)hostname; return NULL;
}
void pg_tls_free(pg_tls *tls) { (void)tls; }
int pg_tls_handshake(pg_tls *tls, char *err, size_t err_len) {
    (void)tls; (void)err; (void)err_len; return -2;
}
long pg_tls_read(pg_tls *tls, void *buf, long n) {
    (void)tls; (void)buf; (void)n; errno = EPIPE; return -1;
}
long pg_tls_write(pg_tls *tls, const void *buf, long n) {
    (void)tls; (void)buf; (void)n; errno = EPIPE; return -1;
}
int pg_tls_enable_ktls(int on) { (void)on; return 0; }
int pg_tls_kernel_ready(void) { return 0; }
int pg_tls_ktls_send(pg_tls *tls) { (void)tls; return 0; }
long pg_tls_sendfile(pg_tls *tls, int fd, long offset, long n) {
    (void)tls; (void)fd; (void)offset; (void)n; errno = EPIPE; return -1;
}
int pg_tls_pending(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_idle_ok(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_wants_write(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_is_h2(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_is_acme(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_ctx_set_acme_dir(pg_tls_ctx *ctx, const char *dir) { (void)ctx; (void)dir; return -1; }
void pg_tls_shutdown(pg_tls *tls) { (void)tls; }

#else

#include <stdio.h>
#include <strings.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

/* One certificate, with the names it is valid for.
 *
 * The names come out of the certificate rather than from configuration: a
 * certificate already carries the list of hosts it is good for, in its subject
 * alternative names, and asking the operator to repeat it is asking them to
 * get it wrong. */
struct pg_tls_host {
    SSL_CTX *ctx;
    char **names;
    int name_count;
};

#define PG_TLS_MAX_HOSTS 64

struct pg_tls_ctx {
    struct pg_tls_host hosts[PG_TLS_MAX_HOSTS];
    int host_count;
    /* hosts[0]: what a client with no SNI, or an unrecognised one, is served.
     * Answering with the first certificate rather than refusing is what every
     * other server does, and it leaves the decision with the client, which can
     * see the name mismatch and say so in terms its user understands. */
    SSL_CTX *ctx;
    /* ALPN preference list in wire format: length-prefixed, most preferred
     * first. Held here because the callback runs per connection. */
    unsigned char *alpn;
    unsigned int alpn_len;
    /* Where --acme-domain keeps its files, when it is on. A tls-alpn-01
     * challenge certificate for NAME is at <acme_dir>/alpn/NAME.crt. */
    char *acme_dir;
};

struct pg_tls {
    SSL *ssl;
    int wants_write;
    int h2;
    /* The connection negotiated acme-tls/1: a CA validating a challenge, to
     * be closed as soon as the handshake is done. */
    int acme;
};

/* Marks a connection that is being served a challenge certificate, so that the
 * SNI and ALPN callbacks leave it alone. Allocated once per process. */
static int acme_ex_index = -1;

#if defined(SSL_OP_ENABLE_KTLS) && !defined(OPENSSL_NO_KTLS)
/* --ktls. Set by the supervisor before any context exists, and inherited by
 * every worker. */
static int g_ktls = 0;
#endif

int pg_tls_enable_ktls(int on) {
#if defined(SSL_OP_ENABLE_KTLS) && !defined(OPENSSL_NO_KTLS)
    g_ktls = on ? 1 : 0;
    return 1;
#else
    (void)on;
    return 0;
#endif
}

int pg_tls_kernel_ready(void) {
#if defined(__linux__)
    /* The module creates this when it loads. */
    FILE *f = fopen("/proc/net/tls_stat", "r");
    if (!f) return 0;
    fclose(f);
    return 1;
#else
    return 0;
#endif
}

static void last_error(char *err, size_t err_len, const char *what) {
    if (!err || err_len == 0) return;
    unsigned long code = ERR_get_error();
    if (code == 0) {
        snprintf(err, err_len, "%s", what);
        return;
    }
    char buf[256];
    ERR_error_string_n(code, buf, sizeof buf);
    snprintf(err, err_len, "%s: %s", what, buf);
    /* Drain the rest so a later failure does not report this one. */
    while (ERR_get_error() != 0) { }
}

/* Turns "h2,http/1.1" into the length-prefixed wire form ALPN uses. */
static unsigned char *encode_alpn(const char *list, unsigned int *out_len) {
    size_t n = strlen(list);
    unsigned char *out = malloc(n + 2);
    if (!out) return NULL;
    unsigned int w = 0;
    size_t i = 0;
    while (i <= n) {
        size_t start = i;
        while (i < n && list[i] != ',') i++;
        size_t len = i - start;
        if (len > 0 && len < 256) {
            out[w++] = (unsigned char)len;
            memcpy(out + w, list + start, len);
            w += (unsigned int)len;
        }
        if (i >= n) break;
        i++;
    }
    *out_len = w;
    return out;
}

/* Server preference: walk our list in order and take the first the client
 * offered. OpenSSL's own helper prefers the client's order, which is not what
 * a server that would rather speak HTTP/2 wants. */
static int alpn_select(SSL *ssl, const unsigned char **out, unsigned char *out_len,
                       const unsigned char *in, unsigned int in_len, void *arg) {
    struct pg_tls_ctx *ctx = (struct pg_tls_ctx *)arg;
    /* A challenge connection speaks acme-tls/1 and nothing else (RFC 8737). */
    if (acme_ex_index >= 0 && SSL_get_ex_data(ssl, acme_ex_index)) {
        for (unsigned int j = 0; j + 1 <= in_len && in[j];) {
            unsigned char have_len = in[j];
            if (have_len == 10 && j + 1u + 10u <= in_len
                && memcmp(in + j + 1, "acme-tls/1", 10) == 0) {
                *out = in + j + 1;
                *out_len = 10;
                return SSL_TLSEXT_ERR_OK;
            }
            j += 1u + have_len;
        }
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    for (unsigned int i = 0; i + 1 <= ctx->alpn_len && ctx->alpn[i];) {
        unsigned char want_len = ctx->alpn[i];
        const unsigned char *want = ctx->alpn + i + 1;
        for (unsigned int j = 0; j + 1 <= in_len && in[j];) {
            unsigned char have_len = in[j];
            const unsigned char *have = in + j + 1;
            if (have_len == want_len && memcmp(have, want, have_len) == 0) {
                *out = have;
                *out_len = have_len;
                return SSL_TLSEXT_ERR_OK;
            }
            j += 1u + have_len;
        }
        i += 1u + want_len;
    }
    /* No overlap. Refusing is correct for a client that asked for something
     * specific and got nothing. */
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

/* Remembers one name a certificate is valid for. Names arrive as ASN.1
 * strings, which are counted rather than terminated and may legally contain an
 * embedded NUL -- a name like that is a forgery attempt, so it is dropped. */
static void add_name(struct pg_tls_host *host, const char *name, int len) {
    if (len <= 0 || len > 255) return;
    if (memchr(name, 0, (size_t)len) != NULL) return;
    char **grown = realloc(host->names, (size_t)(host->name_count + 1) * sizeof *grown);
    if (!grown) return;
    host->names = grown;
    char *copy = malloc((size_t)len + 1);
    if (!copy) return;
    memcpy(copy, name, (size_t)len);
    copy[len] = 0;
    host->names[host->name_count++] = copy;
}

/* The DNS names in a certificate: its subject alternative names, or its common
 * name when it has none. CN is deprecated for this and still turns up in
 * certificates people generate by hand for a private service. */
static void collect_names(struct pg_tls_host *host) {
    X509 *cert = SSL_CTX_get0_certificate(host->ctx);
    if (!cert) return;

    GENERAL_NAMES *sans = X509_get_ext_d2i(cert, NID_subject_alt_name, NULL, NULL);
    if (sans) {
        int n = sk_GENERAL_NAME_num(sans);
        for (int i = 0; i < n; i++) {
            const GENERAL_NAME *entry = sk_GENERAL_NAME_value(sans, i);
            if (!entry || entry->type != GEN_DNS) continue;
            add_name(host, (const char *)ASN1_STRING_get0_data(entry->d.dNSName),
                     ASN1_STRING_length(entry->d.dNSName));
        }
        GENERAL_NAMES_free(sans);
    }

    if (host->name_count == 0) {
        char common[256];
        int len = X509_NAME_get_text_by_NID(X509_get_subject_name(cert),
                                            NID_commonName, common, sizeof common);
        if (len > 0) add_name(host, common, len);
    }
}

/* RFC 6125 name matching: case-insensitive, and a wildcard covers exactly one
 * label. `*.example.com` is a.example.com but not a.b.example.com, and not
 * example.com itself. */
static int host_matches(const char *pattern, const char *host) {
    if (pattern[0] == '*' && pattern[1] == '.') {
        const char *dot = strchr(host, '.');
        if (!dot) return 0;
        return strcasecmp(dot + 1, pattern + 2) == 0;
    }
    return strcasecmp(pattern, host) == 0;
}

/* Picks the certificate for the name the client asked for. */
static int sni_select(SSL *ssl, int *unused_alert, void *arg) {
    (void)unused_alert;
    struct pg_tls_ctx *wrapper = (struct pg_tls_ctx *)arg;
    /* Swapping the context would swap out the challenge certificate. */
    if (acme_ex_index >= 0 && SSL_get_ex_data(ssl, acme_ex_index)) return SSL_TLSEXT_ERR_OK;
    const char *asked = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
    if (!asked || !*asked) return SSL_TLSEXT_ERR_OK;

    for (int i = 0; i < wrapper->host_count; i++) {
        for (int j = 0; j < wrapper->hosts[i].name_count; j++) {
            if (!host_matches(wrapper->hosts[i].names[j], asked)) continue;
            SSL_set_SSL_CTX(ssl, wrapper->hosts[i].ctx);
            return SSL_TLSEXT_ERR_OK;
        }
    }
    /* Unrecognised: the default certificate, and the client decides. */
    return SSL_TLSEXT_ERR_OK;
}

/* Everything that is the same for every certificate. SSL_set_SSL_CTX swaps the
 * certificate but carries almost nothing else over, so each context has to be
 * able to stand on its own. */
static int configure_common(SSL_CTX *ctx, struct pg_tls_ctx *wrapper,
                            const char *ciphers, char *err, size_t err_len) {
    /* TLS 1.2 is the floor; everything below it is broken in public. */
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION
                             | SSL_OP_CIPHER_SERVER_PREFERENCE
                             | SSL_OP_NO_RENEGOTIATION);
#if defined(SSL_OP_ENABLE_KTLS) && !defined(OPENSSL_NO_KTLS)
    /* --ktls: kernel TLS, wherever the kernel and the negotiated cipher allow
     * it. OpenSSL falls back to encrypting in-process on its own when not. */
    if (g_ktls) SSL_CTX_set_options(ctx, SSL_OP_ENABLE_KTLS);
#endif
    SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE
                          | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
                          | SSL_MODE_RELEASE_BUFFERS);
    if (ciphers && *ciphers) {
        if (SSL_CTX_set_cipher_list(ctx, ciphers) != 1) {
            last_error(err, err_len, "no usable ciphers in the list given");
            return 0;
        }
    }
    if (wrapper->alpn) SSL_CTX_set_alpn_select_cb(ctx, alpn_select, wrapper);
    return 1;
}

/* Loads a certificate and key into a fresh context and records its names. */
static int add_host(struct pg_tls_ctx *wrapper, const char *cert_path,
                    const char *key_path, const char *ciphers,
                    char *err, size_t err_len) {
    if (wrapper->host_count >= PG_TLS_MAX_HOSTS) {
        if (err && err_len) snprintf(err, err_len, "too many certificates");
        return 0;
    }
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        last_error(err, err_len, "cannot create a TLS context");
        return 0;
    }
    if (!configure_common(ctx, wrapper, ciphers, err, err_len)) {
        SSL_CTX_free(ctx);
        return 0;
    }
    if (SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) {
        last_error(err, err_len, "cannot load the certificate");
        SSL_CTX_free(ctx);
        return 0;
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        last_error(err, err_len, "cannot load the private key");
        SSL_CTX_free(ctx);
        return 0;
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        last_error(err, err_len, "the private key does not match the certificate");
        SSL_CTX_free(ctx);
        return 0;
    }

    struct pg_tls_host *host = &wrapper->hosts[wrapper->host_count++];
    host->ctx = ctx;
    host->names = NULL;
    host->name_count = 0;
    collect_names(host);
    return 1;
}

/* --- tls-alpn-01 (RFC 8737) ------------------------------------------------
 *
 * A CA validating a challenge opens a TLS connection offering exactly one
 * protocol, acme-tls/1, and expects a self-signed certificate carrying the
 * digest of the key authorization. The ACME helper process writes that
 * certificate into the cache directory; any worker the connection lands on
 * finds it there by the name in the SNI.
 *
 * It has to be decided in the ClientHello callback. The SNI callback runs
 * before ALPN is known, and the ALPN callback runs after the certificate has
 * been chosen, so neither alone can serve a certificate that depends on both. */

static pthread_once_t acme_index_once = PTHREAD_ONCE_INIT;

static void make_acme_index(void) {
    acme_ex_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
}

static int offers_acme(const unsigned char *ext, size_t len) {
    if (len < 2) return 0;
    size_t list = (size_t)ext[0] << 8 | ext[1];
    if (list + 2 > len) return 0;
    size_t i = 2;
    while (i < 2 + list) {
        size_t n = ext[i];
        if (i + 1 + n > 2 + list) return 0;
        if (n == 10 && memcmp(ext + i + 1, "acme-tls/1", 10) == 0) return 1;
        i += 1 + n;
    }
    return 0;
}

/* The host name from a raw server_name extension, lower-cased, restricted to
 * the characters a DNS name has -- it becomes part of a file path. */
static int sni_host(const unsigned char *ext, size_t len, char *out, size_t cap) {
    if (len < 5) return 0;
    size_t list = (size_t)ext[0] << 8 | ext[1];
    if (list + 2 > len || list < 3 || ext[2] != 0) return 0;
    size_t n = (size_t)ext[3] << 8 | ext[4];
    if (n == 0 || n + 5 > len || n >= cap) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = ext[5 + i];
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
        int allowed = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.';
        if (!allowed) return 0;
        out[i] = (char)c;
    }
    out[n] = 0;
    return out[0] != '.';
}

static int acme_client_hello(SSL *ssl, int *alert, void *arg) {
    (void)alert;
    struct pg_tls_ctx *wrapper = (struct pg_tls_ctx *)arg;
    if (!wrapper->acme_dir) return SSL_CLIENT_HELLO_SUCCESS;

    const unsigned char *ext;
    size_t len;
    if (!SSL_client_hello_get0_ext(ssl, TLSEXT_TYPE_application_layer_protocol_negotiation,
                                   &ext, &len)
        || !offers_acme(ext, len)) {
        return SSL_CLIENT_HELLO_SUCCESS;
    }
    char host[256];
    if (!SSL_client_hello_get0_ext(ssl, TLSEXT_TYPE_server_name, &ext, &len)
        || !sni_host(ext, len, host, sizeof host)) {
        return SSL_CLIENT_HELLO_SUCCESS;
    }
    char cert[4200], key[4200];
    if (snprintf(cert, sizeof cert, "%s/alpn/%s.crt", wrapper->acme_dir, host) >= (int)sizeof cert
        || snprintf(key, sizeof key, "%s/alpn/%s.key", wrapper->acme_dir, host) >= (int)sizeof key) {
        return SSL_CLIENT_HELLO_SUCCESS;
    }
    /* No challenge pending for that name is not an error here: the handshake
     * carries on as usual, and a client that offered nothing but acme-tls/1
     * is refused by the ALPN callback for want of a protocol in common. */
    if (SSL_use_certificate_file(ssl, cert, SSL_FILETYPE_PEM) != 1
        || SSL_use_PrivateKey_file(ssl, key, SSL_FILETYPE_PEM) != 1) {
        ERR_clear_error();
        return SSL_CLIENT_HELLO_SUCCESS;
    }
    SSL_set_ex_data(ssl, acme_ex_index, (void *)1);
    return SSL_CLIENT_HELLO_SUCCESS;
}

int pg_tls_ctx_set_acme_dir(pg_tls_ctx *wrapper, const char *dir) {
    if (!wrapper || !dir) return -1;
    pthread_once(&acme_index_once, make_acme_index);
    if (acme_ex_index < 0) return -1;
    char *copy = strdup(dir);
    if (!copy) return -1;
    free(wrapper->acme_dir);
    wrapper->acme_dir = copy;
    /* On the context every connection starts on: the ClientHello callback
     * runs before SNI could move a connection to another one. */
    SSL_CTX_set_client_hello_cb(wrapper->ctx, acme_client_hello, wrapper);
    return 0;
}

int pg_tls_available(void) { return 1; }

int pg_tls_ctx_add(pg_tls_ctx *wrapper, const char *cert_path, const char *key_path,
                   const char *ciphers, char *err, size_t err_len) {
    if (!wrapper) return 0;
    return add_host(wrapper, cert_path, key_path, ciphers, err, err_len);
}

int pg_tls_ctx_names(pg_tls_ctx *wrapper, int host_index, int name_index,
                     char *out, size_t out_len) {
    if (!wrapper || host_index < 0 || host_index >= wrapper->host_count) return 0;
    struct pg_tls_host *host = &wrapper->hosts[host_index];
    if (name_index < 0 || name_index >= host->name_count) return 0;
    if (out && out_len) snprintf(out, out_len, "%s", host->names[name_index]);
    return 1;
}

int pg_tls_ctx_host_count(pg_tls_ctx *wrapper) {
    return wrapper ? wrapper->host_count : 0;
}

pg_tls_ctx *pg_tls_ctx_new(const char *cert_path, const char *key_path,
                           const char *alpn, const char *ciphers,
                           char *err, size_t err_len) {
    struct pg_tls_ctx *wrapper = calloc(1, sizeof *wrapper);
    if (!wrapper) {
        if (err && err_len) snprintf(err, err_len, "out of memory");
        return NULL;
    }

    /* Before the first context, so that `configure_common` can install the
     * callback on every one of them. */
    if (alpn && *alpn) {
        wrapper->alpn = encode_alpn(alpn, &wrapper->alpn_len);
        if (!wrapper->alpn) {
            if (err && err_len) snprintf(err, err_len, "out of memory");
            free(wrapper);
            return NULL;
        }
    }

    if (!add_host(wrapper, cert_path, key_path, ciphers, err, err_len)) {
        free(wrapper->alpn);
        free(wrapper);
        return NULL;
    }

    /* The first certificate is the default, and the one the SNI callback hangs
     * off: the callback runs before the context is swapped, so it has to be
     * installed on whichever context the connection starts on. */
    wrapper->ctx = wrapper->hosts[0].ctx;
    SSL_CTX_set_tlsext_servername_callback(wrapper->ctx, sni_select);
    SSL_CTX_set_tlsext_servername_arg(wrapper->ctx, wrapper);
    return wrapper;
}

void pg_tls_ctx_free(pg_tls_ctx *wrapper) {
    if (!wrapper) return;
    for (int i = 0; i < wrapper->host_count; i++) {
        for (int j = 0; j < wrapper->hosts[i].name_count; j++) {
            free(wrapper->hosts[i].names[j]);
        }
        free(wrapper->hosts[i].names);
        if (wrapper->hosts[i].ctx) SSL_CTX_free(wrapper->hosts[i].ctx);
    }
    free(wrapper->alpn);
    free(wrapper->acme_dir);
    free(wrapper);
}

pg_tls_ctx *pg_tls_client_ctx_new(const char *ca_file, const char *alpn,
                                  char *err, size_t err_len) {
    struct pg_tls_ctx *wrapper = calloc(1, sizeof *wrapper);
    if (!wrapper) {
        if (err && err_len) snprintf(err, err_len, "out of memory");
        return NULL;
    }
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        last_error(err, err_len, "cannot create a TLS client context");
        free(wrapper);
        return NULL;
    }
    /* The same floor and the same modes as a served connection. Not
     * SSL_OP_CIPHER_SERVER_PREFERENCE, which means nothing to a client. */
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE
                          | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
                          | SSL_MODE_RELEASE_BUFFERS);

    /* Refuse a chain that does not check out, rather than reporting it and
     * carrying on: a client that continues past a verification failure is
     * not doing TLS, it is doing encryption against nobody in particular. */
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    if (ca_file && *ca_file) {
        if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
            last_error(err, err_len, "cannot load the CA file");
            SSL_CTX_free(ctx);
            free(wrapper);
            return NULL;
        }
    } else if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
        last_error(err, err_len, "cannot load the system trust store");
        SSL_CTX_free(ctx);
        free(wrapper);
        return NULL;
    }

    if (alpn && *alpn) {
        unsigned int len = 0;
        unsigned char *wire = encode_alpn(alpn, &len);
        if (!wire) {
            if (err && err_len) snprintf(err, err_len, "out of memory");
            SSL_CTX_free(ctx);
            free(wrapper);
            return NULL;
        }
        /* Inverted, unlike almost everything else here: 0 is success. */
        if (SSL_CTX_set_alpn_protos(ctx, wire, len) != 0) {
            last_error(err, err_len, "cannot set the ALPN list");
            free(wire);
            SSL_CTX_free(ctx);
            free(wrapper);
            return NULL;
        }
        wrapper->alpn = wire;
        wrapper->alpn_len = len;
    }

    /* Kept in hosts[0] rather than only in `ctx`: pg_tls_ctx_free releases
     * contexts through the hosts array, so a context parked anywhere else
     * would leak. There is no certificate and no name list -- a client sends
     * neither -- so host_count is 1 with names NULL. */
    wrapper->hosts[0].ctx = ctx;
    wrapper->hosts[0].names = NULL;
    wrapper->hosts[0].name_count = 0;
    wrapper->host_count = 1;
    wrapper->ctx = ctx;
    return wrapper;
}

pg_tls *pg_tls_client_new(pg_tls_ctx *ctx, int fd, const char *hostname) {
    if (!ctx) return NULL;
    struct pg_tls *tls = calloc(1, sizeof *tls);
    if (!tls) return NULL;
    tls->ssl = SSL_new(ctx->ctx);
    if (!tls->ssl) { free(tls); return NULL; }
    if (SSL_set_fd(tls->ssl, fd) != 1) {
        SSL_free(tls->ssl);
        free(tls);
        return NULL;
    }
    if (hostname && *hostname) {
        /* Which certificate to send... */
        SSL_set_tlsext_host_name(tls->ssl, hostname);
        /* ...and the name that certificate has to be for. Verification
         * without this checks that the chain is trusted, not that it belongs
         * to whoever we meant to talk to. */
        if (SSL_set1_host(tls->ssl, hostname) != 1) {
            SSL_free(tls->ssl);
            free(tls);
            return NULL;
        }
    }
    SSL_set_connect_state(tls->ssl);
    return tls;
}

pg_tls *pg_tls_new(pg_tls_ctx *ctx, int fd) {
    if (!ctx) return NULL;
    struct pg_tls *tls = calloc(1, sizeof *tls);
    if (!tls) return NULL;
    tls->ssl = SSL_new(ctx->ctx);
    if (!tls->ssl) { free(tls); return NULL; }
    if (SSL_set_fd(tls->ssl, fd) != 1) {
        SSL_free(tls->ssl);
        free(tls);
        return NULL;
    }
    SSL_set_accept_state(tls->ssl);
    return tls;
}

void pg_tls_free(pg_tls *tls) {
    if (!tls) return;
    if (tls->ssl) SSL_free(tls->ssl);
    free(tls);
}

int pg_tls_handshake(pg_tls *tls, char *err, size_t err_len) {
    if (!tls || !tls->ssl) return -2;
    ERR_clear_error();
    int rc = SSL_do_handshake(tls->ssl);
    if (rc == 1) {
        const unsigned char *proto = NULL;
        unsigned int len = 0;
        SSL_get0_alpn_selected(tls->ssl, &proto, &len);
        tls->h2 = (len == 2 && proto && proto[0] == 'h' && proto[1] == '2');
        tls->acme = (len == 10 && proto && memcmp(proto, "acme-tls/1", 10) == 0);
        tls->wants_write = 0;
        return 1;
    }
    switch (SSL_get_error(tls->ssl, rc)) {
    case SSL_ERROR_WANT_READ:
        tls->wants_write = 0;
        return 0;
    case SSL_ERROR_WANT_WRITE:
        tls->wants_write = 1;
        return -1;
    default:
        last_error(err, err_len, "handshake failed");
        return -2;
    }
}

long pg_tls_read(pg_tls *tls, void *buf, long n) {
    if (!tls || !tls->ssl) { errno = EPIPE; return -1; }
    if (n <= 0) return 0;
    ERR_clear_error();
    int rc = SSL_read(tls->ssl, buf, (int)(n > 0x7fffffff ? 0x7fffffff : n));
    if (rc > 0) {
        tls->wants_write = 0;
        return rc;
    }
    switch (SSL_get_error(tls->ssl, rc)) {
    case SSL_ERROR_ZERO_RETURN:
        return 0;                      /* close_notify: a clean end of stream */
    case SSL_ERROR_WANT_READ:
        tls->wants_write = 0;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_WANT_WRITE:
        /* A key update or renegotiation needs the socket writable before this
         * read can finish. */
        tls->wants_write = 1;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_SYSCALL:
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
        errno = EPIPE;
        return -1;
    default:
        errno = EPIPE;
        return -1;
    }
}

long pg_tls_write(pg_tls *tls, const void *buf, long n) {
    if (!tls || !tls->ssl) { errno = EPIPE; return -1; }
    if (n <= 0) return 0;
    ERR_clear_error();
    int rc = SSL_write(tls->ssl, buf, (int)(n > 0x7fffffff ? 0x7fffffff : n));
    if (rc > 0) {
        tls->wants_write = 0;
        return rc;
    }
    switch (SSL_get_error(tls->ssl, rc)) {
    case SSL_ERROR_WANT_READ:
        /* Rare, but a write can need input first. The caller polls for both. */
        tls->wants_write = 0;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_WANT_WRITE:
        tls->wants_write = 1;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_SYSCALL:
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
        errno = EPIPE;
        return -1;
    default:
        errno = EPIPE;
        return -1;
    }
}

int pg_tls_ktls_send(pg_tls *tls) {
#if defined(SSL_OP_ENABLE_KTLS) && !defined(OPENSSL_NO_KTLS)
    if (!tls || !tls->ssl) return 0;
    BIO *wbio = SSL_get_wbio(tls->ssl);
    return wbio && BIO_get_ktls_send(wbio) ? 1 : 0;
#else
    (void)tls;
    return 0;
#endif
}

long pg_tls_sendfile(pg_tls *tls, int fd, long offset, long n) {
#if defined(SSL_OP_ENABLE_KTLS) && !defined(OPENSSL_NO_KTLS)
    if (!tls || !tls->ssl) { errno = EPIPE; return -1; }
    if (n <= 0) return 0;
    ERR_clear_error();
    ossl_ssize_t rc = SSL_sendfile(tls->ssl, fd, (off_t)offset, (size_t)n, 0);
    if (rc > 0) {
        tls->wants_write = 0;
        return (long)rc;
    }
    if (rc == 0) {
        /* Nothing left at that offset: the file shrank after its length was
         * promised. */
        errno = EPIPE;
        return -1;
    }
    switch (SSL_get_error(tls->ssl, (int)rc)) {
    case SSL_ERROR_WANT_WRITE:
        tls->wants_write = 1;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_WANT_READ:
        tls->wants_write = 0;
        errno = EAGAIN;
        return -1;
    case SSL_ERROR_SYSCALL:
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
        errno = EPIPE;
        return -1;
    default:
        errno = EPIPE;
        return -1;
    }
#else
    (void)tls; (void)fd; (void)offset; (void)n;
    errno = EPIPE;
    return -1;
#endif
}

int pg_tls_pending(pg_tls *tls) {
    if (!tls || !tls->ssl) return 0;
    return SSL_pending(tls->ssl);
}

int pg_tls_idle_ok(pg_tls *tls) {
    if (!tls || !tls->ssl) return 0;
    ERR_clear_error();
    unsigned char byte;
    /* SSL_read is what drives post-handshake messages; OpenSSL offers no way
     * to process them without offering to read. Application data arriving on
     * a connection nobody is using means the peer spoke out of turn, and the
     * byte consumed here does not matter: that connection is being discarded
     * either way. */
    int rc = SSL_read(tls->ssl, &byte, 1);
    if (rc > 0) return 0;
    switch (SSL_get_error(tls->ssl, rc)) {
    case SSL_ERROR_WANT_READ:
    case SSL_ERROR_WANT_WRITE:
        /* Nothing to report: whatever arrived was bookkeeping, and OpenSSL
         * has dealt with it. */
        return 1;
    case SSL_ERROR_SYSCALL:
        return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 1 : 0;
    default:
        /* close_notify included: a clean end is still an end. */
        return 0;
    }
}

int pg_tls_wants_write(pg_tls *tls) { return tls ? tls->wants_write : 0; }

int pg_tls_is_h2(pg_tls *tls) { return tls ? tls->h2 : 0; }

int pg_tls_is_acme(pg_tls *tls) { return tls ? tls->acme : 0; }

void pg_tls_shutdown(pg_tls *tls) {
    if (!tls || !tls->ssl) return;
    /* One try. If the socket will not take the close_notify we are closing
     * anyway, and blocking here would hold up the whole loop. */
    ERR_clear_error();
    SSL_shutdown(tls->ssl);
}

#endif /* PG_NO_OPENSSL */
