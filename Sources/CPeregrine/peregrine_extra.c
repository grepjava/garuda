/* Supporting syscalls and primitives that the original single-threaded,
 * HTTP-only server did not need:
 *
 *   - address parsing, for matching a peer against the trusted-proxy list;
 *   - pthread wrappers behind opaque handles, so Swift never has to see
 *     pthread_mutex_t (whose size and alignment differ per platform);
 *   - SHA-1 and base64, required by the WebSocket opening handshake;
 *   - a few file and environment helpers for --reload and virtualenv lookup.
 *
 * The pthread wrappers are the only place in the server where more than one
 * thread exists, and they exist solely for the optional WSGI thread pool.
 */

#define _GNU_SOURCE 1
#include "peregrine_sys.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

/* ======================================================================== */
/* Addresses                                                                */
/* ======================================================================== */

int pg_parse_ip(const char *s, unsigned char out16[16], int *family) {
    unsigned char buf[16];
    memset(buf, 0, sizeof buf);
    if (inet_pton(AF_INET, s, buf) == 1) {
        memset(out16, 0, 16);
        memcpy(out16, buf, 4);
        if (family) *family = 4;
        return 0;
    }
    /* A scope suffix (fe80::1%eth0) is not part of the address. */
    const char *pct = strchr(s, '%');
    if (pct) {
        size_t n = (size_t)(pct - s);
        if (n >= 46) return -1;
        char trimmed[46];
        memcpy(trimmed, s, n);
        trimmed[n] = 0;
        s = trimmed;
        if (inet_pton(AF_INET6, s, buf) == 1) {
            memcpy(out16, buf, 16);
            if (family) *family = 6;
            return 0;
        }
        return -1;
    }
    if (inet_pton(AF_INET6, s, buf) == 1) {
        memcpy(out16, buf, 16);
        if (family) *family = 6;
        return 0;
    }
    return -1;
}

/* ======================================================================== */
/* Files, environment, pipes                                                */
/* ======================================================================== */

int pg_unlink(const char *path) { return unlink(path); }

const char *pg_getenv(const char *name) { return getenv(name); }

int pg_path_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? 1 : 0;
}

int64_t pg_mtime_ns(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
#if defined(__APPLE__)
    return (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
    return (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
}

int pg_pipe(int fds[2]) {
    if (pipe(fds) != 0) return -1;
    for (int i = 0; i < 2; i++) {
        pg_set_nonblock(fds[i]);
        pg_set_cloexec(fds[i]);
    }
    return 0;
}

/* ======================================================================== */
/* Threads                                                                  */
/* ======================================================================== */

struct pg_mutex { pthread_mutex_t m; };
struct pg_cond  { pthread_cond_t c; };

pg_mutex *pg_mutex_new(void) {
    pg_mutex *m = (pg_mutex *)malloc(sizeof *m);
    if (!m) return NULL;
    if (pthread_mutex_init(&m->m, NULL) != 0) { free(m); return NULL; }
    return m;
}
void pg_mutex_free(pg_mutex *m) {
    if (!m) return;
    pthread_mutex_destroy(&m->m);
    free(m);
}
void pg_mutex_lock(pg_mutex *m)   { pthread_mutex_lock(&m->m); }
void pg_mutex_unlock(pg_mutex *m) { pthread_mutex_unlock(&m->m); }

pg_cond *pg_cond_new(void) {
    pg_cond *c = (pg_cond *)malloc(sizeof *c);
    if (!c) return NULL;
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
#if defined(CLOCK_MONOTONIC) && !defined(__APPLE__)
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
    if (pthread_cond_init(&c->c, &attr) != 0) {
        pthread_condattr_destroy(&attr);
        free(c);
        return NULL;
    }
    pthread_condattr_destroy(&attr);
    return c;
}
void pg_cond_free(pg_cond *c) {
    if (!c) return;
    pthread_cond_destroy(&c->c);
    free(c);
}
void pg_cond_wait(pg_cond *c, pg_mutex *m) { pthread_cond_wait(&c->c, &m->m); }
void pg_cond_signal(pg_cond *c)            { pthread_cond_signal(&c->c); }
void pg_cond_broadcast(pg_cond *c)         { pthread_cond_broadcast(&c->c); }

struct thread_start { void (*fn)(void *); void *arg; };

static void *thread_trampoline(void *raw) {
    struct thread_start s = *(struct thread_start *)raw;
    free(raw);
    /* Worker threads must never take delivery of a process signal: the signal
     * pipe belongs to the loop thread, and a handler running here would report
     * a wakeup nobody is waiting for. */
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    s.fn(s.arg);
    return NULL;
}

int pg_thread_spawn(void (*fn)(void *), void *arg) {
    struct thread_start *s = (struct thread_start *)malloc(sizeof *s);
    if (!s) return -1;
    s->fn = fn;
    s->arg = arg;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 1u << 21);   /* 2 MiB is plenty per request */
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, thread_trampoline, s);
    pthread_attr_destroy(&attr);
    if (rc != 0) { free(s); errno = rc; return -1; }
    return 0;
}

