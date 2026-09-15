#define _GNU_SOURCE 1
#include "garuda_sys.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#  include <sys/epoll.h>
#  include <sys/sendfile.h>
#  include <sys/syscall.h>
#  if defined(SYS_openat2)
#    include <linux/openat2.h>
#  endif
#else
#  include <sys/event.h>
#endif

/* ======================================================================== */
/* Poller                                                                   */
/* ======================================================================== */

#if defined(__linux__)

int pg_poll_create(void) { return epoll_create1(EPOLL_CLOEXEC); }

static uint32_t to_epoll(uint32_t mask) {
    uint32_t e = EPOLLRDHUP;   /* peer half-close must be visible, not silent */
    if (mask & PG_POLL_READ)  e |= EPOLLIN;
    if (mask & PG_POLL_WRITE) e |= EPOLLOUT;
    return e;
}

static int epoll_ctl_op(int pfd, int op, int fd, uint32_t mask, uint64_t token) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = to_epoll(mask);
    ev.data.u64 = token;
    return epoll_ctl(pfd, op, fd, &ev);
}

int pg_poll_add(int pfd, int fd, uint32_t mask, uint64_t token) {
    return epoll_ctl_op(pfd, EPOLL_CTL_ADD, fd, mask, token);
}
int pg_poll_mod(int pfd, int fd, uint32_t mask, uint64_t token) {
    return epoll_ctl_op(pfd, EPOLL_CTL_MOD, fd, mask, token);
}
int pg_poll_del(int pfd, int fd, uint32_t last_mask) {
    (void)last_mask;
    return epoll_ctl(pfd, EPOLL_CTL_DEL, fd, NULL);
}

int pg_poll_wait(int pfd, pg_event *out, int max_events, int timeout_ms) {
    struct epoll_event evs[256];
    if (max_events > 256) max_events = 256;
    int n = epoll_wait(pfd, evs, max_events, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < n; i++) {
        uint32_t m = 0;
        uint32_t e = evs[i].events;
        if (e & EPOLLIN)  m |= PG_POLL_READ;
        if (e & EPOLLOUT) m |= PG_POLL_WRITE;
        if (e & EPOLLERR) m |= PG_POLL_ERR;
        if (e & (EPOLLHUP | EPOLLRDHUP)) m |= PG_POLL_HUP;
        out[i].token = evs[i].data.u64;
        out[i].mask = m;
        out[i]._pad = 0;
    }
    return n;
}

#else /* kqueue */

