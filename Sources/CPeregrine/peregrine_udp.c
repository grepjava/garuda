/* UDP for QUIC. See peregrine_udp.h for why this is not just read/write.
 *
 * The awkward part is the local address. A server bound to the wildcard
 * address learns which of its own addresses a datagram arrived on only from
 * ancillary data, and must put the same address back on the reply -- otherwise
 * a multi-homed host answers from whichever address the routing table prefers
 * and the client, or the NAT between them, drops the packet as unrelated.
 * IP_PKTINFO carries it both ways on Linux; BSD splits it into
 * IP_RECVDSTADDR and IP_SENDSRCADDR.
 */

#define _GNU_SOURCE 1

#include "peregrine_udp.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#  include <linux/in6.h>
#endif

/* pg_set_nonblock / pg_set_cloexec live in peregrine_sys.c. */
int pg_set_nonblock(int fd);
int pg_set_cloexec(int fd);

int pg_bind_udp(const char *host, uint16_t port, int reuseport, int v6only) {
    char portbuf[8];
    snprintf(portbuf, sizeof portbuf, "%u", (unsigned)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV;

    struct addrinfo *res = NULL;
    const char *h = (host && host[0]) ? host : NULL;
    if (getaddrinfo(h, portbuf, &hints, &res) != 0) { errno = EINVAL; return -1; }

    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
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
#ifdef IPV6_RECVPKTINFO
            setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, sizeof one);
#endif
#ifdef IPV6_RECVTCLASS
            setsockopt(fd, IPPROTO_IPV6, IPV6_RECVTCLASS, &one, sizeof one);
#endif
        }
#ifdef IP_PKTINFO
        setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &one, sizeof one);
#elif defined(IP_RECVDSTADDR)
        setsockopt(fd, IPPROTO_IP, IP_RECVDSTADDR, &one, sizeof one);
#endif
#ifdef IP_RECVTOS
        setsockopt(fd, IPPROTO_IP, IP_RECVTOS, &one, sizeof one);
#endif
        /* A QUIC server must not fragment: a datagram too large for the path
         * is a signal, not something to paper over. */
#if defined(IP_MTU_DISCOVER) && defined(IP_PMTUDISC_DO)
        int mtu = IP_PMTUDISC_DO;
        setsockopt(fd, IPPROTO_IP, IP_MTU_DISCOVER, &mtu, sizeof mtu);
#elif defined(IP_DONTFRAG)
        setsockopt(fd, IPPROTO_IP, IP_DONTFRAG, &one, sizeof one);
#endif
        /* Receive queues fill in bursts; the default is far too small for a
         * server taking handshakes from many clients at once. */
        int bufsize = 2 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof bufsize);
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof bufsize);

        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            pg_set_nonblock(fd);
            pg_set_cloexec(fd);
            freeaddrinfo(res);
            return fd;
        }
        int saved = errno;
        close(fd);
        errno = saved;
    }
    freeaddrinfo(res);
    return -1;
}

static void store_addr(pg_udp_addr *out, const struct sockaddr *sa, socklen_t len) {
    out->len = 0;
    if (!sa || len == 0 || (size_t)len > sizeof out->sa) return;
    memcpy(out->sa, sa, (size_t)len);
    out->len = (uint64_t)len;
}

/* Pulls the destination address and the ECN bits out of a datagram's
 * ancillary data. */
static void read_cmsgs(struct msghdr *mh, pg_udp_msg *msg) {
    msg->local.len = 0;
    msg->ecn = 0;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(mh); cm; cm = CMSG_NXTHDR(mh, cm)) {
#ifdef IP_PKTINFO
        if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_PKTINFO) {
            struct in_pktinfo pi;
            memcpy(&pi, CMSG_DATA(cm), sizeof pi);
            struct sockaddr_in a;
            memset(&a, 0, sizeof a);
            a.sin_family = AF_INET;
            a.sin_addr = pi.ipi_addr;
            store_addr(&msg->local, (struct sockaddr *)&a, sizeof a);
            continue;
        }
#elif defined(IP_RECVDSTADDR)
        if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_RECVDSTADDR) {
            struct in_addr ia;
            memcpy(&ia, CMSG_DATA(cm), sizeof ia);
            struct sockaddr_in a;
            memset(&a, 0, sizeof a);
            a.sin_family = AF_INET;
            a.sin_addr = ia;
            store_addr(&msg->local, (struct sockaddr *)&a, sizeof a);
            continue;
        }
#endif
#ifdef IPV6_PKTINFO
        if (cm->cmsg_level == IPPROTO_IPV6 && cm->cmsg_type == IPV6_PKTINFO) {
            struct in6_pktinfo pi;
            memcpy(&pi, CMSG_DATA(cm), sizeof pi);
            struct sockaddr_in6 a;
            memset(&a, 0, sizeof a);
            a.sin6_family = AF_INET6;
            a.sin6_addr = pi.ipi6_addr;
            a.sin6_scope_id = pi.ipi6_ifindex;
            store_addr(&msg->local, (struct sockaddr *)&a, sizeof a);
            continue;
        }
