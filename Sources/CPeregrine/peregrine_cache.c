/* The shared response cache. See peregrine_cache.h. */
#define _GNU_SOURCE

#include "peregrine_cache.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/random.h>
#endif

/* How many neighbouring slots an entry may live in, within its size class. */
#define PROBES 4
/* How long a slot may stay claimed before another writer may take it over:
 * far longer than any copy takes, short enough that a crash is forgotten. */
#define STALE_WRITE_MS 2000
/* Slot sizes, for key, headers and body together. Most cacheable responses
 * are a few kilobytes of JSON or HTML, and a table whose every slot could hold
 * the largest allowed body would hold a few dozen of them; so memory is split
 * evenly between these sizes and one that fits the largest entry, and each
 * entry goes in the smallest that holds it. */
static const size_t CLASS_SIZES[] = { 8 * 1024, 64 * 1024, 512 * 1024 };
#define MAX_CLASSES 4

struct pg_cache_table {
    _Atomic uint64_t generation;
};

struct pg_cache_slot {
    _Atomic uint64_t version;       /* even: stable; odd: being written */
    uint64_t hash;
    uint64_t generation;
    uint64_t stored_ms;
    uint64_t expires_ms;
    uint64_t claimed_ms;            /* when the current or last writer began */
    uint32_t key_len;
    uint32_t head_len;
    uint32_t body_len;
    uint16_t status;
    uint16_t unused;
    /* key, then head, then body */
};

struct pg_cache_class {
    uint8_t *slots;
    uint64_t mask;
    size_t slot_size;               /* header included */
    size_t capacity;                /* key + head + body */
};

static struct pg_cache_table *g_table = NULL;
static struct pg_cache_class g_classes[MAX_CLASSES];
static int g_class_count = 0;
static uint32_t g_max_head = 0;
static uint32_t g_max_body = 0;
static uint64_t g_seed = 0;

static uint64_t mix(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x;
}

static uint64_t hash_key(const uint8_t *p, size_t n) {
    uint64_t h = g_seed ^ (0xcbf29ce484222325ULL + n);
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return mix(h);
}

static struct pg_cache_slot *slot_at(const struct pg_cache_class *c, uint64_t index) {
    return (struct pg_cache_slot *)(c->slots + (index & c->mask) * c->slot_size);
}

static uint8_t *slot_data(struct pg_cache_slot *s) {
    return (uint8_t *)(s + 1);
}

static size_t round_up(size_t n) {
    return (n + 63) & ~(size_t)63;
}

long pg_cache_init(uint64_t total_bytes, uint32_t max_head, uint32_t max_body) {
    if (g_table) {
        long slots = 0;
        for (int i = 0; i < g_class_count; i++) slots += (long)(g_classes[i].mask + 1);
        return slots;
    }
    size_t largest = (size_t)PG_CACHE_MAX_KEY + max_head + max_body;

    size_t capacities[MAX_CLASSES];
    int count = 0;
    for (size_t i = 0; i < sizeof CLASS_SIZES / sizeof CLASS_SIZES[0]; i++) {
        if (CLASS_SIZES[i] < largest) capacities[count++] = CLASS_SIZES[i];
    }
    capacities[count++] = largest;

    /* Each class gets an even share, rounded down to a power of two of its
     * slots so a hash picks one with a mask. */
    uint64_t share = total_bytes / (uint64_t)count;
    uint64_t counts[MAX_CLASSES];
    size_t bytes = sizeof(struct pg_cache_table);
    for (int i = 0; i < count; i++) {
        size_t slot = round_up(sizeof(struct pg_cache_slot) + capacities[i]);
        uint64_t n = share / slot;
        if (n == 0) return -1;
        uint64_t pow2 = 1;
        while (pow2 * 2 <= n) pow2 *= 2;
        counts[i] = pow2;
        bytes += (size_t)pow2 * slot;
    }

    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    /* Anonymous memory is zero already, and touching every page of a large
     * table here would commit all of it up front. A zeroed slot has an even
     * version and generation zero, which no lookup can match: the table's
     * generation starts at one. */

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

    g_table = (struct pg_cache_table *)p;
    atomic_store(&g_table->generation, 1);
    uint8_t *at = (uint8_t *)p + sizeof(struct pg_cache_table);
    long slots = 0;
    for (int i = 0; i < count; i++) {
        g_classes[i].slots = at;
        g_classes[i].mask = counts[i] - 1;
        g_classes[i].slot_size = round_up(sizeof(struct pg_cache_slot) + capacities[i]);
        g_classes[i].capacity = capacities[i];
        at += (size_t)counts[i] * g_classes[i].slot_size;
        slots += (long)counts[i];
    }
    g_class_count = count;
    g_max_head = max_head;
    g_max_body = max_body;
    g_seed = seed;
    return slots;
}

int pg_cache_enabled(void) { return g_table != NULL; }
uint32_t pg_cache_max_head(void) { return g_max_head; }
uint32_t pg_cache_max_body(void) { return g_max_body; }

void pg_cache_flush(void) {
    if (g_table) atomic_fetch_add(&g_table->generation, 1);
}

