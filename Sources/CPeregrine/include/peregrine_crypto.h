/* Cryptographic primitives for QUIC and its TLS 1.3 handshake.
 *
 * QUIC cannot use OpenSSL's TLS the way HTTP/1 and HTTP/2 do. TLS over TCP
 * owns a record layer; QUIC replaces that record layer entirely and asks TLS
 * only for a handshake transcript and a set of secrets. So this shim exposes
 * primitives -- hash, HKDF, AEAD, key exchange, signing -- and the handshake
 * state machine above them is ours.
 *
 * Same rule as Python.h and OpenSSL's ssl.h: no OpenSSL header is reachable
 * from anything Swift imports. Everything here is opaque pointers and byte
 * buffers.
 *
 * Every function returns 0 or a byte count on success and a negative number on
 * failure. Buffers are caller-owned; nothing here allocates on behalf of the
 * caller except the explicit _new/_free pairs.
 */
#ifndef PEREGRINE_CRYPTO_H
#define PEREGRINE_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Whether this binary has the primitives at all. Everything below returns a
 * failure when this is 0. */
int pg_crypto_available(void);

/* Randomness -- for connection IDs, stateless reset tokens and the
 * handshake's private key -- is pg_random_bytes() in peregrine_sys.h. */

/* --------------------------------------------------------------------------
 * Hashing
 * ----------------------------------------------------------------------- */
#define PG_SHA256 0
#define PG_SHA384 1

/* Digest length in bytes, or -1 for an unknown algorithm. */
int pg_hash_len(int alg);
int pg_hash(int alg, const void *data, size_t n, unsigned char *out);

/* An incremental hash, for the handshake transcript. The transcript is hashed
 * once as messages arrive but read at several points, so `snapshot` takes the
 * current digest without ending the context. */
typedef struct pg_hash_ctx pg_hash_ctx;
pg_hash_ctx *pg_hash_new(int alg);
void pg_hash_update(pg_hash_ctx *ctx, const void *data, size_t n);
int pg_hash_snapshot(pg_hash_ctx *ctx, unsigned char *out);
void pg_hash_free(pg_hash_ctx *ctx);

/* --------------------------------------------------------------------------
 * HMAC and HKDF
 * ----------------------------------------------------------------------- */
int pg_hmac(int alg, const void *key, size_t key_len,
            const void *data, size_t data_len, unsigned char *out);

/* RFC 5869. `salt` may be NULL, which means a string of zeros. Writes exactly
 * pg_hash_len(alg) bytes. */
int pg_hkdf_extract(int alg, const void *salt, size_t salt_len,
                    const void *ikm, size_t ikm_len, unsigned char *out);
int pg_hkdf_expand(int alg, const void *prk, size_t prk_len,
                   const void *info, size_t info_len,
                   unsigned char *out, size_t out_len);

/* --------------------------------------------------------------------------
 * AEAD
 *
 * Packet protection. The nonce is always 12 bytes; QUIC builds it by xoring
 * the packet number into the static IV.
 * ----------------------------------------------------------------------- */
#define PG_AEAD_AES128GCM         0
#define PG_AEAD_AES256GCM         1
#define PG_AEAD_CHACHA20POLY1305  2

/* Key length for an AEAD, or -1. The tag is always 16 bytes. */
int pg_aead_key_len(int alg);

typedef struct pg_aead pg_aead;
pg_aead *pg_aead_new(int alg, const unsigned char *key);
void pg_aead_free(pg_aead *a);

/* `out` needs pt_len + 16 bytes. Returns bytes written, or -1. */
long pg_aead_seal(pg_aead *a, const unsigned char nonce[12],
                  const void *aad, size_t aad_len,
                  const void *pt, size_t pt_len, unsigned char *out);
/* Returns plaintext length, or -1 when the tag does not verify. `out` may
 * overlap `ct` only if it is the same address. */
long pg_aead_open(pg_aead *a, const unsigned char nonce[12],
                  const void *aad, size_t aad_len,
                  const void *ct, size_t ct_len, unsigned char *out);

/* --------------------------------------------------------------------------
 * Header protection
 *
 * A five-byte mask derived from a sample of the packet's ciphertext, which is
 * xored over the first byte and the packet number. AES uses one ECB block;
 * ChaCha20 uses the sample as counter and nonce.
 * ----------------------------------------------------------------------- */
typedef struct pg_hp pg_hp;
pg_hp *pg_hp_new(int alg, const unsigned char *key);
void pg_hp_free(pg_hp *h);
int pg_hp_mask(pg_hp *h, const unsigned char sample[16], unsigned char mask[5]);

/* --------------------------------------------------------------------------
 * Key exchange
 * ----------------------------------------------------------------------- */
#define PG_KEX_X25519  0
#define PG_KEX_P256    1

typedef struct pg_kex pg_kex;
/* Generates an ephemeral key pair. */
pg_kex *pg_kex_new(int group);
void pg_kex_free(pg_kex *k);
/* Our public key in TLS wire form (32 bytes for X25519, 65 uncompressed for
 * P-256). Returns the length, or -1. */
long pg_kex_public(pg_kex *k, unsigned char *out, size_t out_len);
/* The shared secret. Returns its length, or -1 when the peer's key is bad. */
long pg_kex_derive(pg_kex *k, const unsigned char *peer, size_t peer_len,
                   unsigned char *out, size_t out_len);

/* --------------------------------------------------------------------------
 * Certificate and signing
 *
 * TLS 1.3 signature schemes, as they appear on the wire.
 * ----------------------------------------------------------------------- */
#define PG_SIG_RSA_PSS_RSAE_SHA256  0x0804
#define PG_SIG_RSA_PSS_RSAE_SHA384  0x0805
#define PG_SIG_RSA_PSS_RSAE_SHA512  0x0806
#define PG_SIG_ECDSA_SECP256R1_SHA256 0x0403
#define PG_SIG_ECDSA_SECP384R1_SHA384 0x0503
#define PG_SIG_ED25519              0x0807

typedef struct pg_certkey pg_certkey;
/* Loads a PEM chain and its private key. On failure returns NULL and writes a
 * reason into `err`. */
pg_certkey *pg_certkey_load(const char *cert_path, const char *key_path,
                            char *err, size_t err_len);
void pg_certkey_free(pg_certkey *ck);

/* Number of certificates in the chain, leaf first. */
int pg_certkey_chain_count(pg_certkey *ck);
/* DER of one certificate. With `out` NULL, returns the length needed. */
long pg_certkey_cert_der(pg_certkey *ck, int index,
                         unsigned char *out, size_t out_len);
/* Signature schemes this key can produce, in our order of preference. Returns
 * how many were written. */
int pg_certkey_schemes(pg_certkey *ck, uint16_t *out, int max);
/* Signs `msg` (the caller has already built the TLS 1.3 signature input).
 * Returns the signature length, or -1. */
long pg_certkey_sign(pg_certkey *ck, uint16_t scheme,
                     const void *msg, size_t msg_len,
                     unsigned char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* PEREGRINE_CRYPTO_H */
