/* ---------------------------------------------------------------------------
 * The response cache (--cache-size), shared by every worker.
 *
 * Like the rate-limit table, it lives in memory mapped MAP_SHARED before the
 * fork, because a response cached by one worker is only worth anything if the
 * worker the next request lands on can answer from it. And like that table, no
 * lock is ever held across processes: a worker that crashed holding one would
 * hold it forever.
 *
 * The table is a fixed set of slots in a few sizes -- memory is split evenly
 * between 8 KiB, 64 KiB and 512 KiB slots and slots big enough for the largest
 * entry allowed, and an entry goes in the smallest that holds it, so a cache
 * of small JSON responses is not a few dozen megabyte-sized holes. Each slot
 * is guarded by a version number used as a sequence lock. A writer claims a
 * slot by moving its version
 * from even to odd with a compare-and-swap, writes, and makes it even again. A
 * reader copies the entry out and checks the version did not move while it
 * did; if it did, the lookup is a miss, never a wait. A writer that dies part
 * way leaves an odd version behind, and after a couple of seconds any other
 * writer may take the slot over, so a crash costs one entry for a moment.
 *
 * Entries are found by a keyed hash and confirmed by comparing the whole key.
 * A generation number in the table's header is bumped whenever workers are
 * replaced, and an entry stored under an older one is a miss: new code may
 * answer the same request differently.
 *
 * What an entry holds is opaque here -- a status, a block of header bytes and
 * a block of body bytes, both laid out by the caller.
 * ------------------------------------------------------------------------- */
#ifndef PEREGRINE_CACHE_H
#define PEREGRINE_CACHE_H

#include <stddef.h>
#include <stdint.h>

/* The longest key an entry can have. A request whose key is longer is simply
 * not cached. */
#define PG_CACHE_MAX_KEY 2048

/* Maps `total_bytes` of shared memory, divided into slots each able to hold a
 * key, `max_head` bytes of headers and `max_body` bytes of body. Call once,
 * before any fork. Returns the number of slots, or -1. */
long pg_cache_init(uint64_t total_bytes, uint32_t max_head, uint32_t max_body);

int pg_cache_enabled(void);
uint32_t pg_cache_max_head(void);
uint32_t pg_cache_max_body(void);

/* Retires every entry at once. */
void pg_cache_flush(void);

/* Looks `key` up at monotonic time `now_ms`. On a hit, copies the header block
 * and then the body into `out`, sets the lengths, the status, how long ago the
 * entry was stored and how long it has left, and returns 1. Returns 0 on a
 * miss, including an entry that changed while it was being read. `out` needs
 * room for max_head + max_body bytes. */
int pg_cache_get(const uint8_t *key, size_t key_len, uint64_t now_ms,
                 uint8_t *out, size_t out_capacity,
                 uint32_t *head_len, uint32_t *body_len, uint16_t *status,
                 uint64_t *age_ms, uint64_t *ttl_ms);

/* Stores an entry fresh for `ttl_ms`. Returns 1 when it was stored, 0 when it
 * was too large or every slot it could go in was being written. */
int pg_cache_put(const uint8_t *key, size_t key_len, uint64_t now_ms, uint64_t ttl_ms,
                 uint16_t status,
                 const uint8_t *head, size_t head_len,
                 const uint8_t *body, size_t body_len);

#endif /* PEREGRINE_CACHE_H */
