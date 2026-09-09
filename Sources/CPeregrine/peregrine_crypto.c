/* Cryptographic primitives for QUIC.
 *
 * QUIC does not use OpenSSL's TLS. It replaces the TLS record layer with its
 * own packet protection and asks the handshake only for secrets, so what is
 * needed here is the layer *below* SSL_read: hash, HKDF, AEAD, key agreement
 * and a signature over the transcript. The handshake state machine that drives
 * them lives in Swift.
 *
 * HKDF is written out by hand rather than driven through EVP_PKEY_HKDF. It is
 * fifteen lines on top of HMAC, and doing it here avoids the API that changed
 * shape between OpenSSL 1.1 and 3.0 for no gain.
 */

#define _GNU_SOURCE 1

#include "peregrine_crypto.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__has_include)
#  if !__has_include(<openssl/evp.h>)
#    define PG_NO_OPENSSL 1
#  endif
#endif

#ifdef PG_NO_OPENSSL

int pg_crypto_available(void) { return 0; }
int pg_hash_len(int alg) { (void)alg; return -1; }
int pg_hash(int a, const void *d, size_t n, unsigned char *o) {
    (void)a; (void)d; (void)n; (void)o; return -1;
}
pg_hash_ctx *pg_hash_new(int alg) { (void)alg; return NULL; }
void pg_hash_update(pg_hash_ctx *c, const void *d, size_t n) { (void)c; (void)d; (void)n; }
int pg_hash_snapshot(pg_hash_ctx *c, unsigned char *o) { (void)c; (void)o; return -1; }
void pg_hash_free(pg_hash_ctx *c) { (void)c; }
int pg_hmac(int a, const void *k, size_t kl, const void *d, size_t dl, unsigned char *o) {
    (void)a; (void)k; (void)kl; (void)d; (void)dl; (void)o; return -1;
}
int pg_hkdf_extract(int a, const void *s, size_t sl, const void *i, size_t il, unsigned char *o) {
    (void)a; (void)s; (void)sl; (void)i; (void)il; (void)o; return -1;
}
int pg_hkdf_expand(int a, const void *p, size_t pl, const void *i, size_t il,
                   unsigned char *o, size_t ol) {
    (void)a; (void)p; (void)pl; (void)i; (void)il; (void)o; (void)ol; return -1;
}
int pg_aead_key_len(int alg) { (void)alg; return -1; }
pg_aead *pg_aead_new(int alg, const unsigned char *key) { (void)alg; (void)key; return NULL; }
void pg_aead_free(pg_aead *a) { (void)a; }
long pg_aead_seal(pg_aead *a, const unsigned char n[12], const void *ad, size_t adl,
                  const void *p, size_t pl, unsigned char *o) {
    (void)a; (void)n; (void)ad; (void)adl; (void)p; (void)pl; (void)o; return -1;
}
long pg_aead_open(pg_aead *a, const unsigned char n[12], const void *ad, size_t adl,
                  const void *c, size_t cl, unsigned char *o) {
    (void)a; (void)n; (void)ad; (void)adl; (void)c; (void)cl; (void)o; return -1;
}
pg_hp *pg_hp_new(int alg, const unsigned char *key) { (void)alg; (void)key; return NULL; }
void pg_hp_free(pg_hp *h) { (void)h; }
int pg_hp_mask(pg_hp *h, const unsigned char s[16], unsigned char m[5]) {
    (void)h; (void)s; (void)m; return -1;
}
pg_kex *pg_kex_new(int group) { (void)group; return NULL; }
void pg_kex_free(pg_kex *k) { (void)k; }
long pg_kex_public(pg_kex *k, unsigned char *o, size_t ol) { (void)k; (void)o; (void)ol; return -1; }
long pg_kex_derive(pg_kex *k, const unsigned char *p, size_t pl,
                   unsigned char *o, size_t ol) {
    (void)k; (void)p; (void)pl; (void)o; (void)ol; return -1;
}
pg_certkey *pg_certkey_load(const char *c, const char *k, char *err, size_t el) {
    (void)c; (void)k;
    if (err && el) snprintf(err, el, "this binary was built without OpenSSL");
    return NULL;
}
void pg_certkey_free(pg_certkey *ck) { (void)ck; }
int pg_certkey_chain_count(pg_certkey *ck) { (void)ck; return 0; }
long pg_certkey_cert_der(pg_certkey *ck, int i, unsigned char *o, size_t ol) {
    (void)ck; (void)i; (void)o; (void)ol; return -1;
}
int pg_certkey_schemes(pg_certkey *ck, uint16_t *o, int m) {
    (void)ck; (void)o; (void)m; return 0;
}
long pg_certkey_sign(pg_certkey *ck, uint16_t s, const void *m, size_t ml,
                     unsigned char *o, size_t ol) {
    (void)ck; (void)s; (void)m; (void)ml; (void)o; (void)ol; return -1;
}

