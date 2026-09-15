/* The shared response cache, tested against garuda_cache.c directly:
 *
 *   bash scripts/cache-unit-test.sh
 *
 * These are the cases an end-to-end test cannot arrange from outside a
 * server -- a writer paused part way through a copy, one that died holding a
 * slot, two copies of one response in different size classes, a request
 * dispatched before its target changed and stored after.
 *
 * The table is mapped once per process and several tests need one of a
 * particular shape, so every test runs in a process of its own. */
#define _GNU_SOURCE

#include "garuda_cache.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern void (*pg_cache_test_after_claim)(void);

static int failures = 0;

#define CHECK(cond) do {                                                   \
    if (!(cond)) {                                                         \
        fprintf(stderr, "    %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
        failures++;                                                        \
    }                                                                      \
} while (0)

#define KIB 1024

struct hit {
    int found;
    uint16_t status;
    uint32_t body_len;
    char body[64];
    uint64_t age_ms;
    uint64_t ttl_ms;
};

static uint8_t out[256 * KIB];

static struct hit get(const char *key, uint64_t now) {
    struct hit r;
    memset(&r, 0, sizeof r);
    uint32_t head_len = 0;
    uint32_t body_len = 0;
    r.found = pg_cache_get((const uint8_t *)key, strlen(key), now, out, sizeof out,
                           &head_len, &body_len, &r.status, &r.age_ms, &r.ttl_ms);
    if (r.found) {
        size_t n = body_len < sizeof r.body - 1 ? body_len : sizeof r.body - 1;
        memcpy(r.body, out + head_len, n);
        r.body_len = body_len;
    }
    return r;
}

/* Stores `body` under `key`, whose target is the key itself. */
static int put_sized(const char *key, uint64_t sequence, uint64_t now, uint64_t ttl,
                     uint16_t status, const char *body, size_t body_len) {
    uint64_t target = pg_cache_target_hash((const uint8_t *)key, strlen(key));
    return pg_cache_put((const uint8_t *)key, strlen(key), target, sequence, now, 0, ttl,
                        status, (const uint8_t *)"", 0, (const uint8_t *)body, body_len);
}

static int put(const char *key, uint64_t sequence, uint64_t now, uint64_t ttl,
               uint16_t status, const char *body) {
    return put_sized(key, sequence, now, ttl, status, body, strlen(body));
}

/* Roughly the bytes one slot takes for these limits, header and rounding
 * included, so a test can ask for a table of a few slots: a little over, so
 * that N of these is N slots and not N - 1. */
static uint64_t slot_bytes(uint32_t max_head, uint32_t max_body) {
    return (uint64_t)PG_CACHE_MAX_KEY + max_head + max_body + 200;
}

/* --- a writer that stops part way keeps its slot ------------------------- */

static int hook_calls = 0;

static void replace_while_paused(void) {
    if (hook_calls++ > 0) return;
    /* Seconds later, by the clock the cache is given: long past the two
     * seconds after which an abandoned slot used to be taken over. */
    uint64_t newer = pg_cache_begin();
    CHECK(put("/paused", newer, 5000, 60000, 201, "NEW") == 1);
}

static void test_paused_writer(void) {
    CHECK(pg_cache_init(1024 * KIB, 1 * KIB, 4 * KIB) > 0);
    uint64_t older = pg_cache_begin();
    pg_cache_test_after_claim = replace_while_paused;
    put("/paused", older, 1000, 60000, 200, "OLD");
    pg_cache_test_after_claim = NULL;
    /* Once for this writer, once for the one it started from the hook. */
    CHECK(hook_calls == 2);

    struct hit r = get("/paused", 5001);
    CHECK(r.found);
    CHECK(r.status == 201);
    CHECK(strcmp(r.body, "NEW") == 0);
}

/* --- a writer that died is replaced, one that lives is not ---------------- */

static void die_holding_slot(void) {
    _exit(0);
}

static void write_while_claimed(void) {
    if (hook_calls++ > 0) return;
    /* Every slot is live or claimed by this process: the claim is left alone
     * and the entry nearest to expiring goes instead. */
    CHECK(put("/g", pg_cache_begin(), 0, 45000, 200, "g") == 1);
}

