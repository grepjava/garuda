/* The OpenSSL half of the ACME client. See peregrine_acme.h. */
#define _GNU_SOURCE

#include "peregrine_acme.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int pg_acme_b64url(const uint8_t *in, size_t n, char *out, size_t cap) {
    static const char table[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    size_t need = (n * 4 + 2) / 3;
    if (!out || need + 1 > cap) return -1;
    size_t o = 0, i = 0;
    while (i + 3 <= n) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8 | in[i + 2];
        out[o++] = table[(v >> 18) & 63];
        out[o++] = table[(v >> 12) & 63];
        out[o++] = table[(v >> 6) & 63];
        out[o++] = table[v & 63];
        i += 3;
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = table[(v >> 18) & 63];
        out[o++] = table[(v >> 12) & 63];
    } else if (n - i == 2) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8;
        out[o++] = table[(v >> 18) & 63];
        out[o++] = table[(v >> 12) & 63];
        out[o++] = table[(v >> 6) & 63];
    }
    out[o] = 0;
    return (int)o;
}

int pg_acme_mkdirs(const char *path) {
    char buf[4096];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof buf) return -1;
    memcpy(buf, path, n + 1);
    for (size_t i = 1; i <= n; i++) {
        if (buf[i] == '/' || buf[i] == 0) {
            char saved = buf[i];
            buf[i] = 0;
            if (mkdir(buf, 0700) != 0 && errno != EEXIST) return -1;
            buf[i] = saved;
        }
    }
    return 0;
}

