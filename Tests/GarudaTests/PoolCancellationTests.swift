import Testing
import CAvian
@testable import Garuda

// A request waiting for a pooled connection that ends -- its client hung up,
// its deadline passed -- has to leave the pool's queue then, not when a
// release finally reaches it. While whoever holds every connection keeps
// them, no release comes, and each cancelled wait left an entry behind.
//
// Redis stands for both pools here: PostgreSQL's queue is the same
// `PoolWaiters`, and its cancellation branch the same line.

private final class HeldSession: @unchecked Sendable {
    var parked: UnsafeContinuation<Void, Never>?
    var pool: RedisPool?
}

@Suite("Pool waits that are cancelled", .serialized)
struct PoolCancellationTests {
    @Test func aCancelledWaitLeavesTheQueue() throws {
        let fake = try #require(FakeRedisNode())
        let held = HeldSession()
        var configuration = RedisConfiguration(host: "127.0.0.1", port: fake.port)
        configuration.tls = .disable
        configuration.timeoutMilliseconds = 10_000
        let settled = configuration
        let app = Application()
        app.state { _ in
            let pool = RedisPool(settled, maxConnections: 1, acquireTimeoutMilliseconds: 60_000)
            held.pool = pool
            return pool
        }
        app.get("/hold") { (redis: State<RedisPool>) async throws -> String in
            try await redis.value.session { _ in
                await withUnsafeContinuation { held.parked = $0 }
                return "held"
            }
        }
        app.get("/wait") { (redis: State<RedisPool>) async throws -> String in
            try await redis.value.get("key") ?? "nil"
        }
        let client = app.test
        let holder = try TestWire(client)
        holder.send("GET /hold HTTP/1.1\r\nHost: test\r\n\r\n")
        for _ in 0..<1_000 where held.parked == nil {
            fake.pump()
            client.turn()
        }
        #expect(held.parked != nil)

        for _ in 0..<20 {
            let wire = try TestWire(client)
            wire.send("GET /wait HTTP/1.1\r\nHost: test\r\n\r\n")
            #expect(wire.turn(until: { !client.worker.pointee.timedWaits.isEmpty }))
            #expect(held.pool?.waitingCount == 1)
            client.onWorker { client.worker.pointee.closeConnection(wire.slot) }
            #expect(wire.turn(until: { held.pool?.waitingCount == 0 }))
            #expect(client.worker.pointee.timedWaits.isEmpty)
        }

        client.onWorker { held.parked.take()?.resume() }
        #expect(holder.receiveStatus() == 200)
        #expect(held.pool?.waitingCount == 0)
    }
}
