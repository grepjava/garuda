/* ---------------------------------------------------------------------------
 * The response cache (--cache-size), shared by every shard.
 *
 * It lives in a region Vega maps before the shards start (ShardOptions
 * .sharedRegions), because a response one shard cached is only worth
 * anything if the shard the next request lands on can answer from it. No
 * lock is ever held across processes: a shard that crashed holding one would
 * hold it for ever.
 *
 * The table is a fixed set of slots in a few sizes -- memory is split evenly
 * between 8 KiB, 64 KiB and 512 KiB slots and slots big enough for the
 * largest entry allowed, and an entry goes in the smallest that holds it, so
 * a cache of small JSON responses is not a few dozen megabyte-sized holes.
 * Each slot is guarded by a version word used as a sequence lock. A writer
 * claims a slot by a compare-and-swap that makes the word odd and puts its
 * process ID in it, writes, and makes it even again. A reader copies the
 * entry out and checks the word did not move while it did; if it did, the
 * lookup is a miss, never a wait. Threads of one process share its ID: a
 * thread cannot die alone, and the compare-and-swap keeps two of them out of
 * one slot.
 *
 * A claim ends only when its writer does. Another writer takes a slot over
 * only once the process named in the claim no longer exists, so a crash
 * costs one slot until then and a pause costs nothing.
 *
 * Every request whose response may be kept is given a number when it is
 * dispatched, from one counter every shard shares. A copy carries its
 * request's number, and wherever copies of the same response are -- two
 * size classes, after the response changed size -- the one with the highest
 * number is the only one a lookup will serve; if that one has expired, the
 * lookup is a miss rather than a return to an older copy.
 *
 * A table of marks, indexed by a hash of the request target, holds for each
 * target the number at or below which its copies are out of date, and a copy
 * at or below its mark is neither stored nor served. A change to the target
 * raises the mark to a new number, which retires every response to a request
 * dispatched before the change. Replacing a copy raises its mark to just
 * below that copy's number, which keeps an older copy of the same response
 * from taking its place. Two targets sharing a mark cost each other a miss
 * now and then, never a stale response.
 *
 * Entries are found by a keyed hash and confirmed by comparing the whole
 * key. The hash's key, the counters and a generation number live in the
 * region's header, so every shard -- each its own process, started however
 * Vega starts it -- hashes alike; `gc_cache_flush` bumps the generation,
 * and an entry stored under an older one is a miss.
 *
 * What an entry holds is opaque here: a status, a block of header bytes and
 * a block of body bytes, both laid out by the caller.
 * ------------------------------------------------------------------------- */
#ifndef GARUDA_CACHE_H
#define GARUDA_CACHE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The longest key an entry can have. A request whose key is longer is
 * simply not cached. */
#define GC_CACHE_MAX_KEY 2048

/* One process's view of the shared table. */
typedef struct gc_cache gc_cache;

/* The bytes of region a table of about `total_bytes`, with room in each
 * entry for `max_head` bytes of headers and `max_body` bytes of body, takes;
 * 0 when that is too little for even one slot of each size. */
uint64_t gc_cache_region_size(uint64_t total_bytes, uint32_t max_head, uint32_t max_body);

/* Attaches to `region`, of the size `gc_cache_region_size` gave for the same
 * arguments and zeroed when it was mapped, setting its header up when this
 * is the first process to, with `seed` keying its hash. NULL when the
 * arguments make no table. */
gc_cache *gc_cache_attach(void *region, uint64_t total_bytes, uint32_t max_head, uint32_t max_body,
                          uint64_t seed);
void gc_cache_detach(gc_cache *cache);

uint32_t gc_cache_max_head(const gc_cache *cache);
uint32_t gc_cache_max_body(const gc_cache *cache);
/* Slots, over every size. */
long gc_cache_slots(const gc_cache *cache);

/* Retires every entry at once. */
void gc_cache_flush(gc_cache *cache);

/* A shard of `shards` has started on the table. One that starts once the
 * first `shards` have -- a reload's replacement, or a crashed one's --
 * retires every entry: new code may answer the same request differently. */
void gc_cache_shard_started(gc_cache *cache, int shards);

/* A number greater than that of every request dispatched and every change
 * made so far. Take one when a request whose response may be stored is
 * dispatched, before the application is called. */
uint64_t gc_cache_begin(gc_cache *cache);

/* The mark a request target is invalidated through: a hash of the target,
 * query string included. */
uint64_t gc_cache_target_hash(const gc_cache *cache, const uint8_t *target, size_t target_len);

/* The target changed: every copy of a response to a request dispatched
 * before now, and every one still to be stored, is out of date. */
void gc_cache_invalidate(gc_cache *cache, uint64_t target_hash);

/* Looks `key` up at monotonic time `now_ms`. On a hit, copies the header
 * block and then the body into `out`, sets the lengths, the status, how old
 * the response is and how long it has left, and returns 1. Returns 0 on a
 * miss, including an entry that changed while it was being read. `out` needs
 * room for max_head + max_body bytes. */
int gc_cache_get(gc_cache *cache, const uint8_t *key, size_t key_len, uint64_t now_ms,
                 uint8_t *out, size_t out_capacity,
                 uint32_t *head_len, uint32_t *body_len, uint16_t *status,
                 uint64_t *age_ms, uint64_t *ttl_ms);

/* Stores the response to the request numbered `sequence` (gc_cache_begin),
 * whose target hashes to `target_hash`. It is `age_ms` old now and fresh for
 * `ttl_ms` more. Returns 1 when it was stored and may be served; 0 when it
 * was too large, every slot it could go in was being written, or it is out
 * of date. */
int gc_cache_put(gc_cache *cache, const uint8_t *key, size_t key_len, uint64_t target_hash,
                 uint64_t sequence, uint64_t now_ms, uint64_t age_ms, uint64_t ttl_ms,
                 uint16_t status,
                 const uint8_t *head, size_t head_len,
                 const uint8_t *body, size_t body_len);

#ifdef __cplusplus
}
#endif

#endif /* GARUDA_CACHE_H */