#else

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/err.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#  include <openssl/core_names.h>
#  include <openssl/params.h>
#endif

int pg_crypto_available(void) { return 1; }

/* ---------------------------------------------------------------------------
 * Hashing
 * ------------------------------------------------------------------------ */

static const EVP_MD *md_for(int alg) {
    switch (alg) {
    case PG_SHA256: return EVP_sha256();
    case PG_SHA384: return EVP_sha384();
    default: return NULL;
    }
}

int pg_hash_len(int alg) {
    switch (alg) {
    case PG_SHA256: return 32;
    case PG_SHA384: return 48;
    default: return -1;
    }
}

int pg_hash(int alg, const void *data, size_t n, unsigned char *out) {
    const EVP_MD *md = md_for(alg);
    if (!md) return -1;
    unsigned int len = 0;
    if (EVP_Digest(data, n, out, &len, md, NULL) != 1) return -1;
    return (int)len;
}

struct pg_hash_ctx {
    EVP_MD_CTX *ctx;
    const EVP_MD *md;
};

pg_hash_ctx *pg_hash_new(int alg) {
    const EVP_MD *md = md_for(alg);
    if (!md) return NULL;
    pg_hash_ctx *h = calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->md = md;
    h->ctx = EVP_MD_CTX_new();
    if (!h->ctx || EVP_DigestInit_ex(h->ctx, md, NULL) != 1) {
        if (h->ctx) EVP_MD_CTX_free(h->ctx);
        free(h);
        return NULL;
    }
    return h;
}

void pg_hash_update(pg_hash_ctx *h, const void *data, size_t n) {
    if (!h || n == 0) return;
    EVP_DigestUpdate(h->ctx, data, n);
}

/* The transcript is read at several points in the handshake but only ever
 * appended to, so the digest is taken from a copy. */
int pg_hash_snapshot(pg_hash_ctx *h, unsigned char *out) {
    if (!h) return -1;
    EVP_MD_CTX *copy = EVP_MD_CTX_new();
    if (!copy) return -1;
    unsigned int len = 0;
    int ok = EVP_MD_CTX_copy_ex(copy, h->ctx) == 1
          && EVP_DigestFinal_ex(copy, out, &len) == 1;
    EVP_MD_CTX_free(copy);
    return ok ? (int)len : -1;
}

void pg_hash_free(pg_hash_ctx *h) {
    if (!h) return;
    EVP_MD_CTX_free(h->ctx);
    free(h);
}

/* ---------------------------------------------------------------------------
 * HMAC and HKDF (RFC 5869)
 * ------------------------------------------------------------------------ */

int pg_hmac(int alg, const void *key, size_t key_len,
            const void *data, size_t data_len, unsigned char *out) {
    const EVP_MD *md = md_for(alg);
    if (!md) return -1;
    unsigned int len = 0;
    /* HMAC() with a zero-length key needs a non-NULL pointer. */
    static const unsigned char empty = 0;
    const unsigned char *k = key_len ? (const unsigned char *)key : &empty;
    if (!HMAC(md, k, (int)key_len, (const unsigned char *)data, data_len, out, &len)) {
        return -1;
    }
    return (int)len;
}