int pg_poll_create(void) {
    int fd = kqueue();
    if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

/* kqueue has no MOD: we always express the desired mask as an ADD for the
 * filters we want and a DELETE for the ones we do not, tolerating ENOENT. */
static int kq_apply(int pfd, int fd, uint32_t mask, uint64_t token) {
    struct kevent ch[2];
    struct kevent res[2];
    struct timespec zero;
    zero.tv_sec = 0;
    zero.tv_nsec = 0;
    int n = 0;
    void *ud = (void *)(uintptr_t)token;
    EV_SET(&ch[n], fd, EVFILT_READ,
           (mask & PG_POLL_READ) ? (EV_ADD | EV_ENABLE) : EV_DELETE, 0, 0, ud);
    n++;
    EV_SET(&ch[n], fd, EVFILT_WRITE,
           (mask & PG_POLL_WRITE) ? (EV_ADD | EV_ENABLE) : EV_DELETE, 0, 0, ud);
    n++;
    int r = kevent(pfd, ch, n, res, n, &zero);
    if (r < 0) return -1;
    for (int i = 0; i < r; i++) {
        if ((res[i].flags & EV_ERROR) && res[i].data != 0 && res[i].data != ENOENT) {
            errno = (int)res[i].data;
            return -1;
        }
    }
    return 0;
}

int pg_poll_add(int pfd, int fd, uint32_t mask, uint64_t token) { return kq_apply(pfd, fd, mask, token); }
int pg_poll_mod(int pfd, int fd, uint32_t mask, uint64_t token) { return kq_apply(pfd, fd, mask, token); }
int pg_poll_del(int pfd, int fd, uint32_t last_mask) {
    (void)last_mask;
    return kq_apply(pfd, fd, 0, 0);
}

int pg_poll_wait(int pfd, pg_event *out, int max_events, int timeout_ms) {
    struct kevent evs[256];
    if (max_events > 256) max_events = 256;
    struct timespec ts;
    struct timespec *tsp = NULL;
    if (timeout_ms >= 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
        tsp = &ts;
    }
    int n = kevent(pfd, NULL, 0, evs, max_events, tsp);
    if (n < 0) return errno == EINTR ? 0 : -1;
    /* Coalesce read+write readiness for the same token into one entry so the
     * Swift side sees the same shape it sees from epoll. */
    int w = 0;
    for (int i = 0; i < n; i++) {
        uint32_t m = 0;
        if (evs[i].filter == EVFILT_READ)  m |= PG_POLL_READ;
        if (evs[i].filter == EVFILT_WRITE) m |= PG_POLL_WRITE;
        if (evs[i].flags & EV_EOF)   m |= PG_POLL_HUP;
        if (evs[i].flags & EV_ERROR) m |= PG_POLL_ERR;
        uint64_t tok = (uint64_t)(uintptr_t)evs[i].udata;
        int merged = 0;
        for (int j = 0; j < w; j++) {
            if (out[j].token == tok) { out[j].mask |= m; merged = 1; break; }
        }
        if (!merged) { out[w].token = tok; out[w].mask = m; out[w]._pad = 0; w++; }
    }
    return w;
}

#endif

/* ======================================================================== */
/* Sockets                                                                  */
/* ======================================================================== */

int pg_set_nonblock(int fd) {
    int f = fcntl(fd, F_GETFL, 0);
    if (f < 0) return -1;
    return fcntl(fd, F_SETFL, f | O_NONBLOCK);
}

int pg_set_cloexec(int fd) {
    int f = fcntl(fd, F_GETFD, 0);
    if (f < 0) return -1;
    return fcntl(fd, F_SETFD, f | FD_CLOEXEC);
}

int pg_set_nodelay(int fd, int on) {
    return setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
}

int pg_shutdown_write(int fd) { return shutdown(fd, SHUT_WR); }
int pg_close(int fd) { return close(fd); }

int pg_listen_tcp(const char *host, uint16_t port, int backlog, int reuseport, int v6only) {
    char portbuf[8];
    snprintf(portbuf, sizeof portbuf, "%u", (unsigned)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV;

    struct addrinfo *res = NULL;
    const char *h = (host && host[0]) ? host : NULL;
    int rc = getaddrinfo(h, portbuf, &hints, &res);
    if (rc != 0) { errno = EINVAL; return -1; }

    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
        if (reuseport) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#else
        (void)reuseport;
#endif
        if (ai->ai_family == AF_INET6) {
            int v = v6only ? 1 : 0;
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v, sizeof v);
        }
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, backlog) == 0) {
            pg_set_nonblock(fd);
            pg_set_cloexec(fd);
            freeaddrinfo(res);
            return fd;
        }
        int saved = errno;
        close(fd);
        fd = -1;
        errno = saved;
    }
    freeaddrinfo(res);
    return -1;
}

int pg_listen_unix(const char *path, int backlog, int unlink_existing) {
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n >= sizeof sa.sun_path) { errno = ENAMETOOLONG; return -1; }
    memcpy(sa.sun_path, path, n);
    if (unlink_existing) unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(fd, backlog) != 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    pg_set_nonblock(fd);
    pg_set_cloexec(fd);
    return fd;
}

static void fill_peer(const struct sockaddr_storage *ss, socklen_t slen,
                      char *peer, size_t peer_len, uint16_t *port) {
    if (peer && peer_len) peer[0] = 0;
    if (port) *port = 0;
    if (ss->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)ss;
        if (peer) getnameinfo((const struct sockaddr *)ss, slen, peer, (socklen_t)peer_len,
                              NULL, 0, NI_NUMERICHOST);
        if (port) *port = ntohs(a->sin_port);
    } else if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)ss;
        if (peer) getnameinfo((const struct sockaddr *)ss, slen, peer, (socklen_t)peer_len,
                              NULL, 0, NI_NUMERICHOST);
        if (port) *port = ntohs(a->sin6_port);
    } else if (ss->ss_family == AF_UNIX) {
        if (peer && peer_len > 4) memcpy(peer, "unix", 5);
    }
}

