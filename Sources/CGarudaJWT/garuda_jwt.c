#include "garuda_jwt.h"

#include <string.h>

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/param_build.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>

struct gjw_key {
    EVP_PKEY *pkey;
    int type;
};

static const EVP_MD *digest_for(int alg) {
    switch (alg) {
    case GJW_HS256: case GJW_RS256: case GJW_PS256: case GJW_ES256: return EVP_sha256();
    case GJW_HS384: case GJW_RS384: case GJW_PS384: case GJW_ES384: return EVP_sha384();
    case GJW_HS512: case GJW_RS512: case GJW_PS512: case GJW_ES512: return EVP_sha512();
    default: return NULL;
    }
}

int gjw_hmac(int alg, const uint8_t *key, size_t key_len, const uint8_t *data, size_t data_len,
             uint8_t *out, size_t out_cap) {
    if (alg < GJW_HS256 || alg > GJW_HS512) return -1;
    const EVP_MD *md = digest_for(alg);
    if (out_cap < (size_t)EVP_MD_get_size(md)) return -1;
    unsigned int len = 0;
    static const uint8_t empty = 0;
    if (!HMAC(md, key_len ? key : &empty, (int)key_len, data_len ? data : &empty, data_len, out, &len)) return -1;
    return (int)len;
}

static int classify(EVP_PKEY *pkey) {
    switch (EVP_PKEY_get_base_id(pkey)) {
    case EVP_PKEY_RSA: return GJW_KEY_RSA;
    case EVP_PKEY_ED25519: return GJW_KEY_ED25519;
    case EVP_PKEY_EC: {
        char name[64];
        size_t len = 0;
        if (!EVP_PKEY_get_utf8_string_param(pkey, OSSL_PKEY_PARAM_GROUP_NAME, name, sizeof name, &len)) return -1;
        if (strcmp(name, "prime256v1") == 0 || strcmp(name, "P-256") == 0) return GJW_KEY_EC_P256;
        if (strcmp(name, "secp384r1") == 0 || strcmp(name, "P-384") == 0) return GJW_KEY_EC_P384;
        if (strcmp(name, "secp521r1") == 0 || strcmp(name, "P-521") == 0) return GJW_KEY_EC_P521;
        return -1;
    }
    default: return -1;
    }
}

static gjw_key *wrap(EVP_PKEY *pkey) {
    if (!pkey) return NULL;
    int type = classify(pkey);
    /* An RSA key too small to be safe is refused rather than trusted. */
    if (type < 0 || (type == GJW_KEY_RSA && EVP_PKEY_get_bits(pkey) < 2048)) {
        EVP_PKEY_free(pkey);
        return NULL;
    }
    gjw_key *key = OPENSSL_zalloc(sizeof *key);
    if (!key) {
        EVP_PKEY_free(pkey);
        return NULL;
    }
    key->pkey = pkey;
    key->type = type;
    return key;
}

gjw_key *gjw_key_from_pem(const char *pem, size_t len, int *has_private) {
    if (has_private) *has_private = 0;
    if (!pem || len == 0 || len > (1 << 20)) return NULL;
    BIO *bio = BIO_new_mem_buf(pem, (int)len);
    if (!bio) return NULL;
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    if (pkey) {
        if (has_private) *has_private = 1;
    } else {
        (void)BIO_reset(bio);
        pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    }
    if (!pkey) {
        (void)BIO_reset(bio);
        X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (cert) {
            pkey = X509_get_pubkey(cert);
            X509_free(cert);
        }
    }
    BIO_free(bio);
    return wrap(pkey);
}

static EVP_PKEY *from_params(const char *type, OSSL_PARAM *params) {
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, type, NULL);
    EVP_PKEY *pkey = NULL;
    if (ctx && EVP_PKEY_fromdata_init(ctx) == 1) {
        if (EVP_PKEY_fromdata(ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params) != 1) pkey = NULL;
    }
    EVP_PKEY_CTX_free(ctx);
    return pkey;
}

gjw_key *gjw_key_from_rsa(const uint8_t *n, size_t n_len, const uint8_t *e, size_t e_len) {
    if (!n || !e || n_len == 0 || e_len == 0 || n_len > 2048 || e_len > 16) return NULL;
    BIGNUM *bn_n = BN_bin2bn(n, (int)n_len, NULL);
    BIGNUM *bn_e = BN_bin2bn(e, (int)e_len, NULL);
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new();
    OSSL_PARAM *params = NULL;
    EVP_PKEY *pkey = NULL;
    if (bn_n && bn_e && bld
        && OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_N, bn_n)
        && OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_E, bn_e)
        && (params = OSSL_PARAM_BLD_to_param(bld)) != NULL) {
        pkey = from_params("RSA", params);
    }
    OSSL_PARAM_free(params);
    OSSL_PARAM_BLD_free(bld);
    BN_free(bn_n);
    BN_free(bn_e);
    return wrap(pkey);
}

