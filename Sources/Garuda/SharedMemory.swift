//===----------------------------------------------------------------------===//
// What every shard shares: memory mapped before the shards start.
//
// A count that has to be the server's and not one shard's -- a client's
// requests under --rate-limit, the --metrics-port page -- lives in a region
// of Vega's (ShardOptions.sharedRegions): mapped once, before the shards
// start, and the same memory in each. The regions are laid out here from the
// config, so the supervisor that maps them and the shards that use them
// agree on which is which. A server in one process takes the same layout
// from memory of its own.
//===----------------------------------------------------------------------===//

import CGarudaShared
import Vega

/// Which shared region holds what, from the config.
struct SharedLayout: Sendable {
    private(set) var sizes: [Int] = []
    private(set) var ticketKey: Int?
    private(set) var rateLimit: Int?
    private(set) var metrics: Int?
    private(set) var cache: Int?
    private(set) var bus: Int?

    init(_ config: ServerConfig) {
        if !config.tlsCertificates.isEmpty { ticketKey = add(TicketKey.regionSize) }
        if config.rateLimitCount > 0 { rateLimit = add(RateLimiter.regionSize) }
        if config.metricsPort != nil { metrics = add(MetricsPage.regionSize) }
        if let size = ResponseCache.regionSize(config) { cache = add(size) }
        if let size = TopicBus.regionSize(config) { bus = add(size) }
    }

    private mutating func add(_ size: Int) -> Int {
        sizes.append(size)
        return sizes.count - 1
    }
}

/// What a shard reaches through the shared regions.
final class ServerShared: Sendable {
    let ticketKey: [UInt8]?
    let rateLimiter: RateLimiter?
    let metrics: MetricsPage?
    let cache: ResponseCache?
    /// --broadcast-size: the ring topics cross shards in (Broadcast.swift).
    let bus: TopicBus?

    /// `region(i)` is region `i` of `layout`; `shard` is this shard's index.
    init(_ layout: SharedLayout, config: ServerConfig, shard: Int,
         region: (Int) -> UnsafeMutableRawBufferPointer) {
        ticketKey = layout.ticketKey.map { TicketKey.shared(in: region($0)) }
        rateLimiter = layout.rateLimit.map { RateLimiter(region: region($0), config: config) }
        metrics = layout.metrics.map { MetricsPage(region: region($0), shard: shard) }
        cache = layout.cache.flatMap { ResponseCache(region: region($0), config: config) }
        bus = layout.bus.flatMap { TopicBus(region: region($0), config: config) }
    }

    /// This shard has started, one of `shards`: a replacement's start retires
    /// what the cache holds.
    func shardStarted(of shards: Int) {
        if let cache { gc_cache_shard_started(cache.handle, Int32(shards)) }
    }

    /// For a server in one process: the regions are its own memory.
    convenience init(_ layout: SharedLayout, config: ServerConfig) {
        let regions = layout.sizes.map { size -> UnsafeMutableRawBufferPointer in
            let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 64)
            memory.initializeMemory(as: UInt8.self, repeating: 0)
            return memory
        }
        self.init(layout, config: config, shard: 0) { regions[$0] }
    }
}