int pg_hkdf_extract(int alg, const void *salt, size_t salt_len,
                    const void *ikm, size_t ikm_len, unsigned char *out) {
    int n = pg_hash_len(alg);
    if (n < 0) return -1;
    unsigned char zeros[48];
    if (!salt || salt_len == 0) {
        memset(zeros, 0, (size_t)n);
        salt = zeros;
        salt_len = (size_t)n;
    }
    return pg_hmac(alg, salt, salt_len, ikm, ikm_len, out) == n ? n : -1;
}

int pg_hkdf_expand(int alg, const void *prk, size_t prk_len,
                   const void *info, size_t info_len,
                   unsigned char *out, size_t out_len) {
    int hl = pg_hash_len(alg);
    if (hl < 0) return -1;
    if (out_len > 255u * (size_t)hl) return -1;
    /* An HkdfLabel is at most 514 bytes, and every one this server builds is
     * far shorter, so each round fits in a stack buffer and HMAC stays a
     * one-shot call. */
    if (info_len > 576) return -1;

    unsigned char round[48 + 576 + 1];
    unsigned char block[48];
    size_t done = 0;
    size_t block_len = 0;
    unsigned char counter = 1;

    while (done < out_len) {
        size_t n = 0;
        if (block_len) { memcpy(round, block, block_len); n = block_len; }
        if (info_len) { memcpy(round + n, info, info_len); n += info_len; }
        round[n++] = counter;
        if (pg_hmac(alg, prk, prk_len, round, n, block) != hl) return -1;
        block_len = (size_t)hl;

        size_t take = out_len - done;
        if (take > block_len) take = block_len;
        memcpy(out + done, block, take);
        done += take;
        counter++;
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * AEAD
 * ------------------------------------------------------------------------ */

struct pg_aead {
    EVP_CIPHER_CTX *enc;
    EVP_CIPHER_CTX *dec;
};

static const EVP_CIPHER *aead_cipher(int alg) {
    switch (alg) {
    case PG_AEAD_AES128GCM: return EVP_aes_128_gcm();
    case PG_AEAD_AES256GCM: return EVP_aes_256_gcm();
    case PG_AEAD_CHACHA20POLY1305: return EVP_chacha20_poly1305();
    default: return NULL;
    }
}

int pg_aead_key_len(int alg) {
    switch (alg) {
    case PG_AEAD_AES128GCM: return 16;
    case PG_AEAD_AES256GCM: return 32;
    case PG_AEAD_CHACHA20POLY1305: return 32;
    default: return -1;
    }
}

/* The key is bound once. Only the nonce changes per packet, and both GCM and
 * ChaCha20-Poly1305 let it be set on its own, which is what makes protecting a
 * packet cost one EVP call chain rather than a key schedule. */
pg_aead *pg_aead_new(int alg, const unsigned char *key) {
    const EVP_CIPHER *c = aead_cipher(alg);
    if (!c) return NULL;
    pg_aead *a = calloc(1, sizeof(*a));
    if (!a) return NULL;
    a->enc = EVP_CIPHER_CTX_new();
    a->dec = EVP_CIPHER_CTX_new();
    if (!a->enc || !a->dec) goto fail;
    if (EVP_EncryptInit_ex(a->enc, c, NULL, NULL, NULL) != 1) goto fail;
    if (EVP_CIPHER_CTX_ctrl(a->enc, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) != 1) goto fail;
    if (EVP_EncryptInit_ex(a->enc, NULL, NULL, key, NULL) != 1) goto fail;
    if (EVP_DecryptInit_ex(a->dec, c, NULL, NULL, NULL) != 1) goto fail;
    if (EVP_CIPHER_CTX_ctrl(a->dec, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) != 1) goto fail;
    if (EVP_DecryptInit_ex(a->dec, NULL, NULL, key, NULL) != 1) goto fail;
    return a;
fail:
    pg_aead_free(a);
    return NULL;
}

void pg_aead_free(pg_aead *a) {
    if (!a) return;
    if (a->enc) EVP_CIPHER_CTX_free(a->enc);
    if (a->dec) EVP_CIPHER_CTX_free(a->dec);
    free(a);
}

long pg_aead_seal(pg_aead *a, const unsigned char nonce[12],
                  const void *aad, size_t aad_len,
                  const void *pt, size_t pt_len, unsigned char *out) {
    if (!a) return -1;
    int len = 0, total = 0;
    if (EVP_EncryptInit_ex(a->enc, NULL, NULL, NULL, nonce) != 1) return -1;
    if (aad_len && EVP_EncryptUpdate(a->enc, NULL, &len,
                                     (const unsigned char *)aad, (int)aad_len) != 1) {
        return -1;
    }
    if (pt_len) {
        if (EVP_EncryptUpdate(a->enc, out, &len,
                              (const unsigned char *)pt, (int)pt_len) != 1) return -1;
        total = len;
    }
    if (EVP_EncryptFinal_ex(a->enc, out + total, &len) != 1) return -1;
    total += len;
    if (EVP_CIPHER_CTX_ctrl(a->enc, EVP_CTRL_AEAD_GET_TAG, 16, out + total) != 1) return -1;
    return (long)total + 16;
}

long pg_aead_open(pg_aead *a, const unsigned char nonce[12],
                  const void *aad, size_t aad_len,
                  const void *ct, size_t ct_len, unsigned char *out) {
    if (!a || ct_len < 16) return -1;
    size_t body = ct_len - 16;
    const unsigned char *in = (const unsigned char *)ct;
    unsigned char tag[16];
    memcpy(tag, in + body, 16);

    int len = 0, total = 0;
    if (EVP_DecryptInit_ex(a->dec, NULL, NULL, NULL, nonce) != 1) return -1;
    if (aad_len && EVP_DecryptUpdate(a->dec, NULL, &len,
                                     (const unsigned char *)aad, (int)aad_len) != 1) {
        return -1;
    }
    if (body) {
        if (EVP_DecryptUpdate(a->dec, out, &len, in, (int)body) != 1) return -1;
        total = len;
    }
    if (EVP_CIPHER_CTX_ctrl(a->dec, EVP_CTRL_AEAD_SET_TAG, 16, tag) != 1) return -1;
    if (EVP_DecryptFinal_ex(a->dec, out + total, &len) != 1) return -1;
    return (long)total + len;
}

/* ---------------------------------------------------------------------------
 * Header protection
 * ------------------------------------------------------------------------ */

struct pg_hp {
    EVP_CIPHER_CTX *ctx;
    int chacha;
};

pg_hp *pg_hp_new(int alg, const unsigned char *key) {
    pg_hp *h = calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->ctx = EVP_CIPHER_CTX_new();
    if (!h->ctx) { free(h); return NULL; }

    int ok;
    switch (alg) {
    case PG_AEAD_AES128GCM:
        ok = EVP_EncryptInit_ex(h->ctx, EVP_aes_128_ecb(), NULL, key, NULL) == 1;
        break;
    case PG_AEAD_AES256GCM:
        ok = EVP_EncryptInit_ex(h->ctx, EVP_aes_256_ecb(), NULL, key, NULL) == 1;
        break;
    case PG_AEAD_CHACHA20POLY1305:
        /* The sample becomes counter and nonce, so the key is bound now and
         * the IV per call. */
        h->chacha = 1;
        ok = EVP_EncryptInit_ex(h->ctx, EVP_chacha20(), NULL, key, NULL) == 1;
        break;
    default:
        ok = 0;
    }
    if (!ok) { EVP_CIPHER_CTX_free(h->ctx); free(h); return NULL; }
    EVP_CIPHER_CTX_set_padding(h->ctx, 0);
    return h;
}

void pg_hp_free(pg_hp *h) {
    if (!h) return;
    EVP_CIPHER_CTX_free(h->ctx);
    free(h);
}

int pg_hp_mask(pg_hp *h, const unsigned char sample[16], unsigned char mask[5]) {
    if (!h) return -1;
    int len = 0;
    if (h->chacha) {
        /* RFC 9001 section 5.4.4: the sample is the 32-bit counter followed by
         * the 96-bit nonce, and the mask is five bytes of key stream. OpenSSL
         * takes both as one 16-byte IV. */
        static const unsigned char zeros[5] = {0, 0, 0, 0, 0};
        if (EVP_EncryptInit_ex(h->ctx, NULL, NULL, NULL, sample) != 1) return -1;
        if (EVP_EncryptUpdate(h->ctx, mask, &len, zeros, 5) != 1) return -1;
        return 0;
    }
    unsigned char block[32];
    if (EVP_EncryptUpdate(h->ctx, block, &len, sample, 16) != 1) return -1;
    if (len < 5) return -1;
    memcpy(mask, block, 5);
    return 0;
}

/* ---------------------------------------------------------------------------
 * Key exchange
 * ------------------------------------------------------------------------ */

struct pg_kex {
    EVP_PKEY *key;
    int group;
};

pg_kex *pg_kex_new(int group) {
    int nid;
    switch (group) {
    case PG_KEX_X25519: nid = EVP_PKEY_X25519; break;
    case PG_KEX_P256: nid = EVP_PKEY_EC; break;
    default: return NULL;
    }

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(nid, NULL);
    if (!ctx) return NULL;
    EVP_PKEY *key = NULL;
    int ok = EVP_PKEY_keygen_init(ctx) == 1;
    if (ok && group == PG_KEX_P256) {
        ok = EVP_PKEY_CTX_set_ec_paramgen_curve_nid(ctx, NID_X9_62_prime256v1) == 1;
    }
    ok = ok && EVP_PKEY_keygen(ctx, &key) == 1;
    EVP_PKEY_CTX_free(ctx);
    if (!ok) { if (key) EVP_PKEY_free(key); return NULL; }

    pg_kex *k = calloc(1, sizeof(*k));
    if (!k) { EVP_PKEY_free(key); return NULL; }
    k->key = key;
    k->group = group;
    return k;
}

void pg_kex_free(pg_kex *k) {
    if (!k) return;
    if (k->key) EVP_PKEY_free(k->key);
    free(k);
}

long pg_kex_public(pg_kex *k, unsigned char *out, size_t out_len) {
    if (!k) return -1;
    if (k->group == PG_KEX_X25519) {
        size_t n = out_len;
        if (EVP_PKEY_get_raw_public_key(k->key, out, &n) != 1) return -1;
        return (long)n;
    }
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    unsigned char *buf = NULL;
    size_t n = EVP_PKEY_get1_encoded_public_key(k->key, &buf);
    if (n == 0 || !buf) return -1;
    long rc = -1;
    if (n <= out_len) { memcpy(out, buf, n); rc = (long)n; }
    OPENSSL_free(buf);
    return rc;
#else
    unsigned char *buf = NULL;
    size_t n = EVP_PKEY_get1_tls_encodedpoint(k->key, &buf);
    if (n == 0 || !buf) return -1;
    long rc = -1;
    if (n <= out_len) { memcpy(out, buf, n); rc = (long)n; }
    OPENSSL_free(buf);
    return rc;
#endif
}

long pg_kex_derive(pg_kex *k, const unsigned char *peer, size_t peer_len,
                   unsigned char *out, size_t out_len) {
    if (!k) return -1;
    EVP_PKEY *pub = NULL;

    if (k->group == PG_KEX_X25519) {
        if (peer_len != 32) return -1;
        pub = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, peer, peer_len);
    } else {
        /* A P-256 share arrives as an uncompressed point, which means nothing
         * without the curve it belongs to; both are supplied together. */
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
        OSSL_PARAM params[3];
        params[0] = OSSL_PARAM_construct_utf8_string(
            OSSL_PKEY_PARAM_GROUP_NAME, (char *)"prime256v1", 0);
        params[1] = OSSL_PARAM_construct_octet_string(
            OSSL_PKEY_PARAM_PUB_KEY, (void *)(uintptr_t)peer, peer_len);
        params[2] = OSSL_PARAM_construct_end();

        EVP_PKEY_CTX *pc = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
        if (!pc) return -1;
        int ok = EVP_PKEY_fromdata_init(pc) == 1
              && EVP_PKEY_fromdata(pc, &pub, EVP_PKEY_PUBLIC_KEY, params) == 1;
        EVP_PKEY_CTX_free(pc);
        if (!ok) { if (pub) EVP_PKEY_free(pub); return -1; }
#else
        EC_KEY *ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
        if (!ec) return -1;
        pub = EVP_PKEY_new();
        if (!pub || EVP_PKEY_assign_EC_KEY(pub, ec) != 1) {
            EC_KEY_free(ec);
            if (pub) EVP_PKEY_free(pub);
            return -1;
        }
        if (EVP_PKEY_set1_tls_encodedpoint(pub, peer, peer_len) != 1) {
            EVP_PKEY_free(pub);
            return -1;
        }
#endif
    }
    if (!pub) return -1;

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(k->key, NULL);
    long rc = -1;
    if (ctx && EVP_PKEY_derive_init(ctx) == 1
            && EVP_PKEY_derive_set_peer(ctx, pub) == 1) {
        size_t n = out_len;
        if (EVP_PKEY_derive(ctx, out, &n) == 1) rc = (long)n;
    }
    if (ctx) EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pub);
    return rc;
}

