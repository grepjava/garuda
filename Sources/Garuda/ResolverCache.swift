//===----------------------------------------------------------------------===//
// What this worker has already looked up.
//
// Without it every connection to the same host is a fresh round trip to a
// nameserver, which is the difference between a resolver that is correct and
// one that is usable: a handler opening connections in a loop would ask about
// the same name every time, and the lookup would cost more than the request.
//
// Per worker, like everything else here, and deliberately not shared. A worker
// is a process with its own poller and its own connections; a shared cache
// would need a lock on the one thread this design exists to keep unlocked, and
// the duplication is a few entries per worker.
//
// Negative answers are kept too. A name that does not exist is asked about
// again and again otherwise -- a typo in a configuration file, or a service
// that has gone away, becomes a query storm against the nameserver at exactly
// the moment something is already wrong.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// A name and what was asked about it. A and AAAA are separate questions with
/// separate answers, so they are separate entries.
struct ResolverCacheKey: Hashable {
    var name: String
    var type: UInt16
}

/// One answer, and when it stops being true.
struct ResolverCacheEntry {
    /// Empty for a name that does not exist, which is worth remembering.
    var addresses: [ResolvedAddress]
    var expiresAtMs: UInt64
}

/// A bounded map from question to answer, evicted lazily.
///
/// Lazily because a worker is one thread and a periodic sweep is work nobody
/// asked for: an entry that has expired and is never looked up again costs one
/// dictionary slot until the bound is reached, which is cheaper than walking
/// every entry once a second to find it.
struct ResolverCache {
    /// Kept small. A handler resolving names an attacker chooses -- a proxy
    /// route, say, or a webhook target -- would otherwise fill a worker's
    /// memory one entry at a time.
    var limit = 512
    /// Neither what a server says nor what it wants. A TTL of 0 means "do not
    /// cache", which for a server behind a load balancer is often a mistake
    /// that costs a query per connection; a TTL of a week outlives any
    /// deployment that would notice it changing.
    var minimumSeconds: UInt32 = 1
    var maximumSeconds: UInt32 = 3600
    /// A name that does not exist is kept for less time than one that does: it
    /// is more likely to be a mistake being corrected than a fact.
    var negativeSeconds: UInt32 = 30

    private(set) var entries: [ResolverCacheKey: ResolverCacheEntry] = [:]
    /// Counted so a test can tell a hit from a fresh query without reaching
    /// into the nameserver.
    private(set) var hits: UInt64 = 0
    private(set) var misses: UInt64 = 0

    /// The answer for this question if it is still good, or nil.
    ///
    /// An expired entry is dropped here rather than returned and ignored: the
    /// lookup is the only moment this cache is certain to be running on the
    /// worker's thread with the key in hand.
    mutating func take(_ key: ResolverCacheKey, now: UInt64) -> [ResolvedAddress]? {
        guard let entry = entries[key] else {
            misses &+= 1
            return nil
        }
        if now >= entry.expiresAtMs {
            entries.removeValue(forKey: key)
            misses &+= 1
            return nil
        }
        hits &+= 1
        return entry.addresses
    }

    /// Remembers an answer. `ttl` is what the server said, in seconds, and is
    /// clamped; an empty list is a name that does not exist and is kept for
    /// `negativeSeconds` regardless of what the server offered.
    mutating func store(_ key: ResolverCacheKey, addresses: [ResolvedAddress],
                        ttl: UInt32, now: UInt64) {
        let seconds: UInt32
        if addresses.isEmpty {
            seconds = negativeSeconds
        } else {
            seconds = min(max(ttl, minimumSeconds), maximumSeconds)
        }
        if entries.count >= limit, entries[key] == nil { makeRoom(now: now) }
        entries[key] = ResolverCacheEntry(addresses: addresses,
                                          expiresAtMs: now &+ UInt64(seconds) &* 1000)
    }

    /// Makes room for one more.
    ///
    /// Expired entries first, since dropping those costs nothing. If none has
    /// expired, the one closest to expiring goes: it is the entry whose loss
    /// costs the fewest future hits, and it avoids the bookkeeping a
    /// least-recently-used order would need on every single lookup.
    private mutating func makeRoom(now: UInt64) {
        let before = entries.count
        entries = entries.filter { now < $0.value.expiresAtMs }
        guard entries.count == before, !entries.isEmpty else { return }
        var soonest: ResolverCacheKey? = nil
        var soonestAt = UInt64.max
        for (key, entry) in entries where entry.expiresAtMs < soonestAt {
            soonest = key
            soonestAt = entry.expiresAtMs
        }
        if let soonest { entries.removeValue(forKey: soonest) }
    }

    /// Forgets everything. For a worker shutting down, and for a test that
    /// wants the next lookup to go to the wire.
    mutating func removeAll() {
        entries.removeAll()
    }
}
