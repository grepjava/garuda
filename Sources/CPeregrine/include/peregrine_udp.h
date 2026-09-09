/* UDP, for QUIC.
 *
 * A QUIC server is one socket for every client, which changes what the
 * syscall layer has to provide compared with TCP:
 *
 *  * There is no accept(), so a datagram carries the only identification a
 *    connection has. Every receive reports the peer address.
 *  * A wildcard bind can receive on any local address, and a reply from the
 *    wrong source address is dropped by NAT and by the client alike. So the
 *    local address is recovered per datagram and put back on the way out.
 *  * One packet per syscall is the wrong ratio when a connection is moving
 *    data, so receives are batched.
 *  * ECN lives in the IP header, which means ancillary data both ways.
 */
#ifndef PEREGRINE_UDP_H
#define PEREGRINE_UDP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An address, kept opaque so Swift never sees sockaddr. It is a trivially
 * copyable value: connections keep one, and hand it straight back to send. */
typedef struct {
    uint64_t len;              /* 0 when unset */
    unsigned char sa[32];      /* sockaddr_in or sockaddr_in6 */
} pg_udp_addr;

/* One received datagram. */
typedef struct {
    pg_udp_addr peer;
    pg_udp_addr local;
    uint32_t len;
    uint8_t ecn;               /* 0 Not-ECT, 1 ECT(1), 2 ECT(0), 3 CE */
    uint8_t _pad[3];
} pg_udp_msg;

/* Binds a non-blocking UDP socket, with SO_REUSEPORT when asked so each
 * worker owns an independent receive queue. Returns fd or -1. */
int pg_bind_udp(const char *host, uint16_t port, int reuseport, int v6only);

/* Receives up to `count` datagrams into one buffer, datagram i at
 * `buf + i * stride`. Returns how many arrived, 0 when the socket is empty,
 * -1 on a real error. Datagrams larger than `stride` are dropped, as QUIC
 * requires of anything over the maximum packet size. */
int pg_udp_recv_batch(int fd, void *buf, size_t stride,
                      pg_udp_msg *msgs, int count);

/* Sends one datagram from `local` (may be NULL, or unset, for the kernel's
 * choice). Returns bytes sent, or -1 with errno; EAGAIN means the send buffer
 * is full and the caller should wait for writability. */
long pg_udp_send(int fd, const void *buf, size_t len,
                 const pg_udp_addr *peer, const pg_udp_addr *local,
                 uint8_t ecn);

/* Printable form, for logging and the ASGI `client` field. */
int pg_udp_addr_text(const pg_udp_addr *addr, char *host, size_t host_len,
                     uint16_t *port);

/* Local address of a bound UDP socket, for the ASGI `server` field. */
int pg_udp_local_addr(int fd, char *host, size_t host_len, uint16_t *port);

#ifdef __cplusplus
}
#endif

#endif /* PEREGRINE_UDP_H */
