/* TLS, wrapped so that OpenSSL headers never reach the Swift side.
 *
 * Same rule as Python.h: the Swift module map imports these headers, and
 * anything with a packed struct, a macro-heavy API or a feature-test macro of
 * its own would leak into every target that imports CPeregrine. So the types
 * here are opaque and the API is the eight operations the server needs.
 *
 * The read and write wrappers deliberately look like read(2) and write(2):
 * they return a byte count, or -1 with errno set to EAGAIN when OpenSSL needs
 * more of the socket. That lets the connection loop keep one code path for
 * plaintext and TLS instead of two.
 */
#ifndef PEREGRINE_TLS_H
#define PEREGRINE_TLS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pg_tls_ctx pg_tls_ctx;
typedef struct pg_tls pg_tls;

/* Whether this binary was built against OpenSSL at all. */
int pg_tls_available(void);

/* Creates a server context. `alpn` is a comma-separated preference list, most
 * preferred first, e.g. "h2,http/1.1"; NULL or "" disables ALPN. On failure
 * returns NULL and writes a human-readable reason into `err`. */
pg_tls_ctx *pg_tls_ctx_new(const char *cert_path, const char *key_path,
                           const char *alpn, const char *ciphers,
                           char *err, size_t err_len);
/* Adds another certificate, for SNI. The first one given to pg_tls_ctx_new is
 * the default; these are chosen by the name the client asks for, matched
 * against the DNS names inside each certificate. Returns 0 and fills `err` on
 * failure. */
int pg_tls_ctx_add(pg_tls_ctx *ctx, const char *cert_path, const char *key_path,
                   const char *ciphers, char *err, size_t err_len);

/* How many certificates are loaded, and the names of each -- for the start-up
 * log, so an operator can see what the server believes it can serve. Returns 0
 * when the index is past the end. */
int pg_tls_ctx_host_count(pg_tls_ctx *ctx);
int pg_tls_ctx_names(pg_tls_ctx *ctx, int host_index, int name_index,
                     char *out, size_t out_len);

void pg_tls_ctx_free(pg_tls_ctx *ctx);

pg_tls *pg_tls_new(pg_tls_ctx *ctx, int fd);
void pg_tls_free(pg_tls *tls);

/* Handshake progress: 1 done, 0 needs more input, -1 needs to write, -2 failed.
 * A failure reason, when there is one, is written into `err`. */
int pg_tls_handshake(pg_tls *tls, char *err, size_t err_len);

/* read(2)/write(2) shaped. -1 with errno EAGAIN means "not yet"; errno EPIPE
 * means the session is over. A read of 0 is a clean close_notify. */
long pg_tls_read(pg_tls *tls, void *buf, long n);
long pg_tls_write(pg_tls *tls, const void *buf, long n);

/* Decrypted bytes OpenSSL is holding that the socket no longer has. A
 * level-triggered poller will not mention these, so anything that reads has to
 * keep asking until this is zero. */
int pg_tls_pending(pg_tls *tls);

/* Set when the last call could not proceed until the socket is writable,
 * which is how a renegotiation or a key update surfaces mid-read. */
int pg_tls_wants_write(pg_tls *tls);

/* 1 when ALPN settled on HTTP/2. */
int pg_tls_is_h2(pg_tls *tls);

/* Best-effort close_notify. Never blocks. */
void pg_tls_shutdown(pg_tls *tls);

#ifdef __cplusplus
}
#endif

#endif /* PEREGRINE_TLS_H */
