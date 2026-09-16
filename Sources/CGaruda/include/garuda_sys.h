#ifndef GARUDA_SYS_H
#define GARUDA_SYS_H

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
 * The poller is *level triggered* on purpose: an event not acted on in one pass
 * is reported again on the next wait rather than lost, so nothing has to
 * remember that it owes a read. The price is that interest in bytes nobody will
 * consume has to be dropped, or the wait spins.
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

/* Starts a TCP connection and returns at once. The socket is non-blocking and
 * close-on-exec, so the caller waits for writability and then asks
 * `pg_connect_error` how it went.
 *
 * `host` must be an IPv4 or IPv6 literal: this resolves nothing, because
 * getaddrinfo blocks, and blocking a worker is the one thing an outbound
 * connection on the event loop exists to avoid. A name is EINVAL, and naming
 * is a layer above this one.
 *
 * Returns fd with *in_progress set to 1 when the connection is still being
 * made -- the usual case -- or 0 when it completed immediately, which happens
 * on loopback. Returns -1 with errno on a real failure. */
int pg_connect_tcp(const char *host, uint16_t port, int *in_progress);

/* The same for a unix socket, which also usually completes at once. */
int pg_connect_unix(const char *path, int *in_progress);

/* SO_ERROR: 0 when the connection is up, otherwise the errno that stopped it.
 * A non-blocking connect reports its outcome here and nowhere else -- the
 * socket simply becomes writable either way. */
int pg_connect_error(int fd);

int pg_set_nonblock(int fd);
int pg_set_nodelay(int fd, int on);
int pg_set_cloexec(int fd);
int pg_shutdown_write(int fd);
int pg_close(int fd);

ssize_t pg_read(int fd, void *buf, size_t n);
ssize_t pg_write(int fd, const void *buf, size_t n);
ssize_t pg_writev(int fd, const struct iovec *iov, int iovcnt);
/* Portable sendfile(); advances *offset. Returns bytes sent or -1. */
ssize_t pg_sendfile(int out_fd, int in_fd, off_t *offset, size_t count);

/* Opens a regular file under `root` for a static route, reporting its size and
 * modification time in nanoseconds since the epoch.
 *
 * `relative` is the request path with the route prefix removed and already
 * percent-decoded. Both paths are resolved with realpath(3) and the result must
 * still lie inside the resolved root, which is what stops `..` and a symlink
 * pointing out of the tree from reaching anything. Only regular files open:
 * a directory, a fifo or a device is refused rather than served.
 *
 * Returns the descriptor, or -1. */
int pg_static_open(const char *root, const char *relative,
                   long long *size, long long *mtime);

/* Opens an absolute path read-only, close-on-exec, for a small system file the
 * server reads whole at start-up -- /etc/resolv.conf and nothing larger.
 *
 * Deliberately not pg_static_open, which resolves a relative path against a
 * root and refuses anything outside it. That is what serving files needs and
 * the opposite of what this needs. Only regular files open, so a path that has
 * been swapped for a fifo cannot make start-up block for ever.
 *
 * Returns the descriptor, or -1 with errno set. */
int pg_open_read(const char *path);

/* A datagram socket connected to `host` and `port`, both numeric.
 *
 * Connected rather than bare, so the kernel refuses datagrams from anyone but
 * the nameserver that was asked: an off-path answer has to guess the query id
 * and the source port, and this takes the port away as something to guess.
 *
 * There is no in_progress here, unlike pg_connect_tcp. connect(2) on a
 * datagram socket only records the peer, so it returns at once or not at all.
 *
 * Returns the descriptor, or -1 with errno set; EINVAL means the host was not
 * an address literal. */
int pg_connect_udp(const char *host, uint16_t port);

/* The port a socket is actually bound to, which for a bind to port 0 is the
 * one the kernel chose. Returns 0 on failure.
 *
 * Without this a test that needs a server of its own has to pick a number and
 * hope nothing else on the machine holds it. The outbound tests avoided the
 * problem by using unix sockets; a nameserver cannot be one. */
uint16_t pg_local_port(int fd);

/* poll(2) on a single descriptor, for a wait outside the readiness poller: the
 * supervisor checking whether a replacement worker has reported ready. */
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
/* Wall-clock microseconds since the Unix epoch. For timestamps another system
 * compares against its own clock; intervals belong to pg_monotonic_us. */
uint64_t pg_realtime_us(void);

/* Asks the kernel to timestamp data as it arrives on `fd`. Set on a listening
 * socket, it is inherited by every connection accepted from it -- and it has
 * to be set there, before the connection exists, or the first request's
 * packets arrive with no timestamp to report. 0 on success. */
int pg_set_rx_timestamps(int fd);

/* read() through recvmsg, also reporting when the kernel received the last
 * of the bytes returned, as wall-clock microseconds. `*arrived_us` is 0 when
 * the kernel recorded nothing (no timestamping, or a platform without it). */
long pg_read_stamped(int fd, void *buf, size_t n, uint64_t *arrived_us);
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
/* fork() for a worker: signals are held across it, and the child gets a signal
 * pipe of its own before they are released, so none sent during start-up is
 * lost. */
pid_t pg_fork_worker(void);
/* In a child that is not a worker: default signal dispositions, no pipe. */
void pg_signals_default(void);
pid_t pg_fork(void);
/* Sets the kernel's short process name (Linux; a no-op elsewhere). */
void pg_set_process_name(const char *name);
pid_t pg_waitpid(pid_t pid, int *status, int nohang);
int  pg_kill(pid_t pid, int sig);
pid_t pg_getpid(void);
int  pg_cpu_count(void);
/* Raise RLIMIT_NOFILE to its hard limit; returns the resulting soft limit. */
long pg_raise_nofile_limit(void);
/* Arms a SIGALRM that _exit()s the process after `seconds`, so a shutdown
 * that wedges anywhere still terminates. 0 seconds disarms. */
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
/* Modification time in nanoseconds, or -1. Used by --reload. */
int64_t pg_mtime_ns(const char *path);
int pg_is_dir(const char *path);
/* Non-blocking, close-on-exec pipe. */
int pg_pipe(int fds[2]);

/* --reload, restarting the supervisor on a rebuilt executable. */
/* The running executable's absolute path. 0, or -1 where it cannot be found. */
int pg_executable_path(char *out, size_t cap);
/* A digest of what a file is on disk -- device, inode, size, mode and
 * modification time -- or 0 when it does not exist or is not an executable
 * regular file (`executable`) or a regular file at all. */
uint64_t pg_file_signature(const char *path, int executable);
/* Runs `path --version` with its output discarded, waiting up to timeout_ms.
 * 1 when it exited 0, which says the file is a whole executable that starts. */
int pg_probe_executable(const char *path, int timeout_ms);
int pg_clear_cloexec(int fd);
/* execv. Returns only on failure, with errno set. */
int pg_execv(const char *path, char *const argv[]);
/* Blocks, and unblocks, the signals the supervisor's pipe carries. The mask
 * survives exec, so a signal arriving before the new image has handlers waits
 * for them instead of taking its default action. */
void pg_block_piped_signals(void);
void pg_unblock_piped_signals(void);
int pg_random_bytes(void *out, size_t n);

/* ---------------------------------------------------------------------------
 * The current worker
 * ------------------------------------------------------------------------- */

/* Where this process's Worker lives. There is one worker per process; the
 * storage is a thread-local, which reads as a register-relative load with no
 * lock. */
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
