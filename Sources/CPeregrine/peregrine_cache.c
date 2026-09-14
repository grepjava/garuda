/* The shared response cache. See peregrine_cache.h. */
#define _GNU_SOURCE

#include "peregrine_cache.h"

#include <errno.h>
#include <signal.h>
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
/* Slot sizes, for key, headers and body together. Most cacheable responses
 * are a few kilobytes of JSON or HTML, and a table whose every slot could hold
 * the largest allowed body would hold a few dozen of them; so memory is split
 * evenly between these sizes and one that fits the largest entry, and each
 * entry goes in the smallest that holds it. */
static const size_t CLASS_SIZES[] = { 8 * 1024, 64 * 1024, 512 * 1024 };
#define MAX_CLASSES 4

/* A slot's version word. Stable, it is a count of finished writes shifted
 * clear of the low bits, so it is even and the rest of it is zero. Claimed,
 * it keeps that count, carries the writer's process ID above the low bit, and
 * is odd. Linux process IDs stay below 2^22 and macOS ones below 10^5. */
#define OWNER_SHIFT 1
#define OWNER_BITS 22
#define COUNT_SHIFT (OWNER_SHIFT + OWNER_BITS)
#define OWNER_MASK ((UINT64_C(1) << OWNER_BITS) - 1)

/* Marks per slot, at the least: enough that two targets rarely share one. */
#define MARKS_PER_SLOT 4
#define MIN_MARKS 4096

#ifdef PG_CACHE_TESTING
/* Called by a writer that has claimed its slot and written the entry's
 * description, before it copies the headers and body: where a test pauses a
 * writer, or ends its process. */
void (*pg_cache_test_after_claim)(void) = NULL;
#define AFTER_CLAIM() do { if (pg_cache_test_after_claim) pg_cache_test_after_claim(); } while (0)
#else
#define AFTER_CLAIM() ((void)0)
#endif

struct pg_cache_table {
    _Atomic uint64_t generation;
    _Atomic uint64_t sequence;
};

