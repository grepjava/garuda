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
 * is guarded by a version word used as a sequence lock. A writer claims a slot
 * by a compare-and-swap that makes the word odd and puts its process ID in
 * it, writes, and makes it even again. A reader copies the entry out and
 * checks the word did not move while it did; if it did, the lookup is a miss,
 * never a wait.
 *
 * A claim ends only when its writer does. One that is merely slow --
 * descheduled, stopped, swapping -- keeps its slot however long it takes, and
 * another writer takes a slot over only once the process named in the claim
 * no longer exists, so a crash costs one slot until then and a pause costs
 * nothing.
 *
 * Every request whose response may be kept is given a number when it is
 * dispatched, from one counter every worker shares. A copy carries its
 * request's number, and wherever copies of the same response are -- two size
 * classes, after the response changed size -- the one with the highest number
 * is the only one a lookup will serve; if that one has expired, the lookup is
 * a miss rather than a return to an older copy. Storing a copy retires the
 * older ones it can see, and a copy older than one already kept is not stored.
 *
 * Invalidation uses the same numbers. A table of marks, indexed by a hash of
 * the request target, holds the number of the last change made to a target
 * through it. A copy numbered below its target's mark answers a request that
 * was dispatched before the change, and is neither stored nor served. Two
 * targets sharing a mark cost each other a miss now and then, never a stale
 * response.
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

/* A number greater than that of every request dispatched and every change
 * made so far. Take one when a request whose response may be stored is
 * dispatched, before the application is called. 0 when there is no cache. */
uint64_t pg_cache_begin(void);

/* The mark a request target is invalidated through: a hash of the target,
 * query string included. */
uint64_t pg_cache_target_hash(const uint8_t *target, size_t target_len);

/* The target changed: every copy of a response to a request dispatched before
 * now, and every one still to be stored, is out of date. */
void pg_cache_invalidate(uint64_t target_hash);

/* Looks `key` up at monotonic time `now_ms`. On a hit, copies the header block
 * and then the body into `out`, sets the lengths, the status, how old the
 * response is and how long it has left, and returns 1. Returns 0 on a miss,
 * including an entry that changed while it was being read. `out` needs room
 * for max_head + max_body bytes. */
int pg_cache_get(const uint8_t *key, size_t key_len, uint64_t now_ms,
                 uint8_t *out, size_t out_capacity,
                 uint32_t *head_len, uint32_t *body_len, uint16_t *status,
                 uint64_t *age_ms, uint64_t *ttl_ms);

/* Stores the response to the request numbered `sequence` (pg_cache_begin),
 * whose target hashes to `target_hash`. It is `age_ms` old now and fresh for
 * `ttl_ms` more. Returns 1 when it was stored; 0 when it was too large, its
 * target changed after the request was dispatched, a more recent copy is
 * already kept, or every slot it could go in was being written. */
int pg_cache_put(const uint8_t *key, size_t key_len, uint64_t target_hash,
                 uint64_t sequence, uint64_t now_ms, uint64_t age_ms, uint64_t ttl_ms,
                 uint16_t status,
                 const uint8_t *head, size_t head_len,
                 const uint8_t *body, size_t body_len);

#endif /* PEREGRINE_CACHE_H */