/* ======================================================================== */
/* SHA-1 and base64, for the WebSocket handshake                            */
/* ======================================================================== */

/* RFC 3174. The only user is one 60-byte digest per WebSocket upgrade, so this
 * is written for clarity rather than for throughput. */

static uint32_t rol(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

static void sha1_block(uint32_t h[5], const unsigned char *p) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
               ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
    }
    for (int i = 16; i < 80; i++) {
        w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20)      { f = (b & c) | (~b & d);            k = 0x5A827999u; }
        else if (i < 40) { f = b ^ c ^ d;                     k = 0x6ED9EBA1u; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d);   k = 0x8F1BBCDCu; }
        else             { f = b ^ c ^ d;                     k = 0xCA62C1D6u; }
        uint32_t t = rol(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rol(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

void pg_sha1(const void *data, size_t n, unsigned char out20[20]) {
    uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u};
    const unsigned char *p = (const unsigned char *)data;
    size_t i = 0;
    for (; i + 64 <= n; i += 64) sha1_block(h, p + i);

    unsigned char tail[128];
    size_t rem = n - i;
    memcpy(tail, p + i, rem);
    tail[rem] = 0x80;
    size_t total = (rem + 1 <= 56) ? 64 : 128;
    memset(tail + rem + 1, 0, total - rem - 1);
    uint64_t bits = (uint64_t)n * 8;
    for (int k = 0; k < 8; k++) tail[total - 1 - k] = (unsigned char)(bits >> (8 * k));
    sha1_block(h, tail);
    if (total == 128) sha1_block(h, tail + 64);

    for (int k = 0; k < 5; k++) {
        out20[k * 4]     = (unsigned char)(h[k] >> 24);
        out20[k * 4 + 1] = (unsigned char)(h[k] >> 16);
        out20[k * 4 + 2] = (unsigned char)(h[k] >> 8);
        out20[k * 4 + 3] = (unsigned char)(h[k]);
    }
}

static const char kB64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t pg_base64(const void *data, size_t n, char *out) {
    const unsigned char *p = (const unsigned char *)data;
    size_t o = 0;
    size_t i = 0;
    for (; i + 3 <= n; i += 3) {
        uint32_t v = ((uint32_t)p[i] << 16) | ((uint32_t)p[i + 1] << 8) | p[i + 2];
        out[o++] = kB64[(v >> 18) & 63];
        out[o++] = kB64[(v >> 12) & 63];
        out[o++] = kB64[(v >> 6) & 63];
        out[o++] = kB64[v & 63];
    }
    size_t rem = n - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)p[i] << 16;
        out[o++] = kB64[(v >> 18) & 63];
        out[o++] = kB64[(v >> 12) & 63];
        out[o++] = '=';
        out[o++] = '=';
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)p[i] << 16) | ((uint32_t)p[i + 1] << 8);
        out[o++] = kB64[(v >> 18) & 63];
        out[o++] = kB64[(v >> 12) & 63];
        out[o++] = kB64[(v >> 6) & 63];
        out[o++] = '=';
    }
    return o;
}

/* Random bytes for the WebSocket close/ping payloads and anywhere else the
 * server needs unpredictability. Falls back to /dev/urandom when getentropy is
 * unavailable. */
int pg_random_bytes(void *out, size_t n) {
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    unsigned char *p = (unsigned char *)out;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) { close(fd); return -1; }
        got += (size_t)r;
    }
    close(fd);
    return 0;
}

int pg_is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

/* ======================================================================== */
/* Shutdown watchdog                                                        */
/* ======================================================================== */

/* Cancellation is cooperative all the way down: a task can catch
 * CancelledError, a C extension can sit in a syscall, and a third-party
 * library can block on a lock nobody will release. Every layer above this one
 * has a deadline, but a deadline is only a promise if something enforces it.
 * SIGALRM does, from outside the interpreter, with _exit rather than exit so
 * that no atexit handler or interpreter finaliser can wedge it in turn. */

static int g_watchdog_code = 0;

static void watchdog_fire(int signo) {
    (void)signo;
    static const char msg[] =
        "[error] shutdown exceeded its deadline; exiting immediately\n";
    ssize_t r = write(2, msg, sizeof msg - 1);
    (void)r;
    _exit(g_watchdog_code);
}

void pg_exit_after(unsigned seconds, int code) {
    g_watchdog_code = code;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = watchdog_fire;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);
    alarm(seconds);
}

void pg_cancel_exit_timer(void) { alarm(0); }
