import Testing
@testable import Garuda

private func address(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> ResolvedAddress {
    ResolvedAddress(bytes: [a, b, c, d])
}

private let alpha = ResolverCacheKey(name: "alpha.example", type: 1)
private let beta = ResolverCacheKey(name: "beta.example", type: 1)

@Suite("Resolver cache")
struct ResolverCacheTests {

    @Test func ananswerComesBackUntilItExpires() {
        var cache = ResolverCache()
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 60, now: 1_000)
        #expect(cache.take(alpha, now: 1_000) == [address(10, 0, 0, 1)])
        // One second before it is due, still good.
        #expect(cache.take(alpha, now: 60_999) == [address(10, 0, 0, 1)])
        // On the second, gone: an entry that expires at a moment is not still
        // valid at that moment.
        #expect(cache.take(alpha, now: 61_000) == nil)
    }

    @Test func anExpiredEntryIsDroppedRatherThanKept() {
        var cache = ResolverCache()
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 1, now: 0)
        #expect(cache.take(alpha, now: 5_000) == nil)
        // Not merely hidden: it is out of the map, so it cannot count towards
        // the bound or be returned later by a clock that moved backwards.
        #expect(cache.entries.isEmpty)
    }

    @Test func aQuestionIsKeyedByTypeAsWellAsName() {
        var cache = ResolverCache()
        let a = ResolverCacheKey(name: "alpha.example", type: 1)
        let aaaa = ResolverCacheKey(name: "alpha.example", type: 28)
        cache.store(a, addresses: [address(10, 0, 0, 1)], ttl: 60, now: 0)
        // A and AAAA are different questions with different answers; sharing
        // an entry would hand an IPv4 address to a caller that asked for IPv6.
        #expect(cache.take(aaaa, now: 0) == nil)
        #expect(cache.take(a, now: 0) != nil)
    }

    // MARK: What the server says about time, and what we do with it

    @Test func aTTLOfZeroIsRaisedToTheMinimum() {
        var cache = ResolverCache()
        // A zero TTL means "do not cache", which behind a load balancer is
        // often a mistake that costs a query per connection. One second is
        // enough to collapse a burst without outliving anything.
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 0, now: 0)
        #expect(cache.take(alpha, now: 999) != nil)
        #expect(cache.take(alpha, now: 1_000) == nil)
    }

    @Test func anAbsurdTTLIsCappedTo() {
        var cache = ResolverCache()
        // A week outlives any deployment that would notice the record change.
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 604_800, now: 0)
        #expect(cache.take(alpha, now: 3_599_000) != nil)
        #expect(cache.take(alpha, now: 3_600_000) == nil)
    }

    /// A name that does not exist is worth remembering: otherwise a typo in a
    /// configuration file becomes a query storm at the moment something is
    /// already wrong.
    @Test func aNameThatDoesNotExistIsRemembered() {
        var cache = ResolverCache()
        cache.store(alpha, addresses: [], ttl: 0, now: 0)
        let found = cache.take(alpha, now: 1_000)
        #expect(found != nil)
        #expect(found?.isEmpty == true)
    }

    /// But kept for less time than a real answer: a missing name is more
    /// likely to be a mistake being fixed than a fact.
    @Test func aNegativeAnswerIsKeptForItsOwnShorterTime() {
        var cache = ResolverCache()
        cache.store(alpha, addresses: [], ttl: 3_600, now: 0)
        #expect(cache.take(alpha, now: 29_000) != nil)
        // Thirty seconds, whatever the server offered for it.
        #expect(cache.take(alpha, now: 30_000) == nil)
    }

    // MARK: Staying bounded

    /// A handler resolving names an attacker chooses -- a proxy route, a
    /// webhook target -- must not be able to fill a worker's memory.
    @Test func theCacheStaysWithinItsBound() {
        var cache = ResolverCache()
        cache.limit = 8
        for i in 0..<50 {
            let key = ResolverCacheKey(name: "host\(i).example", type: 1)
            cache.store(key, addresses: [address(10, 0, 0, UInt8(i % 250))],
                        ttl: 3_600, now: 0)
        }
        #expect(cache.entries.count <= 8)
    }

    @Test func expiredEntriesAreWhatGoFirst() {
        var cache = ResolverCache()
        cache.limit = 3
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 1, now: 0)
        cache.store(beta, addresses: [address(10, 0, 0, 2)], ttl: 3_600, now: 0)
        let third = ResolverCacheKey(name: "third.example", type: 1)
        cache.store(third, addresses: [address(10, 0, 0, 3)], ttl: 3_600, now: 0)

        // Room is needed and alpha has expired, so it goes and the two live
        // entries stay: dropping something still useful while holding
        // something dead would be the wrong trade.
        let fourth = ResolverCacheKey(name: "fourth.example", type: 1)
        cache.store(fourth, addresses: [address(10, 0, 0, 4)], ttl: 3_600, now: 5_000)
        #expect(cache.take(beta, now: 5_000) != nil)
        #expect(cache.take(third, now: 5_000) != nil)
        #expect(cache.take(fourth, now: 5_000) != nil)
    }

    /// With nothing expired, the entry closest to expiring is the one whose
    /// loss costs the fewest future hits.
    @Test func theSoonestToExpireGoesWhenNothingHasExpired() {
        var cache = ResolverCache()
        cache.limit = 2
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 10, now: 0)
        cache.store(beta, addresses: [address(10, 0, 0, 2)], ttl: 3_600, now: 0)
        let third = ResolverCacheKey(name: "third.example", type: 1)
        cache.store(third, addresses: [address(10, 0, 0, 3)], ttl: 3_600, now: 0)

        #expect(cache.take(alpha, now: 0) == nil)
        #expect(cache.take(beta, now: 0) != nil)
        #expect(cache.take(third, now: 0) != nil)
    }

    /// Replacing an entry that is already there must not evict anything: the
    /// map is not growing.
    @Test func refreshingAnEntryDoesNotCostAnother() {
        var cache = ResolverCache()
        cache.limit = 2
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 3_600, now: 0)
        cache.store(beta, addresses: [address(10, 0, 0, 2)], ttl: 3_600, now: 0)
        cache.store(alpha, addresses: [address(10, 0, 0, 9)], ttl: 3_600, now: 1_000)
        #expect(cache.entries.count == 2)
        #expect(cache.take(alpha, now: 1_000) == [address(10, 0, 0, 9)])
        #expect(cache.take(beta, now: 1_000) != nil)
    }

    @Test func hitsAndMissesAreCounted() {
        var cache = ResolverCache()
        #expect(cache.take(alpha, now: 0) == nil)
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 60, now: 0)
        _ = cache.take(alpha, now: 0)
        _ = cache.take(alpha, now: 0)
        #expect(cache.hits == 2)
        // The first lookup, and nothing else: a store is not a miss.
        #expect(cache.misses == 1)
    }

    @Test func clearingForgetsEverything() {
        var cache = ResolverCache()
        cache.store(alpha, addresses: [address(10, 0, 0, 1)], ttl: 3_600, now: 0)
        cache.removeAll()
        #expect(cache.take(alpha, now: 0) == nil)
    }
}