static void test_dead_writer(void) {
    /* One size class of exactly PROBES slots, so every entry competes for
     * every slot. */
    CHECK(pg_cache_init(4 * slot_bytes(1 * KIB, 4 * KIB), 1 * KIB, 4 * KIB) == 4);
    CHECK(put("/a", pg_cache_begin(), 0, 60000, 200, "a") == 1);
    CHECK(put("/b", pg_cache_begin(), 0, 50000, 200, "b") == 1);
    CHECK(put("/c", pg_cache_begin(), 0, 40000, 200, "c") == 1);

    pid_t child = fork();
    if (child == 0) {
        pg_cache_test_after_claim = die_holding_slot;
        put("/d", pg_cache_begin(), 0, 60000, 200, "d");
        _exit(1);
    }
    int wstatus = 0;
    waitpid(child, &wstatus, 0);
    CHECK(WIFEXITED(wstatus) && WEXITSTATUS(wstatus) == 0);

    /* The dead writer's slot is the free one. */
    CHECK(put("/e", pg_cache_begin(), 0, 60000, 200, "e") == 1);
    CHECK(get("/a", 1).found);
    CHECK(get("/b", 1).found);
    CHECK(get("/c", 1).found);
    CHECK(strcmp(get("/e", 1).body, "e") == 0);
    CHECK(!get("/d", 1).found);

    /* /f replaces /c, the nearest to expiring; while it holds that slot, /g
     * has to replace /b rather than take the claimed slot over. */
    pg_cache_test_after_claim = write_while_claimed;
    CHECK(put("/f", pg_cache_begin(), 0, 60000, 200, "f") == 1);
    pg_cache_test_after_claim = NULL;
    /* Once for this writer, once for the one it started from the hook. */
    CHECK(hook_calls == 2);
    CHECK(strcmp(get("/f", 1).body, "f") == 0);
    CHECK(strcmp(get("/g", 1).body, "g") == 0);
    CHECK(get("/a", 1).found);
    CHECK(get("/e", 1).found);
    CHECK(!get("/b", 1).found);
    CHECK(!get("/c", 1).found);
}

/* --- copies of one response in different size classes -------------------- */

static char small_body[100];
static char large_body[20 * KIB];

static void store_large_older(void) {
    if (hook_calls++ > 0) return;
    /* Number 1 is below every request pg_cache_begin has numbered. */
    CHECK(put_sized("/race", 1, 0, 60000, 200, large_body, sizeof large_body) == 1);
}

static void store_small_newer(void) {
    if (hook_calls++ > 0) return;
    CHECK(put_sized("/race2", pg_cache_begin(), 0, 1000, 200, small_body,
                    sizeof small_body) == 1);
}

static void test_size_classes(void) {
    CHECK(pg_cache_init(8 * KIB * KIB, 1 * KIB, 128 * KIB) > 0);
    memset(small_body, 's', sizeof small_body);
    memset(large_body, 'L', sizeof large_body);

    /* An older small response does not hide a newer large one. */
    CHECK(put_sized("/grow", pg_cache_begin(), 0, 60000, 200, small_body, sizeof small_body) == 1);
    CHECK(put_sized("/grow", pg_cache_begin(), 0, 60000, 200, large_body, sizeof large_body) == 1);
    CHECK(get("/grow", 1).body_len == sizeof large_body);

    /* An older large response does not come back when a newer small one
     * expires. */
    CHECK(put_sized("/shrink", pg_cache_begin(), 0, 60000, 200, large_body, sizeof large_body) == 1);
    CHECK(put_sized("/shrink", pg_cache_begin(), 0, 1000, 200, small_body, sizeof small_body) == 1);
    CHECK(get("/shrink", 10).body_len == sizeof small_body);
    CHECK(!get("/shrink", 2000).found);

    /* A response to an earlier request, stored after a later one's, is not
     * kept. */
    uint64_t earlier = pg_cache_begin();
    uint64_t later = pg_cache_begin();
    CHECK(put_sized("/late", later, 0, 60000, 200, small_body, sizeof small_body) == 1);
    CHECK(put_sized("/late", earlier, 0, 60000, 200, large_body, sizeof large_body) == 0);
    CHECK(get("/late", 1).body_len == sizeof small_body);

    /* An older copy written while a newer one is being written is retired by
     * the newer when it finishes. */
    hook_calls = 0;
    pg_cache_test_after_claim = store_large_older;
    CHECK(put_sized("/race", pg_cache_begin(), 0, 1000, 200, small_body,
                    sizeof small_body) == 1);
    pg_cache_test_after_claim = NULL;
    CHECK(get("/race", 10).body_len == sizeof small_body);
    CHECK(!get("/race", 2000).found);

    /* A newer copy written while an older one is being written stays the one
     * served, and when it expires the older does not take its place. */
    hook_calls = 0;
    pg_cache_test_after_claim = store_small_newer;
    CHECK(put_sized("/race2", pg_cache_begin(), 0, 60000, 200, large_body,
                    sizeof large_body) == 1);
    pg_cache_test_after_claim = NULL;
    CHECK(get("/race2", 10).body_len == sizeof small_body);
    CHECK(!get("/race2", 2000).found);
}