int pg_acme_write_file(const char *path, const uint8_t *data, size_t n, int mode) {
    char tmp[4200];
    if (snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid()) >= (int)sizeof tmp) return -1;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0) return -1;
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, data + done, n - done);
        if (w < 0) {
            if (errno == EINTR) continue;
            close(fd);
            unlink(tmp);
            return -1;
        }
        done += (size_t)w;
    }
    if (fsync(fd) != 0 || close(fd) != 0) {
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

int pg_acme_rename(const char *from, const char *to) { return rename(from, to); }

int pg_acme_exit_ok(int status) { return WIFEXITED(status) && WEXITSTATUS(status) == 0; }

#if defined(__has_include)
#  if !__has_include(<openssl/ssl.h>)
#    define PG_NO_OPENSSL 1
#  endif
#endif

#ifdef PG_NO_OPENSSL

pg_acme_key *pg_acme_key_load_or_create(const char *p, char *e, size_t l) {
    (void)p; if (e && l) snprintf(e, l, "built without OpenSSL"); return NULL;
}
void pg_acme_key_free(pg_acme_key *k) { (void)k; }
int pg_acme_jwk(pg_acme_key *k, char *o, size_t c) { (void)k; (void)o; (void)c; return -1; }
int pg_acme_thumbprint(pg_acme_key *k, char *o, size_t c) { (void)k; (void)o; (void)c; return -1; }
int pg_acme_sign(pg_acme_key *k, const uint8_t *d, size_t n, char *o, size_t c) {
    (void)k; (void)d; (void)n; (void)o; (void)c; return -1;
}
int pg_acme_csr(const char *n, const char *k, char *o, size_t c, char *e, size_t l) {
    (void)n; (void)k; (void)o; (void)c; (void)e; (void)l; return -1;
}
int pg_acme_alpn_cert(const char *n, const char *a, const char *c, const char *k, char *e, size_t l) {
    (void)n; (void)a; (void)c; (void)k; (void)e; (void)l; return -1;
}
int pg_acme_placeholder(const char *n, const char *c, const char *k, char *e, size_t l) {
    (void)n; (void)c; (void)k; (void)e; (void)l; return -1;
}
int pg_acme_needs_certificate(const char *p, const char *n, long s) { (void)p; (void)n; (void)s; return 1; }
pg_acme_resp *pg_acme_https(const char *m, const char *u, const char *t, const uint8_t *b,
                            size_t bl, const char *a, const char *ca, char *e, size_t l) {
    (void)m; (void)u; (void)t; (void)b; (void)bl; (void)a; (void)ca;
    if (e && l) snprintf(e, l, "built without OpenSSL");
    return NULL;
}
int pg_acme_resp_status(pg_acme_resp *r) { (void)r; return 0; }
int pg_acme_resp_header(pg_acme_resp *r, const char *n, char *o, size_t c) {
    (void)r; (void)n; (void)o; (void)c; return -1;
}
const uint8_t *pg_acme_resp_body(pg_acme_resp *r, size_t *len) { (void)r; *len = 0; return NULL; }
void pg_acme_resp_free(pg_acme_resp *r) { (void)r; }

#else

#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

/* What marks the certificate served before a real one exists, so that it is
 * never mistaken for one. */
#define PLACEHOLDER_ORG "peregrine acme placeholder"

struct pg_acme_key {
    EVP_PKEY *pkey;
};

static void set_error(char *err, size_t err_len, const char *what) {
    if (!err || err_len == 0) return;
    unsigned long code = ERR_get_error();
    if (code == 0) {
        snprintf(err, err_len, "%s", what);
    } else {
        char buf[256];
        ERR_error_string_n(code, buf, sizeof buf);
        snprintf(err, err_len, "%s: %s", what, buf);
    }
    while (ERR_get_error() != 0) { }
}

static int write_key(EVP_PKEY *pkey, const char *path) {
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return -1;
    int ok = PEM_write_bio_PrivateKey(bio, pkey, NULL, NULL, 0, NULL, NULL) == 1;
    char *data = NULL;
    long n = BIO_get_mem_data(bio, &data);
    if (ok) ok = pg_acme_write_file(path, (const uint8_t *)data, (size_t)n, 0600) == 0;
    BIO_free(bio);
    return ok ? 0 : -1;
}

static int write_cert(X509 *cert, const char *path) {
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return -1;
    int ok = PEM_write_bio_X509(bio, cert) == 1;
    char *data = NULL;
    long n = BIO_get_mem_data(bio, &data);
    if (ok) ok = pg_acme_write_file(path, (const uint8_t *)data, (size_t)n, 0644) == 0;
    BIO_free(bio);
    return ok ? 0 : -1;
}

pg_acme_key *pg_acme_key_load_or_create(const char *path, char *err, size_t err_len) {
    EVP_PKEY *pkey = NULL;
    FILE *f = fopen(path, "r");
    if (f) {
        pkey = PEM_read_PrivateKey(f, NULL, NULL, NULL);
        fclose(f);
        if (!pkey) {
            set_error(err, err_len, "cannot read the ACME account key");
            return NULL;
        }
    } else {
        pkey = EVP_EC_gen("P-256");
        if (!pkey || write_key(pkey, path) != 0) {
            set_error(err, err_len, "cannot create the ACME account key");
            EVP_PKEY_free(pkey);
            return NULL;
        }
    }
    if (EVP_PKEY_get_base_id(pkey) != EVP_PKEY_EC || EVP_PKEY_get_bits(pkey) != 256) {
        if (err && err_len) snprintf(err, err_len, "the ACME account key is not P-256");
        EVP_PKEY_free(pkey);
        return NULL;
    }
    struct pg_acme_key *key = calloc(1, sizeof *key);
    if (!key) { EVP_PKEY_free(pkey); return NULL; }
    key->pkey = pkey;
    return key;
}

void pg_acme_key_free(pg_acme_key *key) {
    if (!key) return;
    EVP_PKEY_free(key->pkey);
    free(key);
}

int pg_acme_jwk(pg_acme_key *key, char *out, size_t cap) {
    BIGNUM *x = NULL, *y = NULL;
    if (!EVP_PKEY_get_bn_param(key->pkey, OSSL_PKEY_PARAM_EC_PUB_X, &x)
        || !EVP_PKEY_get_bn_param(key->pkey, OSSL_PKEY_PARAM_EC_PUB_Y, &y)) {
        BN_free(x); BN_free(y);
        return -1;
    }
    uint8_t xb[32], yb[32];
    char xs[64], ys[64];
    int ok = BN_bn2binpad(x, xb, 32) == 32 && BN_bn2binpad(y, yb, 32) == 32
        && pg_acme_b64url(xb, 32, xs, sizeof xs) > 0
        && pg_acme_b64url(yb, 32, ys, sizeof ys) > 0;
    BN_free(x);
    BN_free(y);
    if (!ok) return -1;
    int n = snprintf(out, cap, "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"%s\",\"y\":\"%s\"}", xs, ys);
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

int pg_acme_thumbprint(pg_acme_key *key, char *out, size_t cap) {
    char jwk[256];
    int n = pg_acme_jwk(key, jwk, sizeof jwk);
    if (n < 0) return -1;
    uint8_t md[32];
    unsigned int mdlen = 0;
    if (!EVP_Digest(jwk, (size_t)n, md, &mdlen, EVP_sha256(), NULL)) return -1;
    return pg_acme_b64url(md, mdlen, out, cap);
}

int pg_acme_sign(pg_acme_key *key, const uint8_t *data, size_t n, char *out, size_t cap) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx) return -1;
    unsigned char der[128];
    size_t derlen = sizeof der;
    int ok = EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, key->pkey) == 1
        && EVP_DigestSign(ctx, der, &derlen, data, n) == 1;
    EVP_MD_CTX_free(ctx);
    if (!ok) return -1;

    const unsigned char *p = der;
    ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &p, (long)derlen);
    if (!sig) return -1;
    const BIGNUM *r = NULL, *s = NULL;
    ECDSA_SIG_get0(sig, &r, &s);
    uint8_t raw[64];
    ok = BN_bn2binpad(r, raw, 32) == 32 && BN_bn2binpad(s, raw + 32, 32) == 32;
    ECDSA_SIG_free(sig);
    if (!ok) return -1;
    return pg_acme_b64url(raw, 64, out, cap);
}

