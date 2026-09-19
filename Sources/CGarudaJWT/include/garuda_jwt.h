/* The signatures JSON Web Tokens use (RFC 7518), over the system's libcrypto.
 *
 * What TLS needs is in avian_crypto.h; a JWT needs other things of the same
 * library -- RSA with PKCS #1 v1.5, HMAC with SHA-512, verifying rather than
 * signing, and public keys given as JWK numbers -- so they live beside the one
 * framework feature that uses them.
 *
 * Every function returns a negative number, or NULL, on failure, and never
 * aborts: a token is untrusted input. */

#ifndef GARUDA_JWT_H
#define GARUDA_JWT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Algorithms, as JWS names them. */
#define GJW_HS256 1
#define GJW_HS384 2
#define GJW_HS512 3
#define GJW_RS256 4
#define GJW_RS384 5
#define GJW_RS512 6
#define GJW_PS256 7
#define GJW_PS384 8
#define GJW_PS512 9
#define GJW_ES256 10
#define GJW_ES384 11
#define GJW_ES512 12
#define GJW_EDDSA 13

/* Key types. */
#define GJW_KEY_RSA 1
#define GJW_KEY_EC_P256 2
#define GJW_KEY_EC_P384 3
#define GJW_KEY_EC_P521 4
#define GJW_KEY_ED25519 5

typedef struct gjw_key gjw_key;

/* HMAC of `data` with `key` for HS256/384/512. Returns the MAC's length. */
int gjw_hmac(int alg, const uint8_t *key, size_t key_len, const uint8_t *data, size_t data_len,
             uint8_t *out, size_t out_cap);

/* An HMAC keyed once, for many MACs under the same key: the digest looked
 * up and the key's pads hashed at the start, not for every token. */
typedef struct gjw_mac gjw_mac;
gjw_mac *gjw_mac_new(int alg, const uint8_t *key, size_t key_len);
void gjw_mac_free(gjw_mac *mac);
/* The MAC of `data`, from a copy of the keyed state, so threads may share
 * one `gjw_mac`. Returns the MAC's length. */
int gjw_mac_compute(const gjw_mac *mac, const uint8_t *data, size_t data_len, uint8_t *out, size_t out_cap);

/* A key from PEM: a public key, a certificate, or a private key (PKCS #8, or
 * the traditional RSA and EC forms). `has_private` says which it was. */
gjw_key *gjw_key_from_pem(const char *pem, size_t len, int *has_private);

/* Public keys from a JWK's members, as unsigned big-endian bytes. */
gjw_key *gjw_key_from_rsa(const uint8_t *n, size_t n_len, const uint8_t *e, size_t e_len);
gjw_key *gjw_key_from_ec(int type, const uint8_t *x, size_t x_len, const uint8_t *y, size_t y_len);
gjw_key *gjw_key_from_ed25519(const uint8_t *x, size_t x_len);

/* A new private key: GJW_KEY_RSA (2048 bits, or `bits`), an EC curve, or
 * Ed25519. */
gjw_key *gjw_key_generate(int type, int bits);

void gjw_key_free(gjw_key *key);

/* GJW_KEY_*, or -1. */
int gjw_key_type(const gjw_key *key);

/* The public key as PEM (SubjectPublicKeyInfo), or the private key as PKCS #8
 * PEM. Returns the length written, or the length needed when `out` is NULL. */
long gjw_key_pem(const gjw_key *key, int private_key, char *out, size_t cap);

/* The public key's JWK members, as unsigned big-endian bytes: n and e for
 * RSA, x and y for EC, x for Ed25519. Returns 0. Lengths in and out. */
int gjw_key_rsa_numbers(const gjw_key *key, uint8_t *n, size_t *n_len, uint8_t *e, size_t *e_len);
int gjw_key_ec_point(const gjw_key *key, uint8_t *x, size_t *x_len, uint8_t *y, size_t *y_len);
int gjw_key_raw_public(const gjw_key *key, uint8_t *out, size_t *out_len);

/* Signs `data` with a private key. ECDSA signatures are written as JWS has
 * them: r and s, each the curve's size, not DER. Returns the length. */
long gjw_sign(const gjw_key *key, int alg, const uint8_t *data, size_t data_len, uint8_t *out, size_t cap);

/* Whether `sig` is `data` signed by `key` with `alg`: 1 yes, 0 no, -1 when
 * the algorithm and key do not belong together. */
int gjw_verify(const gjw_key *key, int alg, const uint8_t *data, size_t data_len,
               const uint8_t *sig, size_t sig_len);

#ifdef __cplusplus
}
#endif

#endif