#endif
#ifdef IP_TOS
        if (cm->cmsg_level == IPPROTO_IP
            && (cm->cmsg_type == IP_TOS
#  ifdef IP_RECVTOS
                || cm->cmsg_type == IP_RECVTOS
#  endif
               )) {
            unsigned char tos = 0;
            memcpy(&tos, CMSG_DATA(cm), 1);
            msg->ecn = tos & 0x03;
            continue;
        }
#endif
#ifdef IPV6_TCLASS
        if (cm->cmsg_level == IPPROTO_IPV6 && cm->cmsg_type == IPV6_TCLASS) {
            int tclass = 0;
            memcpy(&tclass, CMSG_DATA(cm), sizeof tclass);
            msg->ecn = (uint8_t)(tclass & 0x03);
            continue;
        }
#endif
    }
}

#define PG_CMSG_ROOM 256

int pg_udp_recv_batch(int fd, void *buf, size_t stride,
                      pg_udp_msg *msgs, int count) {
    if (count <= 0 || stride == 0) return 0;
#if defined(__linux__)
    enum { MAX_BATCH = 32 };
    if (count > MAX_BATCH) count = MAX_BATCH;

    struct mmsghdr hdrs[MAX_BATCH];
    struct iovec iov[MAX_BATCH];
    struct sockaddr_storage from[MAX_BATCH];
    unsigned char control[MAX_BATCH][PG_CMSG_ROOM];

    memset(hdrs, 0, sizeof(struct mmsghdr) * (size_t)count);
    for (int i = 0; i < count; i++) {
        iov[i].iov_base = (unsigned char *)buf + (size_t)i * stride;
        iov[i].iov_len = stride;
        hdrs[i].msg_hdr.msg_name = &from[i];
        hdrs[i].msg_hdr.msg_namelen = sizeof from[i];
        hdrs[i].msg_hdr.msg_iov = &iov[i];
        hdrs[i].msg_hdr.msg_iovlen = 1;
        hdrs[i].msg_hdr.msg_control = control[i];
        hdrs[i].msg_hdr.msg_controllen = PG_CMSG_ROOM;
    }

    int n;
    do {
        n = recvmmsg(fd, hdrs, (unsigned)count, 0, NULL);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }

    int kept = 0;
    for (int i = 0; i < n; i++) {
        /* A datagram that did not fit was truncated; QUIC has no way to use
         * half a packet, so it is dropped rather than mis-parsed. */
        if (hdrs[i].msg_hdr.msg_flags & MSG_TRUNC) continue;
        pg_udp_msg *m = &msgs[kept];
        store_addr(&m->peer, (struct sockaddr *)&from[i], hdrs[i].msg_hdr.msg_namelen);
        read_cmsgs(&hdrs[i].msg_hdr, m);
        m->len = hdrs[i].msg_len;
        /* Compact the buffer only when something was dropped. */
        if (kept != i) {
            memmove((unsigned char *)buf + (size_t)kept * stride,
                    (unsigned char *)buf + (size_t)i * stride, m->len);
        }
        kept++;
    }
    return kept;
#else
    int kept = 0;
    while (kept < count) {
        struct sockaddr_storage from;
        unsigned char control[PG_CMSG_ROOM];
        struct iovec iov;
        iov.iov_base = (unsigned char *)buf + (size_t)kept * stride;
        iov.iov_len = stride;

        struct msghdr mh;
        memset(&mh, 0, sizeof mh);
        mh.msg_name = &from;
        mh.msg_namelen = sizeof from;
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        mh.msg_control = control;
        mh.msg_controllen = PG_CMSG_ROOM;

        ssize_t n;
        do { n = recvmsg(fd, &mh, 0); } while (n < 0 && errno == EINTR);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return kept > 0 ? kept : -1;
        }
        if (mh.msg_flags & MSG_TRUNC) continue;
        pg_udp_msg *m = &msgs[kept];
        store_addr(&m->peer, (struct sockaddr *)&from, mh.msg_namelen);
        read_cmsgs(&mh, m);
        m->len = (uint32_t)n;
        kept++;
    }
    return kept;
#endif
}