/* "a,b" -> "DNS:a,DNS:b". */
static int san_list(const char *names, char *out, size_t cap) {
    size_t o = 0;
    const char *p = names;
    while (*p) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len > 0) {
            if (o + len + 6 >= cap) return -1;
            if (o > 0) out[o++] = ',';
            memcpy(out + o, "DNS:", 4);
            o += 4;
            memcpy(out + o, p, len);
            o += len;
        }
        if (!end) break;
        p = end + 1;
    }
    out[o] = 0;
    return o > 0 ? 0 : -1;
}

static int add_ext(X509 *cert, int nid, const char *value) {
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, cert, cert, NULL, NULL, 0);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &ctx, nid, value);
    if (!ext) return -1;
    int ok = X509_add_ext(cert, ext, -1) == 1;
    X509_EXTENSION_free(ext);
    return ok ? 0 : -1;
}

/* A self-signed certificate with the fields both of ours share. */
static X509 *self_signed(EVP_PKEY *pkey, const char *common_name, const char *org,
                         long days) {
    X509 *cert = X509_new();
    if (!cert) return NULL;
    X509_set_version(cert, 2);
    unsigned char serial[16];
    RAND_bytes(serial, sizeof serial);
    serial[0] &= 0x7f;
    BIGNUM *bn = BN_bin2bn(serial, sizeof serial, NULL);
    if (bn) {
        BN_to_ASN1_INTEGER(bn, X509_get_serialNumber(cert));
        BN_free(bn);
    }
    X509_gmtime_adj(X509_getm_notBefore(cert), -3600);
    X509_gmtime_adj(X509_getm_notAfter(cert), days * 86400);
    X509_set_pubkey(cert, pkey);
    X509_NAME *name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               (const unsigned char *)common_name, -1, -1, 0);
    if (org) {
        X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC,
                                   (const unsigned char *)org, -1, -1, 0);
    }
    X509_set_issuer_name(cert, name);
    return cert;
}

