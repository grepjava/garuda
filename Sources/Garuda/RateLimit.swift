//===----------------------------------------------------------------------===//
// --rate-limit: turning a client away with 429 before the application runs.
//
//     garuda --rate-limit 600/m --rate-limit-burst 50
//
// The count is the server's, not a shard's or a thread's: a table of
// clients in a region every shard shares (SharedMemory.swift), each entry
// an address's hash and its GCRA theoretical arrival time, updated with
// compare-and-swap. A client that came through four shards spent four
// requests of one allowance, not one of four.
//
// Who the client is follows the rule for forwarded headers everywhere: behind
// a trusted proxy, the address the proxy reports; otherwise the peer. Keying
// by the peer behind a proxy would put every user in one bucket, and
// believing an untrusted X-Forwarded-For would let any client pick a fresh
// bucket per request. An IPv6 client is its /64, which is what one host is
// usually given.
//
// The table is open-addressed, a few entries probed per client. An entry is
// never emptied once used; a full neighbourhood takes over the entry of a
// client back at its full burst, which is the state a new entry starts in.
// A client that finds no entry at all is let through: failing open is the
// lesser harm for a limiter meant to protect, not to account.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega
import VegaCrypto

/// The shared table of clients and when each may next be served.
final class RateLimiter: @unchecked Sendable {
    /// 2^16 entries, a megabyte: room for tens of thousands of clients
    /// active at once before entries have to be reused.
    static let log2Entries = 16
    static let headerSize = 64
    static let regionSize = headerSize + (1 << log2Entries) * 16
    /// How many neighbouring entries a client may land in.
    static let probes = 8

    private let header: UnsafeMutablePointer<Atomic<UInt64>>
    private let table: UnsafeMutablePointer<Atomic<UInt64>>
    private let mask: UInt64
    /// Microseconds between requests at the steady rate, and how far ahead
    /// of it a burst may run.
    let emission: UInt64
    let tolerance: UInt64
    /// Random per server, shared by every shard so they hash alike: an
    /// attacker who could predict where addresses land could crowd a
    /// victim's neighbourhood and have it fail open.
    private let seed: UInt64

    init(region: UnsafeMutableRawBufferPointer, config: ServerConfig) {
        precondition(region.count >= RateLimiter.regionSize)
        let count = max(1, config.rateLimitCount)
        emission = max(1, config.rateLimitPeriodMs * 1000 / UInt64(count))
        let burst = config.rateLimitBurst > 0 ? config.rateLimitBurst : count
        tolerance = emission * UInt64(max(0, burst - 1))
        header = region.baseAddress!.assumingMemoryBound(to: Atomic<UInt64>.self)
        table = (region.baseAddress! + RateLimiter.headerSize).assumingMemoryBound(to: Atomic<UInt64>.self)
        mask = UInt64((1 << RateLimiter.log2Entries) - 1)
        // The first shard to get here draws the seed; the rest read it.
        let state = header, value = header + 1
        if state.pointee.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged {
            var drawn: UInt64 = 0
            for b in SecureRandom.bytes(8) { drawn = drawn << 8 | UInt64(b) }
            value.pointee.store(drawn, ordering: .relaxed)
            state.pointee.store(2, ordering: .releasing)
        }
        while state.pointee.load(ordering: .acquiring) != 2 { sched_yield() }
        seed = value.pointee.load(ordering: .relaxed)
    }

    /// Charges a request to the client at `address` (printable). Microseconds
    /// until the client may send another, or 0 when this one is allowed --
    /// as it is for anything that is not an IP address.
    func check(_ address: UnsafePointer<UInt8>, _ count: Int, now: UInt64) -> UInt64 {
        guard let key = key(address, count) else { return 0 }
        guard let entry = find(key, now: now) else { return 0 }
        let tat = table + 2 * entry + 1
        while true {
            let current = tat.pointee.load(ordering: .relaxed)
            let base = max(current, now)
            if base - now > tolerance { return base - now - tolerance }
            if tat.pointee.compareExchange(expected: current, desired: base + emission,
                                           ordering: .relaxed).exchanged {
                return 0
            }
        }
    }