long pg_udp_send(int fd, const void *buf, size_t len,
                 const pg_udp_addr *peer, const pg_udp_addr *local,
                 uint8_t ecn) {
    if (!peer || peer->len == 0) { errno = EINVAL; return -1; }

    struct iovec iov;
    iov.iov_base = (void *)buf;
    iov.iov_len = len;

    unsigned char control[PG_CMSG_ROOM];
    struct msghdr mh;
    memset(&mh, 0, sizeof mh);
    mh.msg_name = (void *)peer->sa;
    mh.msg_namelen = (socklen_t)peer->len;
    mh.msg_iov = &iov;
    mh.msg_iovlen = 1;
    mh.msg_control = control;
    mh.msg_controllen = 0;

    size_t used = 0;
    struct cmsghdr *cm = NULL;

    /* Reply from the address the client reached us on, not from whichever one
     * the routing table would pick. */
    if (local && local->len > 0) {
        const struct sockaddr *sa = (const struct sockaddr *)local->sa;
#ifdef IP_PKTINFO
        if (sa->sa_family == AF_INET) {
            mh.msg_controllen = (socklen_t)(sizeof control);
            cm = CMSG_FIRSTHDR(&mh);
            cm->cmsg_level = IPPROTO_IP;
            cm->cmsg_type = IP_PKTINFO;
            cm->cmsg_len = CMSG_LEN(sizeof(struct in_pktinfo));
            struct in_pktinfo pi;
            memset(&pi, 0, sizeof pi);
            pi.ipi_spec_dst = ((const struct sockaddr_in *)sa)->sin_addr;
            memcpy(CMSG_DATA(cm), &pi, sizeof pi);
            used += CMSG_SPACE(sizeof(struct in_pktinfo));
        }
#elif defined(IP_SENDSRCADDR)
        if (sa->sa_family == AF_INET) {
            mh.msg_controllen = (socklen_t)(sizeof control);
            cm = CMSG_FIRSTHDR(&mh);
            cm->cmsg_level = IPPROTO_IP;
            cm->cmsg_type = IP_SENDSRCADDR;
            cm->cmsg_len = CMSG_LEN(sizeof(struct in_addr));
            struct in_addr ia = ((const struct sockaddr_in *)sa)->sin_addr;
            memcpy(CMSG_DATA(cm), &ia, sizeof ia);
            used += CMSG_SPACE(sizeof(struct in_addr));
        }
#endif
#ifdef IPV6_PKTINFO
        if (sa->sa_family == AF_INET6) {
            mh.msg_controllen = (socklen_t)(sizeof control);
            cm = CMSG_FIRSTHDR(&mh);
            cm->cmsg_level = IPPROTO_IPV6;
            cm->cmsg_type = IPV6_PKTINFO;
            cm->cmsg_len = CMSG_LEN(sizeof(struct in6_pktinfo));
            struct in6_pktinfo pi;
            memset(&pi, 0, sizeof pi);
            pi.ipi6_addr = ((const struct sockaddr_in6 *)sa)->sin6_addr;
            memcpy(CMSG_DATA(cm), &pi, sizeof pi);
            used += CMSG_SPACE(sizeof(struct in6_pktinfo));
        }
#endif
    }

    if (ecn) {
        const struct sockaddr *sa = (const struct sockaddr *)peer->sa;
        mh.msg_controllen = (socklen_t)(sizeof control);
        struct cmsghdr *next = cm ? CMSG_NXTHDR(&mh, cm) : CMSG_FIRSTHDR(&mh);
        if (next) {
            if (sa->sa_family == AF_INET6) {
#ifdef IPV6_TCLASS
                next->cmsg_level = IPPROTO_IPV6;
                next->cmsg_type = IPV6_TCLASS;
                next->cmsg_len = CMSG_LEN(sizeof(int));
                int tclass = ecn & 0x03;
                memcpy(CMSG_DATA(next), &tclass, sizeof tclass);
                used += CMSG_SPACE(sizeof(int));
#endif
            } else {
#ifdef IP_TOS
                next->cmsg_level = IPPROTO_IP;
                next->cmsg_type = IP_TOS;
                next->cmsg_len = CMSG_LEN(sizeof(int));
                int tos = ecn & 0x03;
                memcpy(CMSG_DATA(next), &tos, sizeof tos);
                used += CMSG_SPACE(sizeof(int));
#endif
            }
        }
    }
    mh.msg_controllen = (socklen_t)used;
    if (used == 0) mh.msg_control = NULL;

    ssize_t n;
    do { n = sendmsg(fd, &mh, 0); } while (n < 0 && errno == EINTR);
    return (long)n;
}

int pg_udp_addr_text(const pg_udp_addr *addr, char *host, size_t host_len,
                     uint16_t *port) {
    if (host && host_len) host[0] = 0;
    if (port) *port = 0;
    if (!addr || addr->len == 0) return -1;
    const struct sockaddr *sa = (const struct sockaddr *)addr->sa;
    if (host && host_len) {
        if (getnameinfo(sa, (socklen_t)addr->len, host, (socklen_t)host_len,
                        NULL, 0, NI_NUMERICHOST) != 0) {
            host[0] = 0;
        }
    }
    if (port) {
        if (sa->sa_family == AF_INET) {
            *port = ntohs(((const struct sockaddr_in *)sa)->sin_port);
        } else if (sa->sa_family == AF_INET6) {
            *port = ntohs(((const struct sockaddr_in6 *)sa)->sin6_port);
        }
    }
    return 0;
}

int pg_udp_local_addr(int fd, char *host, size_t host_len, uint16_t *port) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) return -1;
    pg_udp_addr a;
    store_addr(&a, (struct sockaddr *)&ss, len);
    return pg_udp_addr_text(&a, host, host_len, port);
}