int pg_acme_csr(const char *names, const char *key_path, char *out, size_t cap,
                char *err, size_t err_len) {
    char sans[8192];
    if (san_list(names, sans, sizeof sans) != 0) {
        if (err && err_len) snprintf(err, err_len, "no names for the certificate");
        return -1;
    }
    EVP_PKEY *pkey = EVP_EC_gen("P-256");
    X509_REQ *req = X509_REQ_new();
    STACK_OF(X509_EXTENSION) *exts = sk_X509_EXTENSION_new_null();
    unsigned char *der = NULL;
    int result = -1;
    if (!pkey || !req || !exts) { set_error(err, err_len, "cannot build the CSR"); goto done; }

    X509_REQ_set_version(req, 0);
    X509_REQ_set_pubkey(req, pkey);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, sans);
    if (!ext) { set_error(err, err_len, "cannot build the CSR's names"); goto done; }
    sk_X509_EXTENSION_push(exts, ext);
    if (X509_REQ_add_extensions(req, exts) != 1
        || X509_REQ_sign(req, pkey, EVP_sha256()) <= 0) {
        set_error(err, err_len, "cannot sign the CSR");
        goto done;
    }
    int n = i2d_X509_REQ(req, &der);
    if (n <= 0) { set_error(err, err_len, "cannot encode the CSR"); goto done; }
    if (write_key(pkey, key_path) != 0) {
        if (err && err_len) snprintf(err, err_len, "cannot write the certificate key");
        goto done;
    }
    result = pg_acme_b64url(der, (size_t)n, out, cap);

done:
    OPENSSL_free(der);
    sk_X509_EXTENSION_pop_free(exts, X509_EXTENSION_free);
    X509_REQ_free(req);
    EVP_PKEY_free(pkey);
    return result;
}

int pg_acme_alpn_cert(const char *name, const char *key_authorization,
                      const char *cert_path, const char *key_path,
                      char *err, size_t err_len) {
    uint8_t digest[32];
    unsigned int dlen = 0;
    if (!EVP_Digest(key_authorization, strlen(key_authorization), digest, &dlen,
                    EVP_sha256(), NULL)) {
        set_error(err, err_len, "cannot hash the key authorization");
        return -1;
    }
    EVP_PKEY *pkey = EVP_EC_gen("P-256");
    X509 *cert = pkey ? self_signed(pkey, name, NULL, 7) : NULL;
    ASN1_OBJECT *oid = OBJ_txt2obj("1.3.6.1.5.5.7.1.31", 1);
    ASN1_OCTET_STRING *value = ASN1_OCTET_STRING_new();
    X509_EXTENSION *ext = NULL;
    int result = -1;
    char san[512];
    if (!cert || !oid || !value) { set_error(err, err_len, "cannot build the challenge"); goto done; }
    if (snprintf(san, sizeof san, "DNS:%s", name) >= (int)sizeof san
        || add_ext(cert, NID_subject_alt_name, san) != 0) {
        set_error(err, err_len, "cannot name the challenge certificate");
        goto done;
    }
    /* The extension's value is itself DER: an OCTET STRING of the digest. */
    unsigned char inner[34];
    inner[0] = 0x04;
    inner[1] = 0x20;
    memcpy(inner + 2, digest, 32);
    if (!ASN1_OCTET_STRING_set(value, inner, sizeof inner)) goto done;
    ext = X509_EXTENSION_create_by_OBJ(NULL, oid, 1, value);
    if (!ext || X509_add_ext(cert, ext, -1) != 1
        || X509_sign(cert, pkey, EVP_sha256()) <= 0) {
        set_error(err, err_len, "cannot sign the challenge certificate");
        goto done;
    }
    if (write_key(pkey, key_path) != 0 || write_cert(cert, cert_path) != 0) {
        if (err && err_len) snprintf(err, err_len, "cannot write the challenge certificate");
        goto done;
    }
    result = 0;

done:
    X509_EXTENSION_free(ext);
    ASN1_OCTET_STRING_free(value);
    ASN1_OBJECT_free(oid);
    X509_free(cert);
    EVP_PKEY_free(pkey);
    return result;
}