/* ---------------------------------------------------------------------------
 * Certificate and signing
 * ------------------------------------------------------------------------ */

#define PG_MAX_CHAIN 8

struct pg_certkey {
    X509 *chain[PG_MAX_CHAIN];
    int count;
    EVP_PKEY *key;
};

static void ossl_error(char *err, size_t err_len, const char *what) {
    if (!err || !err_len) return;
    unsigned long e = ERR_get_error();
    char detail[160];
    if (e) {
        ERR_error_string_n(e, detail, sizeof(detail));
        snprintf(err, err_len, "%s: %s", what, detail);
    } else {
        snprintf(err, err_len, "%s", what);
    }
}

pg_certkey *pg_certkey_load(const char *cert_path, const char *key_path,
                            char *err, size_t err_len) {
    ERR_clear_error();
    pg_certkey *ck = calloc(1, sizeof(*ck));
    if (!ck) return NULL;

    BIO *bio = BIO_new_file(cert_path, "r");
    if (!bio) {
        ossl_error(err, err_len, "cannot read certificate");
        free(ck);
        return NULL;
    }
    while (ck->count < PG_MAX_CHAIN) {
        X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (!cert) break;
        ck->chain[ck->count++] = cert;
    }
    BIO_free(bio);
    if (ck->count == 0) {
        ossl_error(err, err_len, "no certificate in file");
        free(ck);
        return NULL;
    }
    /* The loop above stops on the end of the file, which OpenSSL reports the
     * same way it reports a malformed block. */
    ERR_clear_error();

    bio = BIO_new_file(key_path, "r");
    if (bio) {
        ck->key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
        BIO_free(bio);
    }
    if (!ck->key) {
        ossl_error(err, err_len, "cannot read private key");
        pg_certkey_free(ck);
        return NULL;
    }
    if (X509_check_private_key(ck->chain[0], ck->key) != 1) {
        ossl_error(err, err_len, "private key does not match certificate");
        pg_certkey_free(ck);
        return NULL;
    }
    return ck;
}

