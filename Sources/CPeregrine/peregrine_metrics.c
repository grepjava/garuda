/* ---------------------------------------------------------------------------
 * The shared counter page. See peregrine_metrics.h for why it exists.
 * ------------------------------------------------------------------------- */
#define _GNU_SOURCE

#include "peregrine_metrics.h"

#include <errno.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>

#define PG_CACHE_LINE 64

static const uint64_t pg_metric_bucket_us[PG_METRIC_BUCKETS] = {
    500, 1000, 2500, 5000, 10000, 25000, 50000,
    100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000
};

uint64_t pg_metric_bucket_edge(int i) {
    if (i < 0 || i >= PG_METRIC_BUCKETS) return 0;
    return pg_metric_bucket_us[i];
}

/* Rounded up to whole cache lines so two workers never share one. */
static size_t slot_stride(void) {
    size_t bytes = (size_t)PG_METRIC_COUNT * sizeof(uint64_t);
    return (bytes + PG_CACHE_LINE - 1) / PG_CACHE_LINE * PG_CACHE_LINE;
}

static unsigned char *g_page = NULL;
static int g_slots = 0;
static size_t g_stride = 0;

int pg_metrics_init(int slots) {
    if (g_page) return 0;
    if (slots < 1) slots = 1;
    g_stride = slot_stride();
    size_t bytes = g_stride * (size_t)slots;
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    memset(p, 0, bytes);
    g_page = (unsigned char *)p;
    g_slots = slots;
    return 0;
}

int pg_metrics_enabled(void) { return g_page != NULL; }
int pg_metrics_slots(void) { return g_slots; }

static _Atomic uint64_t *cell(int slot, int index) {
    if (!g_page || slot < 0 || slot >= g_slots) return NULL;
    if (index < 0 || index >= PG_METRIC_COUNT) return NULL;
    return (_Atomic uint64_t *)(g_page + g_stride * (size_t)slot
                                + sizeof(uint64_t) * (size_t)index);
}

/* One writer per slot, so this is a load, an add and a store rather than a
 * locked read-modify-write. */
void pg_metrics_add(int slot, int index, uint64_t n) {
    _Atomic uint64_t *c = cell(slot, index);
    if (!c) return;
    uint64_t v = atomic_load_explicit(c, memory_order_relaxed);
    atomic_store_explicit(c, v + n, memory_order_relaxed);
}

void pg_metrics_set(int slot, int index, uint64_t v) {
    _Atomic uint64_t *c = cell(slot, index);
    if (!c) return;
    atomic_store_explicit(c, v, memory_order_relaxed);
}

static _Thread_local int g_local_slot = 0;

void pg_metrics_bind(int slot) { g_local_slot = slot; }

void pg_metrics_add_local(int index, uint64_t n) {
    pg_metrics_add(g_local_slot, index, n);
}

void pg_metrics_set_local(int index, uint64_t v) {
    pg_metrics_set(g_local_slot, index, v);
}

uint64_t pg_metrics_sum(int index) {
    if (!g_page || index < 0 || index >= PG_METRIC_COUNT) return 0;
    uint64_t total = 0;
    for (int i = 0; i < g_slots; i++) {
        _Atomic uint64_t *c = cell(i, index);
        if (c) total += atomic_load_explicit(c, memory_order_relaxed);
    }
    return total;
}

int pg_metrics_bucket(uint64_t micros) {
    for (int i = 0; i < PG_METRIC_BUCKETS; i++) {
        if (micros <= pg_metric_bucket_us[i]) return i;
    }
    return PG_METRIC_BUCKETS;
}