int pg_acme_placeholder(const char *names, const char *cert_path, const char *key_path,
                        char *err, size_t err_len) {
    char sans[8192];
    if (san_list(names, sans, sizeof sans) != 0) {
        if (err && err_len) snprintf(err, err_len, "no names for the certificate");
        return -1;
    }
    char first[256];
    size_t len = strcspn(names, ",");
    if (len >= sizeof first) len = sizeof first - 1;
    memcpy(first, names, len);
    first[len] = 0;

    EVP_PKEY *pkey = EVP_EC_gen("P-256");
    X509 *cert = pkey ? self_signed(pkey, first, PLACEHOLDER_ORG, 90) : NULL;
    int result = -1;
    if (!cert || add_ext(cert, NID_subject_alt_name, sans) != 0
        || X509_sign(cert, pkey, EVP_sha256()) <= 0) {
        set_error(err, err_len, "cannot build the placeholder certificate");
    } else if (write_key(pkey, key_path) != 0 || write_cert(cert, cert_path) != 0) {
        if (err && err_len) snprintf(err, err_len, "cannot write the placeholder certificate");
    } else {
        result = 0;
    }
    X509_free(cert);
    EVP_PKEY_free(pkey);
    return result;
}

int pg_acme_needs_certificate(const char *path, const char *names, long renew_seconds) {
    FILE *f = fopen(path, "r");
    if (!f) return 1;
    X509 *cert = PEM_read_X509(f, NULL, NULL, NULL);
    fclose(f);
    if (!cert) return 1;
    int needs = 0;

    char org[128];
    if (X509_NAME_get_text_by_NID(X509_get_subject_name(cert), NID_organizationName,
                                  org, sizeof org) > 0
        && strcmp(org, PLACEHOLDER_ORG) == 0) {
        needs = 1;
    }

    const char *p = names;
    while (!needs && *p) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len > 0 && X509_check_host(cert, p, len, X509_CHECK_FLAG_NO_WILDCARDS, NULL) != 1) {
            needs = 1;
        }
        if (!end) break;
        p = end + 1;
    }

    if (!needs) {
        int days = 0, secs = 0;
        if (!ASN1_TIME_diff(&days, &secs, NULL, X509_get0_notAfter(cert))
            || (long)days * 86400L + secs < renew_seconds) {
            needs = 1;
        }
    }
    X509_free(cert);
    return needs;
}

/* --- one HTTPS request ------------------------------------------------- */

struct pg_acme_resp {
    int status;
    char *raw;
    size_t head_len;       /* through the blank line */
    uint8_t *body;
    size_t body_len;
};

static int dechunk(uint8_t *p, size_t n, size_t *out_len) {
    size_t r = 0, w = 0;
    for (;;) {
        size_t size = 0;
        int digits = 0;
        while (r < n) {
            uint8_t c = p[r];
            int v = (c >= '0' && c <= '9') ? c - '0'
                  : (c >= 'a' && c <= 'f') ? c - 'a' + 10
                  : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
            if (v < 0) break;
            if (size > (SIZE_MAX >> 4)) return -1;
            size = size * 16 + (size_t)v;
            digits++;
            r++;
        }
        if (!digits) return -1;
        while (r + 1 < n && !(p[r] == '\r' && p[r + 1] == '\n')) r++;
        if (r + 1 >= n) return -1;
        r += 2;
        if (size == 0) break;
        if (r + size > n) return -1;
        memmove(p + w, p + r, size);
        w += size;
        r += size + 2;
    }
    *out_len = w;
    return 0;
}