/* --- a change to a target ------------------------------------------------- */

static void test_invalidation(void) {
    CHECK(pg_cache_init(1024 * KIB, 1 * KIB, 4 * KIB) > 0);
    uint64_t before = pg_cache_begin();
    CHECK(put("/item", before, 0, 60000, 200, "before") == 1);
    char others[8][32];
    for (int i = 0; i < 8; i++) {
        snprintf(others[i], sizeof others[i], "/other%d", i);
        CHECK(put(others[i], pg_cache_begin(), 0, 60000, 200, "other") == 1);
    }
    CHECK(get("/item", 1).found);

    pg_cache_invalidate(pg_cache_target_hash((const uint8_t *)"/item", 5));
    CHECK(!get("/item", 2).found);
    /* The response to a request dispatched before the change, arriving
     * after it, is not stored. */
    CHECK(put("/item", before, 3, 60000, 200, "before") == 0);
    CHECK(!get("/item", 4).found);
    /* One dispatched after it is. */
    CHECK(put("/item", pg_cache_begin(), 5, 60000, 200, "after") == 1);
    CHECK(strcmp(get("/item", 6).body, "after") == 0);

    /* Other targets keep their copies. Two targets may share a mark, which
     * costs a miss, so all but one of eight is the most that can be asked. */
    int kept = 0;
    for (int i = 0; i < 8; i++) kept += get(others[i], 7).found;
    CHECK(kept >= 7);
}

/* --- age, expiry and a flush ---------------------------------------------- */

static void test_age_and_flush(void) {
    CHECK(pg_cache_init(1024 * KIB, 1 * KIB, 4 * KIB) > 0);
    uint64_t target = pg_cache_target_hash((const uint8_t *)"/aged", 5);
    CHECK(pg_cache_put((const uint8_t *)"/aged", 5, target, pg_cache_begin(), 1000, 30000,
                       30000, 200, (const uint8_t *)"", 0, (const uint8_t *)"x", 1) == 1);
    struct hit r = get("/aged", 2000);
    CHECK(r.found);
    CHECK(r.age_ms == 31000);
    CHECK(r.ttl_ms == 29000);
    CHECK(!get("/aged", 31000).found);

    CHECK(put("/flushed", pg_cache_begin(), 0, 60000, 200, "x") == 1);
    CHECK(get("/flushed", 1).found);
    pg_cache_flush();
    CHECK(!get("/flushed", 2).found);
}

/* --- a replaced copy takes its older copies with it ----------------------- */

static void store_newer_small_while_large_writes(void) {
    if (hook_calls++ > 0) return;
    CHECK(put_sized("/evicted", pg_cache_begin(), 0, 30000, 200, small_body, 100) == 1);
}

/* Stores longer-lived small entries until the small copy of `key`, the nearest
 * to expiring, has been replaced by one of them. Whether it was. */
static int replace_small_copy(const char *key) {
    static int next = 0;
    for (int i = 0; i < 500; i++) {
        char filler[32];
        snprintf(filler, sizeof filler, "/fill%d", next++);
        put_sized(filler, pg_cache_begin(), 0, 60000, 200, small_body, 100);
        if (get(key, 1).body_len != 100) return 1;
    }
    return 0;
}

static void store_newer_and_replace_it(void) {
    if (hook_calls++ > 0) return;
    CHECK(put_sized("/gone", pg_cache_begin(), 0, 30000, 200, small_body, 100) == 1);
    CHECK(get("/gone", 1).body_len == 100);
    CHECK(replace_small_copy("/gone"));
}