    /// The client an address belongs to, hashed, or nil for something that
    /// is not an IP address. Brackets and a zone are tolerated, since both
    /// turn up in forwarded headers.
    func key(_ address: UnsafePointer<UInt8>, _ count: Int) -> UInt64? {
        var start = 0
        var end = count
        if count > 0 && address[0] == UInt8(ascii: "[") { start = 1 }
        var i = start
        while i < count {
            if address[i] == UInt8(ascii: "]") || address[i] == UInt8(ascii: "%") {
                end = i
                break
            }
            i += 1
        }
        guard end > start, end - start < 64 else { return nil }
        var text = [CChar](repeating: 0, count: end - start + 1)
        for k in 0..<(end - start) { text[k] = CChar(bitPattern: address[start + k]) }
        var raw = [UInt8](repeating: 0, count: 16)
        var family: Int32 = 0
        let parsed = text.withUnsafeMutableBufferPointer { t in
            raw.withUnsafeMutableBufferPointer { parseIP(t.baseAddress!, $0.baseAddress!, &family) }
        }
        guard parsed else { return nil }
        var bytes: [UInt8]
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        if family == 4 {
            bytes = [4] + raw[0..<4]
        } else if Array(raw[0..<12]) == mapped {
            // ::ffff:a.b.c.d is an IPv4 client on a dual-stack socket, and the
            // same client as a.b.c.d.
            bytes = [4] + raw[12..<16]
        } else {
            // A /64: one host's share of a network, as it is usually handed out.
            bytes = [6] + raw[0..<8]
        }
        var h = seed ^ (0xCBF2_9CE4_8422_2325 &+ UInt64(bytes.count))
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        let mixed = RateLimiter.mix(h)
        return mixed == 0 ? 1 : mixed
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var x = value
        x ^= x >> 30
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return x
    }

    /// The entry for `key`: its own, a free one, or one whose client is back
    /// at a full burst. Nil when the neighbourhood is all busy clients.
    private func find(_ key: UInt64, now: UInt64) -> Int? {
        let home = key & mask
        // An entry is never emptied once used, so a client's own entry is
        // before the first empty one in its probe sequence.
        for p in 0..<UInt64(RateLimiter.probes) {
            let i = Int((home &+ p) & mask)
            let slot = table + 2 * i
            let k = slot.pointee.load(ordering: .relaxed)
            if k == key { return i }
            if k == 0 {
                let (exchanged, original) = slot.pointee.compareExchange(expected: 0, desired: key, ordering: .relaxed)
                if exchanged || original == key { return i }
            }
        }
        for p in 0..<UInt64(RateLimiter.probes) {
            let i = Int((home &+ p) & mask)
            let slot = table + 2 * i
            let k = slot.pointee.load(ordering: .relaxed)
            if k == key { return i }
            if (table + 2 * i + 1).pointee.load(ordering: .relaxed) <= now,
               slot.pointee.compareExchange(expected: k, desired: key, ordering: .relaxed).exchanged {
                return i
            }
        }
        return nil
    }
}

/// Answers a request before routing: the health probe, which an
/// orchestrator sends from one address on a schedule and must never be
/// refused, then --rate-limit. True when it answered. The probe is 503 once
/// SIGTERM has arrived, so that traffic is routed elsewhere.
@inline(never)
func answeredBeforeRouting(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication) -> Bool {
    if let health = app.healthPath {
        let method = x.pointee.head.method
        let path = x.pointee.slice(x.pointee.head.path)
        if (method == .get || method == .head) && path.count == health.count
            && (0..<path.count).allSatisfy({ path.base[$0] == health[$0] }) {
            x.pointee.answer(app.unready.load(ordering: .relaxed) ? 503 : 200, nil, 0)
            return true
        }
    }
    if let limiter = app.rateLimiter, refuseIfRateLimited(x, limiter, app.metrics) { return true }
    return false
}

/// Answers the request 429 when its client has spent its allowance, with
/// Retry-After saying when the next would be allowed. True when it did.
///
/// The connection is kept: the client is being asked to slow down, not
/// disconnected, and a connection it has to reopen costs a handshake for
/// nothing.
func refuseIfRateLimited(_ x: UnsafeMutablePointer<Exchange>, _ limiter: RateLimiter,
                         _ metrics: MetricsPage?) -> Bool {
    let now = monotonicNanos() / 1000
    var wait: UInt64 = 0
    if case .said(let client?, _, _) = x.pointee.forwarded() {
        var client = client
        wait = client.withUTF8 { limiter.check($0.baseAddress!, $0.count, now: now) }
    } else {
        var peer = x.pointee.remote.address
        if peer.isEmpty { return false }
        wait = peer.withUTF8 { limiter.check($0.baseAddress!, $0.count, now: now) }
    }
    guard wait > 0 else { return false }
    metrics?.add(.rateLimited)
    // Whole seconds, rounded up: rounding down would tell a client to come
    // back at a moment it would still be refused.
    let seconds = max(1, (wait + 999_999) / 1_000_000)
    let response = Response(x)
    response.addHeader("retry-after", String(seconds))
    response.send(status: .tooManyRequests, text: "Too Many Requests\n")
    return true
}