int pg_accept(int lfd, char *peer, size_t peer_len, uint16_t *peer_port) {
    struct sockaddr_storage ss;
    socklen_t slen = sizeof ss;
#if defined(__linux__)
    int fd = accept4(lfd, (struct sockaddr *)&ss, &slen, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) return -1;
#else
    int fd = accept(lfd, (struct sockaddr *)&ss, &slen);
    if (fd < 0) return -1;
    pg_set_nonblock(fd);
    pg_set_cloexec(fd);
#endif
    fill_peer(&ss, slen, peer, peer_len, peer_port);
    return fd;
}

ssize_t pg_read(int fd, void *buf, size_t n)         { return read(fd, buf, n); }
ssize_t pg_write(int fd, const void *buf, size_t n)  { return write(fd, buf, n); }
ssize_t pg_writev(int fd, const struct iovec *iov, int iovcnt) { return writev(fd, iov, iovcnt); }

ssize_t pg_sendfile(int out_fd, int in_fd, off_t *offset, size_t count) {
#if defined(__linux__)
    return sendfile(out_fd, in_fd, offset, count);
#elif defined(__APPLE__)
    off_t len = (off_t)count;
    int r = sendfile(in_fd, out_fd, *offset, &len, NULL, 0);
    *offset += len;
    if (len > 0) return (ssize_t)len;
    return r < 0 ? -1 : 0;
#else
    off_t sbytes = 0;
    int r = sendfile(in_fd, out_fd, *offset, count, NULL, &sbytes, 0);
    *offset += sbytes;
    if (sbytes > 0) return (ssize_t)sbytes;
    return r < 0 ? -1 : 0;
#endif
}

#if defined(__linux__) && defined(SYS_openat2)
/* 1 once openat2 has been refused as a system call: an old kernel, or a
 * container whose seccomp profile predates it. Checked once, not per request. */
static int g_openat2_unavailable = -1;

/* The file under `root`, opened so that nothing about the path can take it
 * outside: RESOLVE_BENEATH has the kernel refuse `..` above the root and any
 * absolute symlink, during the one walk that also opens it. Returns the
 * descriptor, -1 for a path that does not lead to a regular file inside the
 * root, or -2 when openat2 itself is unavailable. */
static int static_open_beneath(const char *root, const char *relative) {
    if (g_openat2_unavailable < 0) {
        const char *env = getenv("GARUDA_NO_OPENAT2");
        g_openat2_unavailable = (env && env[0] == '1') ? 1 : 0;
    }
    if (g_openat2_unavailable) return -2;

    /* The root is opened per request rather than kept: a deployment that
     * switches a symlink to a new release directory has to be served from the
     * new one at once, as it was when every request resolved the root. */
    int dir = open(root, O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) return -1;
    struct open_how how;
    memset(&how, 0, sizeof how);
    how.flags = O_RDONLY | O_CLOEXEC;
    how.resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS;
    long fd = syscall(SYS_openat2, dir, relative, &how, sizeof how);
    int saved = errno;
    close(dir);
    if (fd < 0) {
        if (saved == ENOSYS || saved == EPERM) {
            g_openat2_unavailable = 1;
            return -2;
        }
        /* EXDEV is also what an absolute symlink gets, even one that lands
         * inside the root. Those have always been served, so this one request
         * is decided the old way; the old way still refuses real escapes. */
        if (saved == EXDEV) return -2;
        return -1;
    }
    return (int)fd;
}
#endif

/* Nanoseconds, not seconds: the static ETag is built from this and the size,
 * and a file rewritten at the same size within one second has to get a new
 * one. */