pg_acme_resp *pg_acme_https(const char *method, const char *url,
                            const char *content_type, const uint8_t *body, size_t body_len,
                            const char *accept, const char *ca_file,
                            char *err, size_t err_len) {
    if (strncmp(url, "https://", 8) != 0) {
        if (err && err_len) snprintf(err, err_len, "not an https URL: %s", url);
        return NULL;
    }
    const char *host_start = url + 8;
    size_t host_len = strcspn(host_start, ":/");
    char host[256], port[8] = "443";
    if (host_len == 0 || host_len >= sizeof host) {
        if (err && err_len) snprintf(err, err_len, "bad host in %s", url);
        return NULL;
    }
    memcpy(host, host_start, host_len);
    host[host_len] = 0;
    const char *rest = host_start + host_len;
    if (*rest == ':') {
        size_t plen = strcspn(rest + 1, "/");
        if (plen == 0 || plen >= sizeof port) {
            if (err && err_len) snprintf(err, err_len, "bad port in %s", url);
            return NULL;
        }
        memcpy(port, rest + 1, plen);
        port[plen] = 0;
        rest += 1 + plen;
    }
    const char *path = *rest ? rest : "/";

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(host, port, &hints, &res);
    if (gai != 0) {
        if (err && err_len) snprintf(err, err_len, "cannot resolve %s: %s", host, gai_strerror(gai));
        return NULL;
    }
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
#ifdef SOCK_CLOEXEC
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0) continue;
#else
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        fcntl(fd, F_SETFD, FD_CLOEXEC);
#endif
        struct timeval tv = { .tv_sec = 30, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        if (err && err_len) snprintf(err, err_len, "cannot connect to %s:%s", host, port);
        return NULL;
    }

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL *ssl = NULL;
    char *request = NULL;
    char *raw = NULL;
    struct pg_acme_resp *resp = NULL;
    if (!ctx) { set_error(err, err_len, "cannot create a TLS client"); goto fail; }
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_IGNORE_UNEXPECTED_EOF);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    if (ca_file ? SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1
                : SSL_CTX_set_default_verify_paths(ctx) != 1) {
        set_error(err, err_len, "cannot load trusted certificates");
        goto fail;
    }
    ssl = SSL_new(ctx);
    if (!ssl || SSL_set_fd(ssl, fd) != 1) { set_error(err, err_len, "cannot start TLS"); goto fail; }
    {
        unsigned char ip[16];
        int literal = inet_pton(AF_INET, host, ip) == 1 || inet_pton(AF_INET6, host, ip) == 1;
        if (literal) {
            X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), host);
        } else {
            SSL_set_tlsext_host_name(ssl, host);
            SSL_set1_host(ssl, host);
        }
    }
    if (SSL_connect(ssl) != 1) {
        set_error(err, err_len, "TLS handshake with the ACME server failed");
        goto fail;
    }

    {
        size_t cap = 1024 + strlen(path) + strlen(host) + body_len;
        request = malloc(cap);
        if (!request) goto fail;
        /* The port belongs in Host whenever it is not the scheme's default
         * (RFC 9110 section 7.2), and an ACME server builds every URL in its
         * directory from Host: leave it out and the next request goes to 443. */
        char authority[300];
        if (strcmp(port, "443") == 0) {
            snprintf(authority, sizeof authority, "%s", host);
        } else {
            snprintf(authority, sizeof authority, "%s:%s", host, port);
        }
        int n = snprintf(request, cap,
                         "%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: peregrine-acme\r\n"
                         "Accept: %s\r\nConnection: close\r\n",
                         method, path, authority, accept ? accept : "application/json");
        if (body) {
            n += snprintf(request + n, cap - (size_t)n,
                          "Content-Type: %s\r\nContent-Length: %zu\r\n",
                          content_type ? content_type : "application/jose+json", body_len);
        }
        n += snprintf(request + n, cap - (size_t)n, "\r\n");
        if (body && body_len) {
            memcpy(request + n, body, body_len);
            n += (int)body_len;
        }
        int sent = 0;
        while (sent < n) {
            int w = SSL_write(ssl, request + sent, n - sent);
            if (w <= 0) { set_error(err, err_len, "cannot send to the ACME server"); goto fail; }
            sent += w;
        }
    }

    {
        size_t cap = 16384, len = 0;
        raw = malloc(cap + 1);
        if (!raw) goto fail;
        for (;;) {
            if (len == cap) {
                if (cap > (8u << 20)) { if (err && err_len) snprintf(err, err_len, "response too large"); goto fail; }
                char *grown = realloc(raw, cap * 2 + 1);
                if (!grown) goto fail;
                raw = grown;
                cap *= 2;
            }
            int r = SSL_read(ssl, raw + len, (int)(cap - len));
            if (r > 0) { len += (size_t)r; continue; }
            int e = SSL_get_error(ssl, r);
            if (e == SSL_ERROR_ZERO_RETURN || e == SSL_ERROR_SYSCALL) break;
            set_error(err, err_len, "cannot read from the ACME server");
            goto fail;
        }
        raw[len] = 0;

        char *end = strstr(raw, "\r\n\r\n");
        if (!end || strncmp(raw, "HTTP/1.", 7) != 0) {
            if (err && err_len) snprintf(err, err_len, "malformed response from the ACME server");
            goto fail;
        }
        resp = calloc(1, sizeof *resp);
        if (!resp) goto fail;
        resp->raw = raw;
        raw = NULL;
        resp->status = atoi(resp->raw + 9);
        resp->head_len = (size_t)(end - resp->raw) + 4;
        resp->body = (uint8_t *)resp->raw + resp->head_len;
        resp->body_len = len - resp->head_len;

        char te[64];
        char cl[32];
        if (pg_acme_resp_header(resp, "transfer-encoding", te, sizeof te) > 0
            && strcasestr(te, "chunked")) {
            size_t decoded = 0;
            if (dechunk(resp->body, resp->body_len, &decoded) != 0) {
                if (err && err_len) snprintf(err, err_len, "malformed chunked response");
                pg_acme_resp_free(resp);
                resp = NULL;
                goto fail;
            }
            resp->body_len = decoded;
        } else if (pg_acme_resp_header(resp, "content-length", cl, sizeof cl) > 0) {
            size_t want = (size_t)strtoull(cl, NULL, 10);
            if (want < resp->body_len) resp->body_len = want;
        }
        resp->body[resp->body_len] = 0;
    }

    free(request);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return resp;

