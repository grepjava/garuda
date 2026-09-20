/* The socketpair floor: the same round trip with no TLS at all, so the
 * record figures can be read as library cost rather than library cost plus
 * a syscall bill both arms pay equally.
 */
#define _GNU_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>
static double cpu_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 200000;
    int fds[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds)) return 1;
    char request[80], answer[200], scratch[512];
    memset(request, 0x71, sizeof request); memset(answer, 0x61, sizeof answer);
    double t0 = cpu_seconds();
    for (int i = 0; i < n; i++) {
        if (write(fds[1], request, sizeof request) != (ssize_t)sizeof request) return 1;
        if (read(fds[0], scratch, sizeof scratch) != (ssize_t)sizeof request) return 1;
        if (write(fds[0], answer, sizeof answer) != (ssize_t)sizeof answer) return 1;
        if (read(fds[1], scratch, sizeof scratch) != (ssize_t)sizeof answer) return 1;
    }
    double t1 = cpu_seconds();
    printf("plain      record-pair %6.2f us cpu (socketpair floor)\n", (t1 - t0) * 1e6 / n);
    return 0;
}