static long long stat_mtime_ns(const struct stat *st) {
#if defined(__APPLE__)
    return (long long)st->st_mtimespec.tv_sec * 1000000000LL + st->st_mtimespec.tv_nsec;
#else
    return (long long)st->st_mtim.tv_sec * 1000000000LL + st->st_mtim.tv_nsec;
#endif
}

int pg_static_open(const char *root, const char *relative,
                   long long *size, long long *mtime) {
    while (*relative == '/') relative++;

#if defined(__linux__) && defined(SYS_openat2)
    int beneath = static_open_beneath(root, *relative ? relative : ".");
    if (beneath != -2) {
        if (beneath < 0) return -1;
        struct stat st;
        if (fstat(beneath, &st) != 0 || !S_ISREG(st.st_mode)) {
            close(beneath);
            return -1;
        }
        if (size) *size = (long long)st.st_size;
        if (mtime) *mtime = stat_mtime_ns(&st);
        return beneath;
    }
#endif

    /* Without openat2: resolve both paths and compare. Two walks where the
     * one above takes one, and a window between the check and the open that
     * the kernel closes above. */
    char real_root[PATH_MAX];
    if (!realpath(root, real_root)) return -1;

    /* A leading slash on the relative part would make snprintf produce "//x",
     * which resolves the same way, but skipping it keeps the joined path the
     * obvious one. */
    while (*relative == '/') relative++;

    char joined[PATH_MAX];
    int n = snprintf(joined, sizeof joined, "%s/%s", real_root, relative);
    if (n < 0 || (size_t)n >= sizeof joined) return -1;

    /* realpath resolves `..` and follows symlinks, so the containment check
     * below is against where the path actually lands rather than how it is
     * spelled. A path that does not exist fails here, which is the 404. */
    char real[PATH_MAX];
    if (!realpath(joined, real)) return -1;

    size_t root_len = strlen(real_root);
    if (strncmp(real, real_root, root_len) != 0) return -1;
    /* The next character has to be the separator, or the root is the whole
     * path: without this, a root of /var/www would also accept /var/www-old.
     * A root of "/" already ends in the separator. */
    if (!(root_len == 1 && real_root[0] == '/')) {
        if (real[root_len] != '/' && real[root_len] != '\0') return -1;
    }

    int fd = open(real, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    if (size) *size = (long long)st.st_size;
    if (mtime) *mtime = stat_mtime_ns(&st);
    return fd;
}

int pg_poll_single(int fd, int for_write, int timeout_ms) {
    struct pollfd p;
    p.fd = fd;
    p.events = (short)(for_write ? POLLOUT : POLLIN);
    p.revents = 0;
    int r = poll(&p, 1, timeout_ms);
    if (r < 0) return -1;
    if (r == 0) return 0;
    if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    return 1;
}

int pg_errno(void) { return errno; }
void pg_set_errno(int e) { errno = e; }
const char *pg_strerror(int e) { return strerror(e); }
int pg_err_is_again(int e) { return e == EAGAIN || e == EWOULDBLOCK; }
int pg_err_is_intr(int e) { return e == EINTR; }

/* ======================================================================== */
/* Time                                                                     */
/* ======================================================================== */

uint64_t pg_monotonic_ms(void) {
    struct timespec ts;
#if defined(CLOCK_MONOTONIC_COARSE)
    /* Coarse is a vDSO read of a cached value; we only use this for
     * second-granularity idle timeouts, so the precision loss is free. */
    clock_gettime(CLOCK_MONOTONIC_COARSE, &ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

uint64_t pg_monotonic_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
}

uint64_t pg_realtime_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
}

int pg_set_rx_timestamps(int fd) {
    int on = 1;
#if defined(SO_TIMESTAMPNS)
    return setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &on, sizeof on);
#elif defined(SO_TIMESTAMP)
    return setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &on, sizeof on);
#else
    (void)fd; (void)on;
    return -1;
#endif
}