fail:
    free(raw);
    free(request);
    if (ssl) SSL_free(ssl);
    if (ctx) SSL_CTX_free(ctx);
    close(fd);
    return NULL;
}

int pg_acme_resp_status(pg_acme_resp *resp) { return resp ? resp->status : 0; }

int pg_acme_resp_header(pg_acme_resp *resp, const char *name, char *out, size_t cap) {
    if (!resp) return -1;
    size_t nlen = strlen(name);
    char *line = strstr(resp->raw, "\r\n");
    while (line && (size_t)(line - resp->raw) + 2 < resp->head_len) {
        line += 2;
        char *eol = strstr(line, "\r\n");
        if (!eol || eol == line) break;
        if ((size_t)(eol - line) > nlen && line[nlen] == ':'
            && strncasecmp(line, name, nlen) == 0) {
            char *v = line + nlen + 1;
            while (v < eol && (*v == ' ' || *v == '\t')) v++;
            size_t vlen = (size_t)(eol - v);
            if (vlen + 1 > cap) return -1;
            memcpy(out, v, vlen);
            out[vlen] = 0;
            return (int)vlen;
        }
        line = eol;
    }
    return -1;
}

const uint8_t *pg_acme_resp_body(pg_acme_resp *resp, size_t *len) {
    if (!resp) { *len = 0; return NULL; }
    *len = resp->body_len;
    return resp->body;
}

void pg_acme_resp_free(pg_acme_resp *resp) {
    if (!resp) return;
    free(resp->raw);
    free(resp);
}

#endif /* PG_NO_OPENSSL */
