/* ---------------------------------------------------------------------------
 * Counters shared by every worker.
 *
 * A scrape arrives on one worker and has to answer for all of them. Workers
 * are separate processes (SO_REUSEPORT, nothing shared), so the counters live
 * in a page mapped MAP_SHARED before the fork: children inherit the mapping.
 *
 * Each worker writes only its own slot, so a counter needs no read-modify-
 * write against anyone else -- the atomics here are relaxed loads and stores,
 * which compile to a plain load and store on every architecture this runs on.
 * They exist to make the read a defined one, not to order anything: a scrape
 * that sees a counter one increment behind is a scrape, not a bug.
 *
 * Slots are padded to whole cache lines so that two workers incrementing their
 * own counters never share a line.
 * ------------------------------------------------------------------------- */
#ifndef GARUDA_METRICS_H
#define GARUDA_METRICS_H

#include <stdint.h>

/* Duration histogram, in microseconds. Prometheus convention: seconds, with
 * buckets spanning what a request can plausibly take -- from a hello-world
 * answered inside half a millisecond to something waiting on a database. */
#define PG_METRIC_BUCKETS 14

enum {
    PG_M_REQUESTS_1XX = 0,
    PG_M_REQUESTS_2XX,
    PG_M_REQUESTS_3XX,
    PG_M_REQUESTS_4XX,
    PG_M_REQUESTS_5XX,
    PG_M_CONNECTIONS_ACCEPTED,
    PG_M_CONNECTIONS_CLOSED,
    PG_M_CONNECTIONS_ACTIVE,      /* gauge: this worker's live connections */
    PG_M_CONNECTIONS_REJECTED,    /* over capacity, or no descriptors left */
    PG_M_SLOTS_CAPACITY,          /* gauge: this worker's connection table */
    PG_M_POOL_HITS,               /* buffer pool: a block came off the free list */
    PG_M_POOL_MISSES,             /* buffer pool: a block had to be allocated */
    PG_M_RATE_LIMITED,            /* refused with 429 by --rate-limit */
    PG_M_CACHE_HITS,              /* answered from --cache-size */
    PG_M_CACHE_MISSES,            /* looked up in the cache and not found */
    PG_M_CACHE_STORES,            /* responses stored in the cache */
    PG_M_DURATION_COUNT,
    PG_M_DURATION_SUM_US,
    PG_M_BUCKET0,
    PG_METRIC_COUNT = PG_M_BUCKET0 + PG_METRIC_BUCKETS
};

/* Upper edge of bucket `i`, in microseconds. A function rather than the array
 * itself: Swift imports a C array of known length as a tuple, which cannot be
 * subscripted. */
uint64_t pg_metric_bucket_edge(int i);

/* Maps the page. Call once, before any worker exists and before any fork.
 * Returns 0, or -1 with errno set. Calling it twice is a no-op that succeeds. */
int pg_metrics_init(int slots);

/* Whether pg_metrics_init has mapped a page. */
int pg_metrics_enabled(void);
int pg_metrics_slots(void);

void pg_metrics_add(int slot, int index, uint64_t n);
void pg_metrics_set(int slot, int index, uint64_t v);

/* Which slot the calling worker writes, set once when the worker starts. Each
 * worker owns its own slot, so no two ever write the same counters. */
void pg_metrics_bind(int slot);
void pg_metrics_add_local(int index, uint64_t n);
void pg_metrics_set_local(int index, uint64_t v);

/* Every worker's value for `index`, added together. */
uint64_t pg_metrics_sum(int index);

/* The bucket a duration falls in, or PG_METRIC_BUCKETS for +Inf. */
int pg_metrics_bucket(uint64_t micros);

#endif /* GARUDA_METRICS_H */