void pg_certkey_free(pg_certkey *ck) {
    if (!ck) return;
    for (int i = 0; i < ck->count; i++) X509_free(ck->chain[i]);
    if (ck->key) EVP_PKEY_free(ck->key);
    free(ck);
}

int pg_certkey_chain_count(pg_certkey *ck) { return ck ? ck->count : 0; }

long pg_certkey_cert_der(pg_certkey *ck, int index,
                         unsigned char *out, size_t out_len) {
    if (!ck || index < 0 || index >= ck->count) return -1;
    int n = i2d_X509(ck->chain[index], NULL);
    if (n <= 0) return -1;
    if (!out) return n;
    if ((size_t)n > out_len) return -1;
    unsigned char *p = out;
    return i2d_X509(ck->chain[index], &p);
}

int pg_certkey_schemes(pg_certkey *ck, uint16_t *out, int max) {
    if (!ck || !ck->key || max <= 0) return 0;
    int n = 0;
    switch (EVP_PKEY_base_id(ck->key)) {
    case EVP_PKEY_RSA:
    case EVP_PKEY_RSA_PSS:
        if (n < max) out[n++] = PG_SIG_RSA_PSS_RSAE_SHA256;
        if (n < max) out[n++] = PG_SIG_RSA_PSS_RSAE_SHA384;
        if (n < max) out[n++] = PG_SIG_RSA_PSS_RSAE_SHA512;
        break;
    case EVP_PKEY_EC:
        /* The curve fixes the digest, so a P-256 key can only ever produce
         * ecdsa_secp256r1_sha256. */
        if (EVP_PKEY_bits(ck->key) >= 384) {
            if (n < max) out[n++] = PG_SIG_ECDSA_SECP384R1_SHA384;
        } else {
            if (n < max) out[n++] = PG_SIG_ECDSA_SECP256R1_SHA256;
        }
        break;
    case EVP_PKEY_ED25519:
        if (n < max) out[n++] = PG_SIG_ED25519;
        break;
    default:
        break;
    }
    return n;
}

