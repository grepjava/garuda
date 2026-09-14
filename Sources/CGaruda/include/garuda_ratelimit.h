/* ---------------------------------------------------------------------------
 * Per-client rate limiting, shared by every worker.
 *
 * Workers do not see a client's traffic whole. Each has its own SO_REUSEPORT
 * socket and the kernel spreads a client's connections across them by hash,
 * so a limit kept per worker is really a limit per worker per client -- N
 * times what was asked for, and unevenly. The state therefore lives in a page
 * mapped MAP_SHARED before the fork, like the metrics page, and every worker
 * reads and writes the same entry for the same client.
 *
 * Each entry is one 64-bit value: GCRA's theoretical arrival time. A request
 * is a load, a comparison and a compare-and-swap of that value, so two workers
 * admitting requests from the same client at once cannot both take the last
 * token -- one CAS fails and retries against what the other wrote. No lock is
 * held across processes, which matters because a lock held by a worker that
 * crashes is held forever.
 *
 * The table is fixed. An entry whose client has been quiet long enough to be
 * back at a full burst is indistinguishable from an empty one, and is reused.
 * When a new client finds every candidate entry busy, the request is allowed:
 * a limiter that refuses traffic because its own table is full is a denial of
 * service against everyone, which is the thing it exists to prevent.
 * ------------------------------------------------------------------------- */
#ifndef GARUDA_RATELIMIT_H
#define GARUDA_RATELIMIT_H

#include <stddef.h>
#include <stdint.h>

/* Maps the table. Call once, before any fork. `emission_us` is the interval
 * between requests at the sustained rate; `tolerance_us` is how far ahead of
 * that a burst may run. 2^log2_entries entries. Returns 0, or -1. */
int pg_ratelimit_init(uint64_t emission_us, uint64_t tolerance_us, int log2_entries);

int pg_ratelimit_enabled(void);

/* Charges one request to the client at `addr`, a textual IPv4 or IPv6
 * address, at monotonic time `now_us`.
 *
 * Returns 0 when the request is allowed, and otherwise how many microseconds
 * until one would be. An address that does not parse -- a unix socket peer --
 * is not limited. IPv6 clients are keyed by their /64, which is what one
 * subscriber is normally given: keying by the full address would give each
 * of them 2^64 separate allowances. */
uint64_t pg_ratelimit_check(const uint8_t *addr, size_t len, uint64_t now_us);

#endif /* GARUDA_RATELIMIT_H */
