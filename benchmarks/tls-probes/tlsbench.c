/* OpenSSL 3.5 against BoringSSL, on the two things Garuda's profile says
 * cost it: a TLS 1.3 handshake, and a small record read and written on an
 * established connection.
 *
 * One source, compiled twice. BoringSSL's headers here are swift-nio-ssl's
 * vendored copy, whose prefix header maps the ordinary names onto prefixed
 * ones, so the code below is the same for both.
 *
 * Client and server both run in this process over a socketpair, so what is
 * measured is the process's own CPU, not a network. Both sides are the
 * library under test, which is what we want: the question is what the
 * library costs, not what talking to it costs.
 *
 * The sockets are NON-BLOCKING, which is not a detail. With one thread
 * driving both ends, a blocking SSL_do_handshake deadlocks: the client sits
 * in read() waiting for a ServerHello the server cannot send until this same
 * thread returns.
 *
 * The group is pinned on both sides. OpenSSL 3.5 picks X25519MLKEM768 by
 * default and BoringSSL may pick classical X25519; left alone, the
 * comparison would measure that choice rather than the library. Both ends
 * print what they actually negotiated, so the pin is checked, not trusted.
 */
#define _GNU_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef USE_BORINGSSL
#include "CNIOBoringSSL_ssl.h"
#include "CNIOBoringSSL_err.h"
#include "CNIOBoringSSL_pem.h"
#include "CNIOBoringSSL_x509.h"
#include "CNIOBoringSSL_obj.h"
#define LIBNAME "boringssl"
#else
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/objects.h>
#define LIBNAME "openssl"
#endif

static const char *GROUP = "X25519";

static double cpu_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void die(const char *what) {
    fprintf(stderr, "%s: %s failed\n", LIBNAME, what);
    ERR_print_errors_fp(stderr);
    exit(1);
}

/* The name of the group that was actually agreed. The two libraries spell
 * this question differently. */
static const char *group_of(SSL *ssl) {
#ifdef USE_BORINGSSL
    const char *n = SSL_get_curve_name(SSL_get_curve_id(ssl));
    return n ? n : "?";
#else
    int nid = SSL_get_negotiated_group(ssl);
    const char *n = nid ? OBJ_nid2sn(nid) : NULL;
    return n ? n : "?";
#endif
}

static void nonblocking(int fd) {
    int f = fcntl(fd, F_GETFL, 0);
    if (f < 0 || fcntl(fd, F_SETFL, f | O_NONBLOCK) < 0) die("O_NONBLOCK");
}

/* Drives both sides until each says the handshake is done. Neither can
 * block, so this alternates until both report success. */
static int handshake(SSL *server, SSL *client) {
    int sdone = 0, cdone = 0;
    for (int i = 0; i < 64 && !(sdone && cdone); i++) {
        if (!cdone) {
            int rc = SSL_do_handshake(client);
            if (rc == 1) cdone = 1;
            else {
                int e = SSL_get_error(client, rc);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
            }
        }
        if (!sdone) {
            int rc = SSL_do_handshake(server);
            if (rc == 1) sdone = 1;
            else {
                int e = SSL_get_error(server, rc);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
            }
        }
    }
    return sdone && cdone;
}

/* A whole record, however many attempts that takes. The peer has already
 * written, so a WANT_READ here means a partial record, not an idle socket. */
static int io_write(SSL *ssl, const void *buf, int len) {
    for (int i = 0; i < 1024; i++) {
        int rc = SSL_write(ssl, buf, len);
        if (rc == len) return 1;
        if (rc > 0) return 0;
        int e = SSL_get_error(ssl, rc);
        if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
    }
    return 0;
}

