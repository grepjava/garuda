/* ---------------------------------------------------------------------------
 * The OpenSSL half of the ACME client (RFC 8555, RFC 8737).
 *
 * The protocol -- the order, the authorizations, the polling -- is in Swift,
 * in ACME.swift. What is here is everything that needs OpenSSL: the account
 * key and its JWK, ES256 signatures, the CSR, the tls-alpn-01 challenge
 * certificate, and one HTTPS request at a time to the CA.
 *
 * None of it runs in a worker. The client runs in a helper process the
 * supervisor forks, so a CA that is slow or down costs a waiting process and
 * nothing that serves requests.
 * ------------------------------------------------------------------------- */
#ifndef GARUDA_ACME_H
#define GARUDA_ACME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pg_acme_key pg_acme_key;
typedef struct pg_acme_resp pg_acme_resp;

/* base64url without padding, NUL-terminated. Returns the length, or -1. */
int pg_acme_b64url(const uint8_t *in, size_t n, char *out, size_t cap);

/* The account key at `path`, created (P-256, mode 0600) if there is none. */
pg_acme_key *pg_acme_key_load_or_create(const char *path, char *err, size_t err_len);
void pg_acme_key_free(pg_acme_key *key);

/* The public key as a JWK, in the member order RFC 7638 fixes for its
 * thumbprint. Returns the length, or -1. */
int pg_acme_jwk(pg_acme_key *key, char *out, size_t cap);

/* base64url(SHA-256(JWK)): the account's half of every key authorization. */
int pg_acme_thumbprint(pg_acme_key *key, char *out, size_t cap);

/* ES256 over `data`, as base64url of the raw 64-byte r||s JWS wants (not the
 * DER OpenSSL produces). Returns the length, or -1. */
int pg_acme_sign(pg_acme_key *key, const uint8_t *data, size_t n, char *out, size_t cap);

/* A fresh P-256 key written to `key_path` (0600), and a CSR for the
 * comma-separated `names` signed with it, as base64url DER. */
int pg_acme_csr(const char *names, const char *key_path, char *out, size_t cap,
                char *err, size_t err_len);

/* The RFC 8737 challenge certificate for `name`: self-signed, the name as its
 * only SAN, and a critical id-pe-acmeIdentifier extension holding
 * SHA-256(key_authorization). Written atomically to the two paths. */
int pg_acme_alpn_cert(const char *name, const char *key_authorization,
                      const char *cert_path, const char *key_path,
                      char *err, size_t err_len);

/* A self-signed certificate for `names` to serve until a real one arrives, so
 * that workers can start -- and answer the challenge that gets the real one. */
int pg_acme_placeholder(const char *names, const char *cert_path, const char *key_path,
                        char *err, size_t err_len);

/* 1 when the certificate at `path` should be replaced: unreadable, the
 * placeholder, missing one of `names`, or expiring within `renew_seconds`. */
int pg_acme_needs_certificate(const char *path, const char *names, long renew_seconds);

/* One HTTPS request. The peer is verified against `ca_file`, or the system's
 * trust store when that is NULL. NULL with `err` set on failure. */
pg_acme_resp *pg_acme_https(const char *method, const char *url,
                            const char *content_type, const uint8_t *body, size_t body_len,
                            const char *accept, const char *ca_file,
                            char *err, size_t err_len);
int pg_acme_resp_status(pg_acme_resp *resp);
/* Copies header `name` (case-insensitive) into `out`. Returns its length, or
 * -1 when absent. */
int pg_acme_resp_header(pg_acme_resp *resp, const char *name, char *out, size_t cap);
const uint8_t *pg_acme_resp_body(pg_acme_resp *resp, size_t *len);
void pg_acme_resp_free(pg_acme_resp *resp);

/* Files. */
int pg_acme_mkdirs(const char *path);
/* Writes `data` to `path` through a temporary file and a rename, mode `mode`. */
int pg_acme_write_file(const char *path, const uint8_t *data, size_t n, int mode);
int pg_acme_rename(const char *from, const char *to);
/* 1 when a wait status says the child exited with 0. */
int pg_acme_exit_ok(int status);

#ifdef __cplusplus
}
#endif

#endif /* GARUDA_ACME_H */
