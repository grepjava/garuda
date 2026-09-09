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

#include "peregrine_tls.h"

#include <errno.h>
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
void pg_tls_ctx_free(pg_tls_ctx *ctx) { (void)ctx; }
pg_tls *pg_tls_new(pg_tls_ctx *ctx, int fd) { (void)ctx; (void)fd; return NULL; }
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
int pg_tls_pending(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_wants_write(pg_tls *tls) { (void)tls; return 0; }
int pg_tls_is_h2(pg_tls *tls) { (void)tls; return 0; }
void pg_tls_shutdown(pg_tls *tls) { (void)tls; }

#else

#include <stdio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

struct pg_tls_ctx {
    SSL_CTX *ctx;
    /* ALPN preference list in wire format: length-prefixed, most preferred
     * first. Held here because the callback runs per connection. */
    unsigned char *alpn;
    unsigned int alpn_len;
};

struct pg_tls {
    SSL *ssl;
    int wants_write;
    int h2;
};

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
    (void)ssl;
    struct pg_tls_ctx *ctx = (struct pg_tls_ctx *)arg;
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

int pg_tls_available(void) { return 1; }

pg_tls_ctx *pg_tls_ctx_new(const char *cert_path, const char *key_path,
                           const char *alpn, const char *ciphers,
                           char *err, size_t err_len) {
    struct pg_tls_ctx *wrapper = calloc(1, sizeof *wrapper);
    if (!wrapper) {
        if (err && err_len) snprintf(err, err_len, "out of memory");
        return NULL;
    }
    wrapper->ctx = SSL_CTX_new(TLS_server_method());
    if (!wrapper->ctx) {
        last_error(err, err_len, "cannot create a TLS context");
        free(wrapper);
        return NULL;
    }
    SSL_CTX *ctx = wrapper->ctx;

    /* TLS 1.2 is the floor; everything below it is broken in public. */
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION
                             | SSL_OP_CIPHER_SERVER_PREFERENCE
                             | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE
                          | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
                          | SSL_MODE_RELEASE_BUFFERS);
    if (ciphers && *ciphers) {
        if (SSL_CTX_set_cipher_list(ctx, ciphers) != 1) {
            last_error(err, err_len, "no usable ciphers in the list given");
            SSL_CTX_free(ctx);
            free(wrapper);
            return NULL;
        }
    }

    if (SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) {
        last_error(err, err_len, "cannot load the certificate");
        SSL_CTX_free(ctx);
        free(wrapper);
        return NULL;
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        last_error(err, err_len, "cannot load the private key");
        SSL_CTX_free(ctx);
        free(wrapper);
        return NULL;
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        last_error(err, err_len, "the private key does not match the certificate");
        SSL_CTX_free(ctx);
        free(wrapper);
        return NULL;
    }

    if (alpn && *alpn) {
        wrapper->alpn = encode_alpn(alpn, &wrapper->alpn_len);
        if (!wrapper->alpn) {
            if (err && err_len) snprintf(err, err_len, "out of memory");
            SSL_CTX_free(ctx);
            free(wrapper);
            return NULL;
        }
        SSL_CTX_set_alpn_select_cb(ctx, alpn_select, wrapper);
    }
    return wrapper;
}

void pg_tls_ctx_free(pg_tls_ctx *ctx) {
    if (!ctx) return;
    if (ctx->ctx) SSL_CTX_free(ctx->ctx);
    free(ctx->alpn);
    free(ctx);
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

int pg_tls_pending(pg_tls *tls) {
    if (!tls || !tls->ssl) return 0;
    return SSL_pending(tls->ssl);
}

int pg_tls_wants_write(pg_tls *tls) { return tls ? tls->wants_write : 0; }

int pg_tls_is_h2(pg_tls *tls) { return tls ? tls->h2 : 0; }

void pg_tls_shutdown(pg_tls *tls) {
    if (!tls || !tls->ssl) return;
    /* One try. If the socket will not take the close_notify we are closing
     * anyway, and blocking here would hold up the whole loop. */
    ERR_clear_error();
    SSL_shutdown(tls->ssl);
}

#endif /* PG_NO_OPENSSL */