int pg_cache_get(const uint8_t *key, size_t key_len, uint64_t now_ms,
                 uint8_t *out, size_t out_capacity,
                 uint32_t *head_len, uint32_t *body_len, uint16_t *status,
                 uint64_t *age_ms, uint64_t *ttl_ms) {
    if (!g_table || key_len == 0 || key_len > PG_CACHE_MAX_KEY) return 0;
    uint64_t h = hash_key(key, key_len);
    uint64_t generation = atomic_load(&g_table->generation);
    for (int k = 0; k < g_class_count; k++) {
        const struct pg_cache_class *cls = &g_classes[k];
        for (int p = 0; p < PROBES; p++) {
            struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
            uint64_t before = atomic_load(&s->version);
            if (before & 1) continue;
            /* Read into locals first: a writer may be changing these, and the
             * version check at the end is what says whether any of it was
             * real. */
            uint64_t hash = s->hash;
            uint64_t gen = s->generation;
            uint64_t stored = s->stored_ms;
            uint64_t expires = s->expires_ms;
            uint32_t klen = s->key_len;
            uint32_t hlen = s->head_len;
            uint32_t blen = s->body_len;
            uint16_t st = s->status;
            if (hash != h || gen != generation || expires <= now_ms) continue;
            if (klen != key_len || hlen > g_max_head || blen > g_max_body) continue;
            if ((size_t)klen + hlen + blen > cls->capacity) continue;
            if ((size_t)hlen + blen > out_capacity) continue;
            uint8_t *data = slot_data(s);
            if (memcmp(data, key, key_len) != 0) continue;
            memcpy(out, data + klen, (size_t)hlen + blen);
            if (atomic_load(&s->version) != before) return 0;
            *head_len = hlen;
            *body_len = blen;
            *status = st;
            *age_ms = now_ms > stored ? now_ms - stored : 0;
            *ttl_ms = expires - now_ms;
            return 1;
        }
    }
    return 0;
}

int pg_cache_put(const uint8_t *key, size_t key_len, uint64_t now_ms, uint64_t ttl_ms,
                 uint16_t status,
                 const uint8_t *head, size_t head_len,
                 const uint8_t *body, size_t body_len) {
    if (!g_table || key_len == 0 || key_len > PG_CACHE_MAX_KEY) return 0;
    if (head_len > g_max_head || body_len > g_max_body || ttl_ms == 0) return 0;
    size_t needed = key_len + head_len + body_len;
    const struct pg_cache_class *cls = NULL;
    for (int k = 0; k < g_class_count; k++) {
        if (g_classes[k].capacity >= needed) {
            cls = &g_classes[k];
            break;
        }
    }
    if (!cls) return 0;
    uint64_t h = hash_key(key, key_len);
    uint64_t generation = atomic_load(&g_table->generation);

    /* The best slot to overwrite: this key's own, else one that holds nothing
     * worth keeping, else the one closest to expiring. A slot whose writer
     * vanished counts as holding nothing. A copy of the same key left in
     * another size class, from before the response changed size, is found
     * after this one or expires. */
    struct pg_cache_slot *choice = NULL;
    uint64_t choice_version = 0;
    int choice_rank = 4;              /* lower is better */
    uint64_t choice_expires = UINT64_MAX;
    for (int p = 0; p < PROBES; p++) {
        struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
        uint64_t v = atomic_load(&s->version);
        int rank;
        if (v & 1) {
            uint64_t claimed = s->claimed_ms;
            if (claimed > now_ms || now_ms - claimed < STALE_WRITE_MS) continue;
            rank = 1;
        } else if (s->hash == h && s->key_len == key_len
                   && memcmp(slot_data(s), key, key_len) == 0) {
            rank = 0;
        } else if (s->generation != generation || s->expires_ms <= now_ms) {
            rank = 1;
        } else {
            rank = 2;
        }
        if (rank < choice_rank
            || (rank == 2 && choice_rank == 2 && s->expires_ms < choice_expires)) {
            choice = s;
            choice_version = v;
            choice_rank = rank;
            choice_expires = s->expires_ms;
        }
    }
    if (!choice) return 0;

    /* Claim: even to odd, or a stale odd to the next odd, so that two writers
     * taking over the same abandoned slot cannot both win. */
    uint64_t claimed = (choice_version & 1) ? choice_version + 2 : choice_version + 1;
    if (!atomic_compare_exchange_strong(&choice->version, &choice_version, claimed)) return 0;

    choice->claimed_ms = now_ms;
    choice->hash = h;
    choice->generation = generation;
    choice->stored_ms = now_ms;
    choice->expires_ms = now_ms + ttl_ms;
    choice->key_len = (uint32_t)key_len;
    choice->head_len = (uint32_t)head_len;
    choice->body_len = (uint32_t)body_len;
    choice->status = status;
    uint8_t *data = slot_data(choice);
    memcpy(data, key, key_len);
    if (head_len) memcpy(data + key_len, head, head_len);
    if (body_len) memcpy(data + key_len + head_len, body, body_len);

    atomic_store(&choice->version, claimed + 1);
    return 1;
}
