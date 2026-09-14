/* Kernel notification of file changes, for --reload.
 *
 * A watch descriptor becomes readable when something changes in a directory
 * added to it: inotify on Linux, kqueue elsewhere on the BSDs and macOS. It is
 * a prompt to look, not an account of what changed -- the caller rescans, so a
 * missed or merged event costs latency and nothing else. Where neither exists,
 * pg_watch_open returns -1 and the caller polls. */
#ifndef GARUDA_WATCH_H
#define GARUDA_WATCH_H

/* A new watch descriptor, non-blocking and close-on-exec, or -1. */
int pg_watch_open(void);

/* Watches one directory, not the tree under it. Returns 0 or -1. Adding the
 * same directory twice is the caller's to avoid: on kqueue it opens the
 * directory again. */
int pg_watch_add(int wfd, const char *dir);

/* Reads and discards whatever is pending. Returns 1 when there was anything,
 * 0 when there was not, -1 on error. */
int pg_watch_drain(int wfd);

/* Closes the watch descriptor, and on kqueue every directory it opened. */
void pg_watch_close(int wfd);

/* Waits for either of two descriptors to become readable. `b` may be -1.
 * Returns a mask, 1 for `a` and 2 for `b`, 0 on timeout, -1 on error. */
int pg_poll_either(int a, int b, int timeout_ms);

#endif