long pg_read_stamped(int fd, void *buf, size_t n, uint64_t *arrived_us) {
    *arrived_us = 0;
    struct iovec iov = { .iov_base = buf, .iov_len = n };
    char control[64];
    struct msghdr mh;
    memset(&mh, 0, sizeof mh);
    mh.msg_iov = &iov;
    mh.msg_iovlen = 1;
    mh.msg_control = control;
    mh.msg_controllen = sizeof control;
    ssize_t got;
    do { got = recvmsg(fd, &mh, 0); } while (got < 0 && errno == EINTR);
    if (got <= 0) return (long)got;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&mh); cm; cm = CMSG_NXTHDR(&mh, cm)) {
        if (cm->cmsg_level != SOL_SOCKET) continue;
#if defined(SCM_TIMESTAMPNS)
        if (cm->cmsg_type == SCM_TIMESTAMPNS) {
            struct timespec ts;
            memcpy(&ts, CMSG_DATA(cm), sizeof ts);
            if (ts.tv_sec > 0) {
                *arrived_us = (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
            }
        }
#endif
#if defined(SCM_TIMESTAMP)
        if (cm->cmsg_type == SCM_TIMESTAMP) {
            struct timeval tv;
            memcpy(&tv, CMSG_DATA(cm), sizeof tv);
            if (tv.tv_sec > 0) {
                *arrived_us = (uint64_t)tv.tv_sec * 1000000u + (uint64_t)tv.tv_usec;
            }
        }
#endif
    }
    return (long)got;
}

int64_t pg_unix_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec;
}

static const char *const kDays[7]    = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
static const char *const kMonths[12] = {"Jan","Feb","Mar","Apr","May","Jun",
                                        "Jul","Aug","Sep","Oct","Nov","Dec"};

static void put2(char *p, int v) { p[0] = (char)(48 + v / 10); p[1] = (char)(48 + v % 10); }

int pg_http_date(char *buf29, int64_t t) {
    /* civil-from-days, no locale state, no struct tm, no allocation. Called at
     * most once per second by the date cache. */
    int64_t days = t / 86400;
    int64_t secs = t % 86400;
    if (secs < 0) { secs += 86400; days -= 1; }

    int wday = (int)((days + 4) % 7);      /* 1970-01-01 was a Thursday */
    if (wday < 0) wday += 7;

    int64_t z = days + 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp + (mp < 10 ? 3 : -9);
    if (m <= 2) y += 1;

    memcpy(buf29, kDays[wday], 3);
    buf29[3] = ','; buf29[4] = ' ';
    put2(buf29 + 5, (int)d);
    buf29[7] = ' ';
    memcpy(buf29 + 8, kMonths[m - 1], 3);
    buf29[11] = ' ';
    int yy = (int)y;
    buf29[12] = (char)(48 + (yy / 1000) % 10);
    buf29[13] = (char)(48 + (yy / 100) % 10);
    buf29[14] = (char)(48 + (yy / 10) % 10);
    buf29[15] = (char)(48 + yy % 10);
    buf29[16] = ' ';
    put2(buf29 + 17, (int)(secs / 3600));
    buf29[19] = ':';
    put2(buf29 + 20, (int)((secs / 60) % 60));
    buf29[22] = ':';
    put2(buf29 + 23, (int)(secs % 60));
    memcpy(buf29 + 25, " GMT", 4);
    return 29;
}

/* ======================================================================== */
/* Signals / processes                                                      */
/* ======================================================================== */

static int g_sigpipe[2] = {-1, -1};

static void sig_handler(int signo) {
    /* async-signal-safe: one byte, ignore failure, preserve errno */
    int saved = errno;
    unsigned char b = (unsigned char)signo;
    ssize_t r = write(g_sigpipe[1], &b, 1);
    (void)r;
    errno = saved;
}

static void install(int signo) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sig_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(signo, &sa, NULL);
}

int pg_signal_pipe_init(void) {
    if (g_sigpipe[0] >= 0) return g_sigpipe[0];
    if (pipe(g_sigpipe) != 0) return -1;
    pg_set_nonblock(g_sigpipe[0]);
    pg_set_nonblock(g_sigpipe[1]);
    pg_set_cloexec(g_sigpipe[0]);
    pg_set_cloexec(g_sigpipe[1]);
    install(SIGINT);
    install(SIGTERM);
    install(SIGQUIT);
    install(SIGHUP);
    install(SIGCHLD);
    install(SIGUSR1);
    return g_sigpipe[0];
}