long pg_certkey_sign(pg_certkey *ck, uint16_t scheme,
                     const void *msg, size_t msg_len,
                     unsigned char *out, size_t out_len) {
    if (!ck || !ck->key) return -1;
    ERR_clear_error();

    const EVP_MD *md = NULL;
    int pss = 0;
    switch (scheme) {
    case PG_SIG_RSA_PSS_RSAE_SHA256: md = EVP_sha256(); pss = 1; break;
    case PG_SIG_RSA_PSS_RSAE_SHA384: md = EVP_sha384(); pss = 1; break;
    case PG_SIG_RSA_PSS_RSAE_SHA512: md = EVP_sha512(); pss = 1; break;
    case PG_SIG_ECDSA_SECP256R1_SHA256: md = EVP_sha256(); break;
    case PG_SIG_ECDSA_SECP384R1_SHA384: md = EVP_sha384(); break;
    case PG_SIG_ED25519: md = NULL; break;
    default: return -1;
    }

    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx) return -1;
    EVP_PKEY_CTX *pctx = NULL;
    long rc = -1;
    size_t n = out_len;

    if (EVP_DigestSignInit(ctx, &pctx, md, NULL, ck->key) != 1) goto done;
    if (pss) {
        if (EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) != 1) goto done;
        /* TLS 1.3 fixes the salt at the digest length. */
        if (EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) != 1) goto done;
    }
    if (scheme == PG_SIG_ED25519) {
        /* Ed25519 hashes internally and has no streaming interface. */
        if (EVP_DigestSign(ctx, out, &n, (const unsigned char *)msg, msg_len) != 1) goto done;
    } else {
        if (EVP_DigestSignUpdate(ctx, msg, msg_len) != 1) goto done;
        if (EVP_DigestSignFinal(ctx, out, &n) != 1) goto done;
    }
    rc = (long)n;
done:
    EVP_MD_CTX_free(ctx);
    return rc;
}

#endif /* PG_NO_OPENSSL */