static int io_read(SSL *ssl, void *buf, int cap, int want) {
    for (int i = 0; i < 1024; i++) {
        int rc = SSL_read(ssl, buf, cap);
        if (rc == want) return 1;
        if (rc > 0) return 0;
        int e = SSL_get_error(ssl, rc);
        if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *cert = argc > 1 ? argv[1] : "/tmp/c.pem";
    const char *key = argc > 2 ? argv[2] : "/tmp/k.pem";
    int handshakes = argc > 3 ? atoi(argv[3]) : 2000;
    int records = argc > 4 ? atoi(argv[4]) : 200000;

    SSL_library_init();
    SSL_CTX *sctx = SSL_CTX_new(TLS_server_method());
    SSL_CTX *cctx = SSL_CTX_new(TLS_client_method());
    if (!sctx || !cctx) die("SSL_CTX_new");
    if (SSL_CTX_use_certificate_file(sctx, cert, SSL_FILETYPE_PEM) != 1) die("certificate");
    if (SSL_CTX_use_PrivateKey_file(sctx, key, SSL_FILETYPE_PEM) != 1) die("key");
    SSL_CTX_set_verify(cctx, SSL_VERIFY_NONE, NULL);
    /* The same settings Garuda's server context uses, as far as both have
     * them: partial writes, a moving write buffer, buffers released. */
    SSL_CTX_set_mode(sctx, SSL_MODE_ENABLE_PARTIAL_WRITE
                           | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
                           | SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_min_proto_version(sctx, TLS1_2_VERSION);
    if (SSL_CTX_set1_groups_list(sctx, GROUP) != 1) die("server groups");
    if (SSL_CTX_set1_groups_list(cctx, GROUP) != 1) die("client groups");
    /* The suite has to be pinned for the same reason as the group. BoringSSL
     * does not let TLS 1.3 suites be chosen at all and takes AES-128-GCM
     * where AES is accelerated; OpenSSL leads with AES-256-GCM. So bring
     * OpenSSL to BoringSSL's choice rather than the other way round, or the
     * record figure compares key sizes instead of libraries. */
#ifndef USE_BORINGSSL
    if (SSL_CTX_set_ciphersuites(sctx, "TLS_AES_128_GCM_SHA256") != 1) die("server suite");
    if (SSL_CTX_set_ciphersuites(cctx, "TLS_AES_128_GCM_SHA256") != 1) die("client suite");
#endif

    /* ---- handshakes ---- */
    char agreed[128] = "?", suite[128] = "?";
    double t0 = cpu_seconds();
    int done = 0;
    for (int i = 0; i < handshakes; i++) {
        int fds[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) die("socketpair");
        nonblocking(fds[0]); nonblocking(fds[1]);
        SSL *s = SSL_new(sctx), *c = SSL_new(cctx);
        SSL_set_fd(s, fds[0]); SSL_set_accept_state(s);
        SSL_set_fd(c, fds[1]); SSL_set_connect_state(c);
        if (handshake(s, c)) {
            done++;
            if (done == 1) {
                snprintf(agreed, sizeof agreed, "%s", group_of(c));
                snprintf(suite, sizeof suite, "%s", SSL_get_cipher_name(c));
            }
        }
        SSL_free(s); SSL_free(c);
        close(fds[0]); close(fds[1]);
    }
    double t1 = cpu_seconds();
    if (done != handshakes) {
        fprintf(stderr, "%s: only %d of %d handshakes completed\n", LIBNAME, done, handshakes);
        return 1;
    }

    /* ---- records on one established connection ---- */
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) die("socketpair");
    nonblocking(fds[0]); nonblocking(fds[1]);
    SSL *s = SSL_new(sctx), *c = SSL_new(cctx);
    SSL_set_fd(s, fds[0]); SSL_set_accept_state(s);
    SSL_set_fd(c, fds[1]); SSL_set_connect_state(c);
    if (!handshake(s, c)) die("handshake for records");

    /* A request in and an answer out, the shape of the `user` workload. */
    char request[80], answer[200], scratch[512];
    memset(request, 0x71, sizeof request);
    memset(answer, 0x61, sizeof answer);
    double t2 = cpu_seconds();
    int moved = 0;
    for (int i = 0; i < records; i++) {
        if (!io_write(c, request, (int)sizeof request)) break;
        if (!io_read(s, scratch, (int)sizeof scratch, (int)sizeof request)) break;
        if (!io_write(s, answer, (int)sizeof answer)) break;
        if (!io_read(c, scratch, (int)sizeof scratch, (int)sizeof answer)) break;
        moved++;
    }
    double t3 = cpu_seconds();
    if (moved != records) {
        fprintf(stderr, "%s: only %d of %d record round trips\n", LIBNAME, moved, records);
        return 1;
    }

    printf("%-10s handshake %7.1f us cpu   record-pair %6.2f us cpu   [%s %s]\n",
           LIBNAME, (t1 - t0) * 1e6 / handshakes, (t3 - t2) * 1e6 / records,
           agreed, suite);
    SSL_free(s); SSL_free(c);
    close(fds[0]); close(fds[1]);
    SSL_CTX_free(sctx); SSL_CTX_free(cctx);
    return 0;
}