static const char *curve_name(int type, size_t *size) {
    switch (type) {
    case GJW_KEY_EC_P256: *size = 32; return "prime256v1";
    case GJW_KEY_EC_P384: *size = 48; return "secp384r1";
    case GJW_KEY_EC_P521: *size = 66; return "secp521r1";
    default: return NULL;
    }
}

gjw_key *gjw_key_from_ec(int type, const uint8_t *x, size_t x_len, const uint8_t *y, size_t y_len) {
    size_t size = 0;
    const char *curve = curve_name(type, &size);
    if (!curve || !x || !y || x_len != size || y_len != size) return NULL;
    uint8_t point[1 + 2 * 66];
    point[0] = 0x04;
    memcpy(point + 1, x, size);
    memcpy(point + 1 + size, y, size);
    OSSL_PARAM params[] = {
        OSSL_PARAM_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, (char *)curve, 0),
        OSSL_PARAM_octet_string(OSSL_PKEY_PARAM_PUB_KEY, point, 1 + 2 * size),
        OSSL_PARAM_END,
    };
    return wrap(from_params("EC", params));
}

gjw_key *gjw_key_from_ed25519(const uint8_t *x, size_t x_len) {
    if (!x || x_len != 32) return NULL;
    return wrap(EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, x, x_len));
}

gjw_key *gjw_key_generate(int type, int bits) {
    EVP_PKEY *pkey = NULL;
    size_t size = 0;
    switch (type) {
    case GJW_KEY_RSA:
        pkey = EVP_RSA_gen((unsigned int)(bits >= 2048 ? bits : 2048));
        break;
    case GJW_KEY_EC_P256: case GJW_KEY_EC_P384: case GJW_KEY_EC_P521:
        pkey = EVP_EC_gen(curve_name(type, &size));
        break;
    case GJW_KEY_ED25519:
        pkey = EVP_PKEY_Q_keygen(NULL, NULL, "ED25519");
        break;
    default:
        return NULL;
    }
    return wrap(pkey);
}

void gjw_key_free(gjw_key *key) {
    if (!key) return;
    EVP_PKEY_free(key->pkey);
    OPENSSL_free(key);
}

int gjw_key_type(const gjw_key *key) { return key ? key->type : -1; }

long gjw_key_pem(const gjw_key *key, int private_key, char *out, size_t cap) {
    if (!key) return -1;
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return -1;
    int ok = private_key ? PEM_write_bio_PrivateKey(bio, key->pkey, NULL, NULL, 0, NULL, NULL)
                         : PEM_write_bio_PUBKEY(bio, key->pkey);
    long result = -1;
    if (ok) {
        char *data = NULL;
        long len = BIO_get_mem_data(bio, &data);
        if (!out) {
            result = len;
        } else if ((size_t)len <= cap) {
            memcpy(out, data, (size_t)len);
            result = len;
        }
    }
    BIO_free(bio);
    return result;
}

static int bn_param(const gjw_key *key, const char *name, uint8_t *out, size_t *len) {
    BIGNUM *bn = NULL;
    if (!EVP_PKEY_get_bn_param(key->pkey, name, &bn)) return -1;
    int size = BN_num_bytes(bn);
    int result = -1;
    if ((size_t)size <= *len) {
        BN_bn2bin(bn, out);
        *len = (size_t)size;
        result = 0;
    }
    BN_free(bn);
    return result;
}

int gjw_key_rsa_numbers(const gjw_key *key, uint8_t *n, size_t *n_len, uint8_t *e, size_t *e_len) {
    if (!key || key->type != GJW_KEY_RSA) return -1;
    if (bn_param(key, OSSL_PKEY_PARAM_RSA_N, n, n_len) != 0) return -1;
    return bn_param(key, OSSL_PKEY_PARAM_RSA_E, e, e_len);
}

int gjw_key_ec_point(const gjw_key *key, uint8_t *x, size_t *x_len, uint8_t *y, size_t *y_len) {
    size_t size = 0;
    if (!key || !curve_name(key->type, &size) || *x_len < size || *y_len < size) return -1;
    uint8_t point[1 + 2 * 66];
    size_t len = 0;
    if (!EVP_PKEY_get_octet_string_param(key->pkey, OSSL_PKEY_PARAM_ENCODED_PUBLIC_KEY, point, sizeof point, &len)
        || len != 1 + 2 * size || point[0] != 0x04) {
        return -1;
    }
    memcpy(x, point + 1, size);
    memcpy(y, point + 1 + size, size);
    *x_len = size;
    *y_len = size;
    return 0;
}

int gjw_key_raw_public(const gjw_key *key, uint8_t *out, size_t *out_len) {
    if (!key || key->type != GJW_KEY_ED25519) return -1;
    return EVP_PKEY_get_raw_public_key(key->pkey, out, out_len) == 1 ? 0 : -1;
}

