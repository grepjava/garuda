/* The shared rate-limit table. See garuda_ratelimit.h. */
#define _GNU_SOURCE

#include "garuda_ratelimit.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/random.h>
#endif

/* How many neighbouring entries a client may land in. Enough that a table a
 * few percent full almost never turns a client away for want of a slot, few
 * enough that a lookup stays in one or two cache lines. */
#define PROBES 8

struct pg_rl_entry {
    _Atomic uint64_t key;   /* 0 = never used */
    _Atomic uint64_t tat;   /* GCRA theoretical arrival time, microseconds */
};

static struct pg_rl_entry *g_table = NULL;
static uint64_t g_mask = 0;
static uint64_t g_emission = 0;
static uint64_t g_tolerance = 0;
/* Random per server, chosen before the fork so every worker hashes alike. An
 * attacker who could predict where addresses land could crowd a victim's
 * neighbourhood and have it fail open. */
static uint64_t g_seed = 0;

static uint64_t mix(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x;
}

static uint64_t hash_bytes(const uint8_t *p, size_t n) {
    uint64_t h = g_seed ^ (0xcbf29ce484222325ULL + n);
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return mix(h);
}

int pg_ratelimit_init(uint64_t emission_us, uint64_t tolerance_us, int log2_entries) {
    if (g_table) return 0;
    if (emission_us == 0) return -1;
    if (log2_entries < 8) log2_entries = 8;
    if (log2_entries > 24) log2_entries = 24;
    size_t count = (size_t)1 << log2_entries;
    void *p = mmap(NULL, count * sizeof(struct pg_rl_entry), PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    memset(p, 0, count * sizeof(struct pg_rl_entry));

    uint64_t seed = 0;
#ifdef __linux__
    if (getrandom(&seed, sizeof seed, 0) != (ssize_t)sizeof seed) seed = 0;
#else
    arc4random_buf(&seed, sizeof seed);
#endif
    if (seed == 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        seed = mix((uint64_t)ts.tv_nsec ^ ((uint64_t)ts.tv_sec << 32) ^ (uint64_t)getpid());
    }

    g_seed = seed;
    g_mask = count - 1;
    g_emission = emission_us;
    g_tolerance = tolerance_us;
    g_table = (struct pg_rl_entry *)p;
    return 0;
}

int pg_ratelimit_enabled(void) { return g_table != NULL; }

/* The client an address belongs to, or -1 for something that is not an IP
 * address. Brackets and a zone suffix are tolerated, since both turn up in
 * forwarded headers. */
static int key_of(const uint8_t *addr, size_t len, uint64_t *out) {
    char text[INET6_ADDRSTRLEN + 1];
    size_t start = 0, end = len;
    if (len > 0 && addr[0] == '[') start = 1;
    for (size_t i = start; i < len; i++) {
        if (addr[i] == ']' || addr[i] == '%') { end = i; break; }
    }
    if (end <= start || end - start >= sizeof text) return -1;
    memcpy(text, addr + start, end - start);
    text[end - start] = 0;

    uint8_t key[9];
    unsigned char buf[16];
    if (inet_pton(AF_INET, text, buf) == 1) {
        key[0] = 4;
        memcpy(key + 1, buf, 4);
        *out = hash_bytes(key, 5);
    } else if (inet_pton(AF_INET6, text, buf) == 1) {
        static const unsigned char mapped[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
        if (memcmp(buf, mapped, 12) == 0) {
            /* ::ffff:a.b.c.d is an IPv4 client on a dual-stack socket, and
             * the same client as a.b.c.d. */
            key[0] = 4;
            memcpy(key + 1, buf + 12, 4);
            *out = hash_bytes(key, 5);
        } else {
            key[0] = 6;
            memcpy(key + 1, buf, 8);
            *out = hash_bytes(key, 9);
        }
    } else {
        return -1;
    }
    if (*out == 0) *out = 1;
    return 0;
}

static struct pg_rl_entry *find(uint64_t key, uint64_t now) {
    uint64_t home = key & g_mask;
    /* An entry is never emptied again once used, so a client's entry is
     * always before the first empty one in its probe sequence. */
    for (int p = 0; p < PROBES; p++) {
        struct pg_rl_entry *e = &g_table[(home + (uint64_t)p) & g_mask];
        uint64_t k = atomic_load_explicit(&e->key, memory_order_relaxed);
        if (k == key) return e;
        if (k == 0) {
            uint64_t expected = 0;
            if (atomic_compare_exchange_strong(&e->key, &expected, key)) return e;
            if (expected == key) return e;
        }
    }
    /* Nothing free. Take over an entry whose client is back at a full burst,
     * which is exactly the state a new entry would start in. */
    for (int p = 0; p < PROBES; p++) {
        struct pg_rl_entry *e = &g_table[(home + (uint64_t)p) & g_mask];
        uint64_t k = atomic_load_explicit(&e->key, memory_order_relaxed);
        if (k == key) return e;
        if (atomic_load_explicit(&e->tat, memory_order_relaxed) <= now
            && atomic_compare_exchange_strong(&e->key, &k, key)) {
            return e;
        }
    }
    return NULL;
}

uint64_t pg_ratelimit_check(const uint8_t *addr, size_t len, uint64_t now_us) {
    if (!g_table || !addr) return 0;
    uint64_t key;
    if (key_of(addr, len, &key) != 0) return 0;
    struct pg_rl_entry *e = find(key, now_us);
    if (!e) return 0;

    for (;;) {
        uint64_t tat = atomic_load(&e->tat);
        uint64_t base = tat > now_us ? tat : now_us;
        if (base - now_us > g_tolerance) return base - now_us - g_tolerance;
        if (atomic_compare_exchange_weak(&e->tat, &tat, base + g_emission)) return 0;
    }
}