struct pg_cache_slot {
    _Atomic uint64_t version;       /* see OWNER_SHIFT */
    uint64_t hash;
    uint64_t mark;                  /* the target's hash, for its invalidation mark */
    uint64_t generation;
    uint64_t sequence;              /* the number of the request it answers */
    uint64_t stored_ms;
    uint64_t age_ms;                /* how old it was when it was stored */
    uint64_t expires_ms;
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
static _Atomic uint64_t *g_marks = NULL;
static uint64_t g_mark_mask = 0;
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

static uint64_t claim_word(uint64_t word, uint64_t owner) {
    return ((word >> COUNT_SHIFT) << COUNT_SHIFT) | (owner << OWNER_SHIFT) | 1;
}

static uint64_t publish_word(uint64_t claimed) {
    return ((claimed >> COUNT_SHIFT) + 1) << COUNT_SHIFT;
}

/* This process, as a claim names it, or 0 when it cannot be named. */
static uint64_t self_owner(void) {
    pid_t pid = getpid();
    if (pid <= 0 || (uint64_t)pid > OWNER_MASK) return 0;
    return (uint64_t)pid;
}

/* Whether the writer a claim names is gone. Only its absence counts: a
 * process that exists, or that this one may not signal, may still be
 * writing. Every thread of a free-threaded server shares one ID, and one of
 * them cannot die without the rest. */
static int owner_gone(uint64_t owner, uint64_t self) {
    if (owner == self) return 0;
    if (owner == 0) return 1;
    return kill((pid_t)owner, 0) != 0 && errno == ESRCH;
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
    uint64_t total_slots = 0;
    size_t bytes = sizeof(struct pg_cache_table);
    for (int i = 0; i < count; i++) {
        size_t slot = round_up(sizeof(struct pg_cache_slot) + capacities[i]);
        uint64_t n = share / slot;
        if (n == 0) return -1;
        uint64_t pow2 = 1;
        while (pow2 * 2 <= n) pow2 *= 2;
        counts[i] = pow2;
        total_slots += pow2;
        bytes += (size_t)pow2 * slot;
    }
    uint64_t marks = MIN_MARKS;
    while (marks < total_slots * MARKS_PER_SLOT) marks *= 2;
    bytes += (size_t)marks * sizeof(_Atomic uint64_t);

    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    /* Anonymous memory is zero already, and touching every page of a large
     * table here would commit all of it up front. A zeroed slot is stable and
     * has generation zero, which no lookup can match: the table's generation
     * starts at one. A zeroed mark is below every request's number. */

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
    atomic_store(&g_table->sequence, 1);
    uint8_t *at = (uint8_t *)p + sizeof(struct pg_cache_table);
    g_marks = (_Atomic uint64_t *)at;
    g_mark_mask = marks - 1;
    at += (size_t)marks * sizeof(_Atomic uint64_t);
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

uint64_t pg_cache_begin(void) {
    if (!g_table) return 0;
    return atomic_fetch_add(&g_table->sequence, 1) + 1;
}

uint64_t pg_cache_target_hash(const uint8_t *target, size_t target_len) {
    if (!g_table) return 0;
    return hash_key(target, target_len);
}

void pg_cache_invalidate(uint64_t target_hash) {
    if (!g_table) return;
    uint64_t now = pg_cache_begin();
    _Atomic uint64_t *mark = &g_marks[target_hash & g_mark_mask];
    uint64_t current = atomic_load(mark);
    while (current < now && !atomic_compare_exchange_weak(mark, &current, now)) {}
}

/* Whether a slot holds `key` under `generation`, read without owning it: the
 * caller confirms the version word did not move. */
static int holds(const struct pg_cache_class *cls, struct pg_cache_slot *s, uint64_t h,
                 const uint8_t *key, size_t key_len, uint64_t generation) {
    if (s->hash != h || s->generation != generation || s->key_len != key_len) return 0;
    if (key_len > cls->capacity) return 0;
    return memcmp(slot_data(s), key, key_len) == 0;
}

/* Whether some class holds a copy of `key` answering a request numbered after
 * `sequence`, expired or not. */
static int holds_newer(uint64_t h, const uint8_t *key, size_t key_len,
                       uint64_t generation, uint64_t sequence) {
    for (int k = 0; k < g_class_count; k++) {
        const struct pg_cache_class *cls = &g_classes[k];
        for (int p = 0; p < PROBES; p++) {
            struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
            uint64_t v = atomic_load(&s->version);
            if (v & 1) continue;
            if (!holds(cls, s, h, key, key_len, generation)) continue;
            uint64_t seq = s->sequence;
            if (atomic_load(&s->version) != v) continue;
            if (seq > sequence) return 1;
        }
    }
    return 0;
}

/* Retires every copy of `key` answering a request numbered before `sequence`,
 * other than `keep`. A copy still being written is passed over: if it is the
 * older, a lookup already prefers this one to it, and whoever retires this
 * one retires it too. */
static void retire_older(uint64_t h, const uint8_t *key, size_t key_len,
                         uint64_t generation, uint64_t sequence,
                         const struct pg_cache_slot *keep, uint64_t self) {
    for (int k = 0; k < g_class_count; k++) {
        const struct pg_cache_class *cls = &g_classes[k];
        for (int p = 0; p < PROBES; p++) {
            struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
            if (s == keep) continue;
            uint64_t v = atomic_load(&s->version);
            if (v & 1) continue;
            if (!holds(cls, s, h, key, key_len, generation) || s->sequence >= sequence) continue;
            /* A claim from the word read above proves nothing was written in
             * between, so what was read is what the slot holds. */
            uint64_t claimed = claim_word(v, self);
            uint64_t expected = v;
            if (!atomic_compare_exchange_strong(&s->version, &expected, claimed)) continue;
            s->generation = 0;
            s->expires_ms = 0;
            atomic_store(&s->version, publish_word(claimed));
        }
    }
}

int pg_cache_get(const uint8_t *key, size_t key_len, uint64_t now_ms,
                 uint8_t *out, size_t out_capacity,
                 uint32_t *head_len, uint32_t *body_len, uint16_t *status,
                 uint64_t *age_ms, uint64_t *ttl_ms) {
    if (!g_table || key_len == 0 || key_len > PG_CACHE_MAX_KEY) return 0;
    uint64_t h = hash_key(key, key_len);
    uint64_t generation = atomic_load(&g_table->generation);

    /* Every class is searched, and only the copy answering the latest request
     * counts. */
    struct pg_cache_slot *best = NULL;
    const struct pg_cache_class *best_class = NULL;
    uint64_t best_version = 0;
    uint64_t best_sequence = 0;
    for (int k = 0; k < g_class_count; k++) {
        const struct pg_cache_class *cls = &g_classes[k];
        for (int p = 0; p < PROBES; p++) {
            struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
            uint64_t v = atomic_load(&s->version);
            if (v & 1) continue;
            if (!holds(cls, s, h, key, key_len, generation)) continue;
            uint64_t seq = s->sequence;
            if (atomic_load(&s->version) != v) continue;
            if (seq > best_sequence) {
                best = s;
                best_class = cls;
                best_version = v;
                best_sequence = seq;
            }
        }
    }
    if (!best) return 0;

    /* Read into locals first: a writer may be changing these, and the version
     * check after the copy is what says whether any of it was real. */
    uint64_t mark = best->mark;
    uint64_t stored = best->stored_ms;
    uint64_t age = best->age_ms;
    uint64_t expires = best->expires_ms;
    uint32_t hlen = best->head_len;
    uint32_t blen = best->body_len;
    uint16_t st = best->status;
    if (expires <= now_ms) return 0;
    if (hlen > g_max_head || blen > g_max_body) return 0;
    if (key_len + hlen + blen > best_class->capacity) return 0;
    if ((size_t)hlen + blen > out_capacity) return 0;
    memcpy(out, slot_data(best) + key_len, (size_t)hlen + blen);
    if (atomic_load(&best->version) != best_version) return 0;
    if (best_sequence <= atomic_load(&g_marks[mark & g_mark_mask])) return 0;
    *head_len = hlen;
    *body_len = blen;
    *status = st;
    *age_ms = age + (now_ms > stored ? now_ms - stored : 0);
    *ttl_ms = expires - now_ms;
    return 1;
}

int pg_cache_put(const uint8_t *key, size_t key_len, uint64_t target_hash,
                 uint64_t sequence, uint64_t now_ms, uint64_t age_ms, uint64_t ttl_ms,
                 uint16_t status,
                 const uint8_t *head, size_t head_len,
                 const uint8_t *body, size_t body_len) {
    if (!g_table || key_len == 0 || key_len > PG_CACHE_MAX_KEY || sequence == 0) return 0;
    if (head_len > g_max_head || body_len > g_max_body || ttl_ms == 0) return 0;
    uint64_t self = self_owner();
    if (self == 0) return 0;
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

    /* Dispatched before its target last changed, it describes what the target
     * was. And older than a copy already kept, it has nothing to add. */
    if (sequence <= atomic_load(&g_marks[target_hash & g_mark_mask])) return 0;
    if (holds_newer(h, key, key_len, generation, sequence)) return 0;

    /* The best slot to overwrite: this key's own, else one that holds nothing
     * worth keeping, else the one closest to expiring. A slot whose writer is
     * gone counts as holding nothing; one whose writer is alive is not
     * touched, however long it has been. */
    struct pg_cache_slot *choice = NULL;
    uint64_t choice_version = 0;
    int choice_rank = 4;              /* lower is better */
    uint64_t choice_expires = UINT64_MAX;
    for (int p = 0; p < PROBES; p++) {
        struct pg_cache_slot *s = slot_at(cls, h + (uint64_t)p);
        uint64_t v = atomic_load(&s->version);
        int rank;
        if (v & 1) {
            if (!owner_gone((v >> OWNER_SHIFT) & OWNER_MASK, self)) continue;
            rank = 1;
        } else if (holds(cls, s, h, key, key_len, generation)) {
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

    /* Claim: stable to odd, or a gone writer's odd to this process's, so that
     * two writers taking over the same slot cannot both win. */
    uint64_t claimed = claim_word(choice_version, self);
    uint64_t expected = choice_version;
    if (!atomic_compare_exchange_strong(&choice->version, &expected, claimed)) return 0;

    /* The entry being replaced, when it is another response's: an older copy
     * of that response elsewhere would otherwise be what its lookups found
     * next. Read now, before it is overwritten, from a slot this process owns;
     * a gone writer's half-written entry describes nothing. */
    uint8_t evicted_key[PG_CACHE_MAX_KEY];
    size_t evicted_len = 0;
    uint64_t evicted_hash = 0;
    uint64_t evicted_sequence = 0;
    if (!(choice_version & 1) && choice->generation == generation
        && !holds(cls, choice, h, key, key_len, generation)
        && choice->key_len > 0 && choice->key_len <= PG_CACHE_MAX_KEY
        && choice->key_len <= cls->capacity) {
        evicted_len = choice->key_len;
        evicted_hash = choice->hash;
        evicted_sequence = choice->sequence;
        memcpy(evicted_key, slot_data(choice), evicted_len);
    }

    choice->hash = h;
    choice->mark = target_hash;
    choice->generation = generation;
    choice->sequence = sequence;
    choice->stored_ms = now_ms;
    choice->age_ms = age_ms;
    choice->expires_ms = now_ms + ttl_ms;
    choice->key_len = (uint32_t)key_len;
    choice->head_len = (uint32_t)head_len;
    choice->body_len = (uint32_t)body_len;
    choice->status = status;
    uint8_t *data = slot_data(choice);
    memcpy(data, key, key_len);
    AFTER_CLAIM();
    if (head_len) memcpy(data + key_len, head, head_len);
    if (body_len) memcpy(data + key_len + head_len, body, body_len);

    expected = claimed;
    if (!atomic_compare_exchange_strong(&choice->version, &expected, publish_word(claimed))) {
        return 0;
    }

    retire_older(h, key, key_len, generation, sequence, choice, self);
    if (evicted_len > 0) {
        retire_older(evicted_hash, evicted_key, evicted_len, generation, evicted_sequence,
                     choice, self);
    }
    return 1;
}