static void test_eviction(void) {
    /* A class of eight slots for small entries, and one of two for bodies up
     * to 16 KiB. */
    CHECK(pg_cache_init(2 * 8 * (8 * KIB + 200), 1 * KIB, 16 * KIB) > 0);

    /* A newer small copy stored while an older large one is being written:
     * both are kept, and the newer is the one served. When the newer is
     * replaced, the older does not come back in its place. */
    uint64_t older = pg_cache_begin();
    hook_calls = 0;
    pg_cache_test_after_claim = store_newer_small_while_large_writes;
    CHECK(put_sized("/evicted", older, 0, 60000, 200, large_body, 10 * KIB) == 1);
    pg_cache_test_after_claim = NULL;
    CHECK(get("/evicted", 1).body_len == 100);
    CHECK(replace_small_copy("/evicted"));
    CHECK(!get("/evicted", 1).found);

    /* The same, but the newer copy is stored and replaced while the older is
     * still being written: the older publishes after the newer is gone, and
     * is still not served. */
    hook_calls = 0;
    pg_cache_test_after_claim = store_newer_and_replace_it;
    CHECK(put_sized("/gone", pg_cache_begin(), 0, 60000, 200, large_body, 10 * KIB) == 0);
    pg_cache_test_after_claim = NULL;
    CHECK(hook_calls >= 2);
    CHECK(!get("/gone", 1).found);

    /* And a response to an earlier request that only arrives after a newer
     * copy has come and gone is not stored at all. */
    uint64_t earlier = pg_cache_begin();
    CHECK(put_sized("/late", pg_cache_begin(), 0, 30000, 200, small_body, 100) == 1);
    CHECK(replace_small_copy("/late"));
    CHECK(put_sized("/late", earlier, 0, 60000, 200, large_body, 10 * KIB) == 0);
    CHECK(!get("/late", 1).found);

    /* A response to a later request is stored and served as usual. */
    CHECK(put_sized("/late", pg_cache_begin(), 0, 60000, 200, large_body, 10 * KIB) == 1);
    CHECK(get("/late", 1).body_len == 10 * KIB);
}

/* --- what is out of date takes no slot from what is not -------------------- */

static void test_space(void) {
    /* A class of four small slots, every one in every entry's reach, and one
     * slot for bodies up to 16 KiB. */
    CHECK(pg_cache_init(2 * 4 * (8 * KIB + 200), 1 * KIB, 16 * KIB) > 0);

    /* The small copy of /k outlives everything else, so nothing would replace
     * it for being near its end. */
    CHECK(put_sized("/k", pg_cache_begin(), 0, 120000, 200, small_body, 100) == 1);
    CHECK(put_sized("/s1", pg_cache_begin(), 0, 60000, 200, small_body, 100) == 1);
    CHECK(put_sized("/s2", pg_cache_begin(), 0, 60000, 200, small_body, 100) == 1);
    CHECK(put_sized("/s3", pg_cache_begin(), 0, 60000, 200, small_body, 100) == 1);

    /* A newer, large /k retires the small one, and the next small entry takes
     * that slot rather than a live entry's. */
    CHECK(put_sized("/k", pg_cache_begin(), 0, 60000, 200, large_body, 10 * KIB) == 1);
    CHECK(put_sized("/s4", pg_cache_begin(), 0, 90000, 200, small_body, 100) == 1);
    CHECK(get("/k", 1).body_len == 10 * KIB);
    CHECK(get("/s1", 1).found);
    CHECK(get("/s2", 1).found);
    CHECK(get("/s3", 1).found);
    CHECK(get("/s4", 1).found);

    /* A response to a request dispatched before its target changed is turned
     * away before it can push anything out. */
    uint64_t before = pg_cache_begin();
    pg_cache_invalidate(pg_cache_target_hash((const uint8_t *)"/x", 2));
    CHECK(put_sized("/x", before, 0, 60000, 200, small_body, 100) == 0);
    CHECK(get("/s1", 1).found);
    CHECK(get("/s2", 1).found);
    CHECK(get("/s3", 1).found);
    CHECK(get("/s4", 1).found);
}

static int run(const char *name, void (*test)(void)) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        test();
        _exit(failures == 0 ? 0 : 1);
    }
    int wstatus = 0;
    waitpid(pid, &wstatus, 0);
    int passed = WIFEXITED(wstatus) && WEXITSTATUS(wstatus) == 0;
    printf("  %s %s\n", passed ? "ok  " : "FAIL", name);
    return passed;
}

int main(void) {
    int passed = 0;
    int total = 0;
    total++; passed += run("a paused writer keeps its slot, and a replacement is served whole",
                           test_paused_writer);
    total++; passed += run("a dead writer's slot is reused, a live one's is not taken",
                           test_dead_writer);
    total++; passed += run("the newest copy wins across size classes, expired or not",
                           test_size_classes);
    total++; passed += run("a replaced copy takes the older copies of its response with it",
                           test_eviction);
    total++; passed += run("out-of-date copies take no slot from live ones",
                           test_space);
    total++; passed += run("a change retires a target's copies and refuses older responses",
                           test_invalidation);
    total++; passed += run("a stored response keeps its age, and a flush retires it",
                           test_age_and_flush);
    printf("\ncache unit: %d passed, %d failed\n", passed, total - passed);
    return passed == total ? 0 : 1;
}