/* The signals the pipe carries. */
static void piped_signals(sigset_t *set) {
    sigemptyset(set);
    sigaddset(set, SIGINT);
    sigaddset(set, SIGTERM);
    sigaddset(set, SIGQUIT);
    sigaddset(set, SIGHUP);
    sigaddset(set, SIGUSR1);
}

/* fork(), for a worker: the child comes back with a signal pipe of its own.
 *
 * A child inherits the supervisor's handlers along with its pipe, and the pipe
 * is the supervisor's to read. Closing it in the child and making a new one
 * only once the worker is ready to poll -- which is after its TLS context,
 * QUIC listener and extra listeners have been set up --
 * left a window in which a SIGTERM ran the handler, wrote to a descriptor that
 * was gone, and vanished. The worker then served on until the supervisor's
 * grace period ran out and it was killed.
 *
 * So the signals are blocked across the fork and the child's pipe is made
 * before they are unblocked. One sent at any point after fork waits, blocked,
 * and is then written to the pipe the worker will read. */
pid_t pg_fork_worker(void) {
    sigset_t set, previous;
    piped_signals(&set);
    sigprocmask(SIG_BLOCK, &set, &previous);
    pid_t pid = fork();
    if (pid == 0) {
        if (g_sigpipe[0] >= 0) { close(g_sigpipe[0]); close(g_sigpipe[1]); }
        g_sigpipe[0] = -1;
        g_sigpipe[1] = -1;
        if (pipe(g_sigpipe) == 0) {
            pg_set_nonblock(g_sigpipe[0]);
            pg_set_nonblock(g_sigpipe[1]);
            pg_set_cloexec(g_sigpipe[0]);
            pg_set_cloexec(g_sigpipe[1]);
        } else {
            g_sigpipe[0] = -1;
            g_sigpipe[1] = -1;
        }
    }
    sigprocmask(SIG_SETMASK, &previous, NULL);
    return pid;
}

void pg_block_piped_signals(void) {
    sigset_t set;
    piped_signals(&set);
    sigprocmask(SIG_BLOCK, &set, NULL);
}

void pg_unblock_piped_signals(void) {
    sigset_t set;
    piped_signals(&set);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
}

/* For a child that is not a worker: the ordinary dispositions back, and no
 * pipe. Without this a SIGTERM to such a child ran the inherited handler,
 * which wrote the signal into the supervisor's pipe -- so the helper ignored
 * it, and the supervisor took it as addressed to itself. */
void pg_signals_default(void) {
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGUSR1, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);
    if (g_sigpipe[0] >= 0) { close(g_sigpipe[0]); close(g_sigpipe[1]); }
    g_sigpipe[0] = -1;
    g_sigpipe[1] = -1;
}

void pg_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); }

pid_t pg_fork(void) { return fork(); }
pid_t pg_waitpid(pid_t pid, int *status, int nohang) {
    return waitpid(pid, status, nohang ? WNOHANG : 0);
}
int pg_kill(pid_t pid, int sig) { return kill(pid, sig); }
pid_t pg_getpid(void) { return getpid(); }

#ifdef __linux__
#include <sys/prctl.h>
#endif

/* The name top, ps -e, pgrep -x and pkill match on. The executable normally
 * has it already; setting it keeps `pkill garuda` working when the file was
 * renamed or started through a link of another name. Only the short kernel
 * name changes -- the command line still says what was run. It is inherited
 * across fork and by threads created afterwards. */
void pg_set_process_name(const char *name) {
#ifdef __linux__
    prctl(PR_SET_NAME, name, 0, 0, 0);
#else
    (void)name;
#endif
}

int pg_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
}

long pg_raise_nofile_limit(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) return -1;
    if (rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
        getrlimit(RLIMIT_NOFILE, &rl);
    }
    return (long)rl.rlim_cur;
}
