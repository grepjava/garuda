#define _GNU_SOURCE 1
#include "peregrine_watch.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <unistd.h>

#if defined(__linux__)
#  include <sys/inotify.h>
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) \
    || defined(__OpenBSD__) || defined(__DragonFly__)
#  define PG_WATCH_KQUEUE 1
#  include <sys/event.h>
#  include <sys/time.h>
#endif

#if defined(__linux__)

int pg_watch_open(void) {
    return inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
}

int pg_watch_add(int wfd, const char *dir) {
    /* Everything an editor does to a file, whether it writes in place or
     * writes a copy and renames it over the original. */
    uint32_t mask = IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_CREATE | IN_DELETE
                  | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF
                  | IN_ONLYDIR;
    return inotify_add_watch(wfd, dir, mask) < 0 ? -1 : 0;
}

int pg_watch_drain(int wfd) {
    char buf[4096];
    int any = 0;
    for (;;) {
        ssize_t n = read(wfd, buf, sizeof buf);
        if (n > 0) { any = 1; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return any;
        return any ? 1 : -1;
    }
}

void pg_watch_close(int wfd) {
    if (wfd >= 0) close(wfd);
}

#elif defined(PG_WATCH_KQUEUE)

/* kqueue watches descriptors, not paths, so each directory stays open for as
 * long as it is watched. There is one watcher in a process, the supervisor's,
 * so the list is process-wide. */
static int *g_dirs = NULL;
static int g_dir_count = 0;
static int g_dir_capacity = 0;

int pg_watch_open(void) {
    int fd = kqueue();
    if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

int pg_watch_add(int wfd, const char *dir) {
    int flags = O_RDONLY | O_CLOEXEC;
#  if defined(O_EVTONLY)
    flags = O_EVTONLY | O_CLOEXEC;
#  endif
    int fd = open(dir, flags);
    if (fd < 0) return -1;
    if (g_dir_count == g_dir_capacity) {
        int capacity = g_dir_capacity ? g_dir_capacity * 2 : 64;
        int *grown = realloc(g_dirs, (size_t)capacity * sizeof *g_dirs);
        if (!grown) { close(fd); return -1; }
        g_dirs = grown;
        g_dir_capacity = capacity;
    }
    /* A directory's own vnode changes when an entry is added, removed or
     * renamed -- which is what saving through a temporary file does. A file
     * written in place does not change its directory; the caller's periodic
     * scan is what notices that. */
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_DELETE,
           0, NULL);
    if (kevent(wfd, &ev, 1, NULL, 0, NULL) < 0) { close(fd); return -1; }
    g_dirs[g_dir_count++] = fd;
    return 0;
}

int pg_watch_drain(int wfd) {
    struct kevent evs[64];
    struct timespec zero = { 0, 0 };
    int any = 0;
    for (;;) {
        int n = kevent(wfd, NULL, 0, evs, 64, &zero);
        if (n > 0) { any = 1; if (n < 64) return 1; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return any ? 1 : -1;
        return any;
    }
}

void pg_watch_close(int wfd) {
    for (int i = 0; i < g_dir_count; i++) close(g_dirs[i]);
    free(g_dirs);
    g_dirs = NULL;
    g_dir_count = g_dir_capacity = 0;
    if (wfd >= 0) close(wfd);
}

#else

int pg_watch_open(void) { return -1; }
int pg_watch_add(int wfd, const char *dir) { (void)wfd; (void)dir; return -1; }
int pg_watch_drain(int wfd) { (void)wfd; return 0; }
void pg_watch_close(int wfd) { (void)wfd; }

#endif

int pg_poll_either(int a, int b, int timeout_ms) {
    struct pollfd p[2];
    p[0].fd = a;
    p[0].events = POLLIN;
    p[0].revents = 0;
    /* A negative descriptor is skipped by poll(2) itself. */
    p[1].fd = b;
    p[1].events = POLLIN;
    p[1].revents = 0;
    int r = poll(p, 2, timeout_ms);
    if (r < 0) return errno == EINTR ? 0 : -1;
    int mask = 0;
    if (p[0].revents & POLLIN) mask |= 1;
    if (b >= 0 && (p[1].revents & POLLIN)) mask |= 2;
    return mask;
}
