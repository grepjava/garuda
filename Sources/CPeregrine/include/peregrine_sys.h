#ifndef PEREGRINE_SYS_H
#define PEREGRINE_SYS_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Readiness poller.
 *
 * epoll on Linux, kqueue on Darwin/BSD, presented as one flat API returning a
 * plain array of (token, mask) pairs. Doing the translation here keeps Swift
 * away from `struct epoll_event` (packed on x86-64) and `union epoll_data`.
 *
 * The poller is *level triggered* on purpose. Peregrine hands its poller fd to
 * asyncio via loop.add_reader() when running ASGI apps; that outer poll only
 * works if the poller fd stays readable while events remain unconsumed.
 * ------------------------------------------------------------------------- */

#define PG_POLL_READ   0x1u
#define PG_POLL_WRITE  0x2u
#define PG_POLL_ERR    0x4u
#define PG_POLL_HUP    0x8u

typedef struct {
    uint64_t token;
    uint32_t mask;
    uint32_t _pad;
} pg_event;

int  pg_poll_create(void);
int  pg_poll_add(int pfd, int fd, uint32_t mask, uint64_t token);
int  pg_poll_mod(int pfd, int fd, uint32_t mask, uint64_t token);
int  pg_poll_del(int pfd, int fd, uint32_t last_mask);
/* Returns number of events, or -1 with errno (EINTR is reported as 0). */
int  pg_poll_wait(int pfd, pg_event *out, int max_events, int timeout_ms);

/* ---------------------------------------------------------------------------
 * Sockets
 * ------------------------------------------------------------------------- */

/* Bind + listen. `host` may be NULL/"" (any), an IPv4/IPv6 literal or a name.
 * Returns fd or -1 (errno set). The socket is non-blocking and, when
 * `reuseport` is set, carries SO_REUSEPORT so N worker processes can each own
 * an independent accept queue -- this is what removes the thundering herd and
 * the shared-accept-lock from the multi-process story. */
int pg_listen_tcp(const char *host, uint16_t port, int backlog, int reuseport, int v6only);
/* A unix socket cannot be opened twice: binding requires the path to be free,
 * so `unlink_existing` removes a stale one. With several workers the listener
 * is therefore created once by the supervisor and inherited across fork --
 * letting each worker bind for itself would have every worker unlink and
 * replace the socket the previous one just published. */
int pg_listen_unix(const char *path, int backlog, int unlink_existing);

/* accept4() where available, accept()+fcntl() elsewhere. Fills `peer` with a
 * printable address and `peer_port`. Returns fd, or -1 with errno. */
int pg_accept(int lfd, char *peer, size_t peer_len, uint16_t *peer_port);

int pg_set_nonblock(int fd);
int pg_set_nodelay(int fd, int on);
int pg_set_cloexec(int fd);
int pg_shutdown_write(int fd);
int pg_close(int fd);

/* Local address of a listening socket, for the ASGI/WSGI `server` field. */
int pg_local_addr(int fd, char *host, size_t host_len, uint16_t *port);

ssize_t pg_read(int fd, void *buf, size_t n);
ssize_t pg_write(int fd, const void *buf, size_t n);
ssize_t pg_writev(int fd, const struct iovec *iov, int iovcnt);
/* Portable sendfile(); advances *offset. Returns bytes sent or -1. */
ssize_t pg_sendfile(int out_fd, int in_fd, off_t *offset, size_t count);

/* poll(2) on a single descriptor. Used only by the synchronous WSGI path when
 * a response outgrows the high-water mark and the worker must apply
 * backpressure rather than buffer without bound. */
int pg_poll_single(int fd, int for_write, int timeout_ms);

int pg_errno(void);
void pg_set_errno(int e);
const char *pg_strerror(int e);
int pg_err_is_again(int e);      /* EAGAIN / EWOULDBLOCK */
int pg_err_is_intr(int e);       /* EINTR */

/* ---------------------------------------------------------------------------
 * Time
 * ------------------------------------------------------------------------- */
uint64_t pg_monotonic_ms(void);
/* Precise monotonic microseconds. Unlike pg_monotonic_ms this never reads a
 * coarse clock: it times a single request, where the coarse clock's few
 * milliseconds of slack would be the whole measurement. */
uint64_t pg_monotonic_us(void);
/* IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT". Writes exactly 29 bytes,
 * no NUL. Returns 29. Hand-rolled: strftime() would pull in locale state. */