/* Whether `alg` is one this key can sign or verify. */
static int belongs(const gjw_key *key, int alg) {
    switch (alg) {
    case GJW_RS256: case GJW_RS384: case GJW_RS512:
    case GJW_PS256: case GJW_PS384: case GJW_PS512: return key->type == GJW_KEY_RSA;
    case GJW_ES256: return key->type == GJW_KEY_EC_P256;
    case GJW_ES384: return key->type == GJW_KEY_EC_P384;
    case GJW_ES512: return key->type == GJW_KEY_EC_P521;
    case GJW_EDDSA: return key->type == GJW_KEY_ED25519;
    default: return 0;
    }
}

static size_t ec_size(int type) {
    size_t size = 0;
    (void)curve_name(type, &size);
    return size;
}

static EVP_MD_CTX *digest_context(const gjw_key *key, int alg, int signing) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx) return NULL;
    EVP_PKEY_CTX *pctx = NULL;
    const EVP_MD *md = alg == GJW_EDDSA ? NULL : digest_for(alg);
    int ok = signing ? EVP_DigestSignInit(ctx, &pctx, md, NULL, key->pkey)
                     : EVP_DigestVerifyInit(ctx, &pctx, md, NULL, key->pkey);
    if (ok == 1 && (alg == GJW_PS256 || alg == GJW_PS384 || alg == GJW_PS512)) {
        ok = EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) > 0
             && EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) > 0;
    } else if (ok == 1 && (alg == GJW_RS256 || alg == GJW_RS384 || alg == GJW_RS512)) {
        ok = EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING) > 0;
    }
    if (ok != 1) {
        EVP_MD_CTX_free(ctx);
        return NULL;
    }
    return ctx;
}

long gjw_sign(const gjw_key *key, int alg, const uint8_t *data, size_t data_len, uint8_t *out, size_t cap) {
    if (!key || !belongs(key, alg)) return -1;
    EVP_MD_CTX *ctx = digest_context(key, alg, 1);
    if (!ctx) return -1;
    size_t len = 0;
    long result = -1;
    if (EVP_DigestSign(ctx, NULL, &len, data, data_len) == 1) {
        uint8_t *der = OPENSSL_malloc(len);
        if (der && EVP_DigestSign(ctx, der, &len, data, data_len) == 1) {
            if (key->type == GJW_KEY_EC_P256 || key->type == GJW_KEY_EC_P384 || key->type == GJW_KEY_EC_P521) {
                size_t size = ec_size(key->type);
                const unsigned char *p = der;
                ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &p, (long)len);
                if (sig && cap >= 2 * size) {
                    const BIGNUM *r = NULL, *s = NULL;
                    ECDSA_SIG_get0(sig, &r, &s);
                    if (BN_bn2binpad(r, out, (int)size) == (int)size
                        && BN_bn2binpad(s, out + size, (int)size) == (int)size) {
                        result = (long)(2 * size);
                    }
                }
                ECDSA_SIG_free(sig);
            } else if (len <= cap) {
                memcpy(out, der, len);
                result = (long)len;
            }
        }
        OPENSSL_free(der);
    }
    EVP_MD_CTX_free(ctx);
    return result;
}

int gjw_verify(const gjw_key *key, int alg, const uint8_t *data, size_t data_len,
               const uint8_t *sig, size_t sig_len) {
    if (!key || !belongs(key, alg)) return -1;
    uint8_t *der = NULL;
    const uint8_t *signature = sig;
    size_t signature_len = sig_len;
    if (key->type == GJW_KEY_EC_P256 || key->type == GJW_KEY_EC_P384 || key->type == GJW_KEY_EC_P521) {
        /* JWS gives r and s at the curve's size; libcrypto wants DER. */
        size_t size = ec_size(key->type);
        if (sig_len != 2 * size) return 0;
        ECDSA_SIG *es = ECDSA_SIG_new();
        BIGNUM *r = BN_bin2bn(sig, (int)size, NULL);
        BIGNUM *s = BN_bin2bn(sig + size, (int)size, NULL);
        if (!es || !r || !s || ECDSA_SIG_set0(es, r, s) != 1) {
            ECDSA_SIG_free(es);
            BN_free(r);
            BN_free(s);
            return 0;
        }
        int len = i2d_ECDSA_SIG(es, &der);
        ECDSA_SIG_free(es);
        if (len <= 0) return 0;
        signature = der;
        signature_len = (size_t)len;
    }
    EVP_MD_CTX *ctx = digest_context(key, alg, 0);
    int result = 0;
    if (ctx) {
        result = EVP_DigestVerify(ctx, signature, signature_len, data, data_len) == 1 ? 1 : 0;
        EVP_MD_CTX_free(ctx);
    }
    OPENSSL_free(der);
    return result;
}