int pg_http_date(char *buf29, int64_t unix_seconds);
int64_t pg_unix_seconds(void);

/* ---------------------------------------------------------------------------
 * Process control / signals
 *
 * Signals are funnelled into a self-pipe so the readiness poller is the single
 * place the server ever blocks.
 * ------------------------------------------------------------------------- */
int  pg_signal_pipe_init(void);   /* returns readable fd, -1 on failure */
void pg_signal_pipe_reset(void);  /* after fork(): child gets a fresh pipe */
pid_t pg_fork(void);
pid_t pg_waitpid(pid_t pid, int *status, int nohang);
int  pg_kill(pid_t pid, int sig);
pid_t pg_getpid(void);
int  pg_cpu_count(void);
/* Raise RLIMIT_NOFILE to its hard limit; returns the resulting soft limit. */
long pg_raise_nofile_limit(void);
/* Arms a SIGALRM that _exit()s the process after `seconds`, so a shutdown
 * that wedges below the interpreter still terminates. 0 seconds disarms. */
void pg_exit_after(unsigned seconds, int code);
void pg_cancel_exit_timer(void);

/* Ignore SIGPIPE: a peer that vanishes mid-response must surface as EPIPE from
 * write(), never as a process-killing signal. */
void pg_ignore_sigpipe(void);

/* ---------------------------------------------------------------------------
 * Addresses, files, environment
 * ------------------------------------------------------------------------- */

/* inet_pton for both families. Writes 16 bytes (IPv4 left-aligned in the first
 * four) and reports 4 or 6 in *family. Returns 0 on success. */
int pg_parse_ip(const char *s, unsigned char out16[16], int *family);

int pg_unlink(const char *path);
const char *pg_getenv(const char *name);
int pg_path_exists(const char *path);
/* Modification time in nanoseconds, or -1. Used by --reload. */
int64_t pg_mtime_ns(const char *path);
int pg_is_dir(const char *path);
/* Non-blocking, close-on-exec pipe. */
int pg_pipe(int fds[2]);
int pg_random_bytes(void *out, size_t n);

/* ---------------------------------------------------------------------------
 * Threads
 *
 * Threads belong to the optional WSGI pool and, under --free-threaded, to the
 * workers themselves. They are exposed as opaque handles because
 * pthread_mutex_t and pthread_cond_t have platform-dependent size and alignment
 * that Swift would otherwise have to mirror exactly.
 * ------------------------------------------------------------------------- */

typedef struct pg_mutex pg_mutex;
typedef struct pg_cond pg_cond;

pg_mutex *pg_mutex_new(void);
void pg_mutex_free(pg_mutex *m);
void pg_mutex_lock(pg_mutex *m);
void pg_mutex_unlock(pg_mutex *m);

pg_cond *pg_cond_new(void);
void pg_cond_free(pg_cond *c);
void pg_cond_wait(pg_cond *c, pg_mutex *m);
void pg_cond_signal(pg_cond *c);
void pg_cond_broadcast(pg_cond *c);

/* Starts a detached thread with every signal blocked. Returns 0 on success. */
int pg_thread_spawn(void (*fn)(void *), void *arg);

/* The same, joinable, for threads whose exit the caller has to observe: under
 * --free-threaded the supervising thread must know that every worker has let go
 * of its connections before the ASGI lifespan is allowed to shut down. Returns
 * NULL on failure; the handle is freed by pg_thread_join. */
typedef struct pg_thread pg_thread;
pg_thread *pg_thread_start(void (*fn)(void *), void *arg);
void pg_thread_join(pg_thread *t);

/* Where the current thread's Worker lives.
 *
 * The server used to have exactly one worker per process, so this was a plain
 * global. Under --free-threaded there is one per thread, and the C callbacks
 * that need it -- the asyncio reader, ASGI send/receive -- are handed nothing
 * but a connection token, so they have to find it themselves. A thread-local is
 * the cheapest way to answer that: a register-relative load, no lock, and no
 * change to any call site. */
void *pg_worker_current(void);
void pg_worker_set_current(void *worker);

/* ---------------------------------------------------------------------------
 * WebSocket handshake primitives
 * ------------------------------------------------------------------------- */

void pg_sha1(const void *data, size_t n, unsigned char out20[20]);
/* Writes 4*ceil(n/3) bytes, no NUL. Returns the number written. */
size_t pg_base64(const void *data, size_t n, char *out);

#ifdef __cplusplus
}
#endif
#endif
