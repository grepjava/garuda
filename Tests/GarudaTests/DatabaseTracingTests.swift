import Testing
import CAvian
import AvianCore
import Tracing
import InMemoryTracing
@testable import Garuda

// The spans PostgreSQL statements and Redis round trips leave under a traced
// request, against real servers.
//
// Opt-in through GARUDA_POSTGRES and GARUDA_REDIS, as the integration suites
// are.

private let postgres: PostgresConfiguration? = {
    guard let raw = av_getenv("GARUDA_POSTGRES") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

private let redis: RedisConfiguration? = {
    guard let raw = av_getenv("GARUDA_REDIS") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port,
                                           password: parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 3_000
    return configuration
}()

/// Runs `body` in a traced handler that has `service`, and returns what it
/// returns, or the error it threw, written out.
private func traced<Service>(
    _ tracer: InMemoryTracer, _ make: @escaping @Sendable () -> Service,
    _ body: @escaping @Sendable (Service) async throws -> String) throws -> String {
    let app = Application()
    app.tracing { _ in tracer }
    app.state { _ in make() }
    app.get("/run") { (service: State<Service>) async -> String in
        do {
            return try await body(service.value)
        } catch {
            return "threw \(error)"
        }
    }
    let client = app.test
    client.timeoutMillis = 15_000
    return try client.get("/run").text
}

@Suite("Tracing, PostgreSQL", .serialized,
       .enabled(if: postgres != nil, "set GARUDA_POSTGRES to run"))
struct PostgresTracingTests {
    @Test func aStatementIsASpanUnderTheRequest() throws {
        let tracer = InMemoryTracer()
        let configuration = postgres!
        let result = try traced(tracer, { PostgresPool(configuration, maxConnections: 2) }) { db in
            let rows = try await db.execute("select 1 where $1 = 'a'", "a")
            return "\(rows)"
        }
        #expect(result == "1")

        let spans = tracer.finishedSpans
        let server = try #require(spans.first { $0.kind == .server })
        let statement = try #require(spans.first { $0.kind == .client })
        #expect(statement.operationName == "SELECT")
        #expect(statement.parentSpanID == server.spanID)
        #expect(statement.attributes.get("db.system.name") == .string("postgresql"))
        #expect(statement.attributes.get("db.operation.name") == .string("SELECT"))
        // The SQL as written, never the values sent beside it.
        #expect(statement.attributes.get("db.query.text") == .string("select 1 where $1 = 'a'"))
        #expect(statement.attributes.get("db.namespace") == .string(configuration.database!))
        #expect(statement.attributes.get("server.address") == .string(configuration.host))
        #expect(statement.attributes.get("server.port") == .int64(Int64(configuration.port)))
        #expect(statement.status == nil)
    }

    @Test func aStatementTheServerRefusesCarriesItsCode() throws {
        let tracer = InMemoryTracer()
        let configuration = postgres!
        let result = try traced(tracer, { PostgresPool(configuration, maxConnections: 2) }) { db in
            try await db.execute("select * from garuda_no_such_table")
            return "ran"
        }
        #expect(result.hasPrefix("threw"))
        let statement = try #require(tracer.finishedSpans.first { $0.kind == .client })
        #expect(statement.status?.code == .error)
        #expect(statement.attributes.get("db.response.status_code") == .string("42P01"))
        #expect(statement.attributes.get("error.type") == .string("42P01"))
        #expect(statement.errors.count == 1)
    }

    @Test func aTransactionIsASpanPerStatement() throws {
        let tracer = InMemoryTracer()
        let configuration = postgres!
        let result = try traced(tracer, { PostgresPool(configuration, maxConnections: 2) }) { db in
            try await db.transaction { tx in
                try await tx.execute("select 1")
                try await tx.execute("select 2")
            }
            return "done"
        }
        #expect(result == "done")
        let names = tracer.finishedSpans.filter { $0.kind == .client }.map(\.operationName)
        #expect(names == ["BEGIN", "SELECT", "SELECT", "COMMIT"])
    }
}

@Suite("Tracing, Redis", .serialized,
       .enabled(if: redis != nil, "set GARUDA_REDIS to run"))
struct RedisTracingTests {
    @Test func aCommandAndAPipelineAreSpansUnderTheRequest() throws {
        let tracer = InMemoryTracer()
        let configuration = redis!
        let key = "garuda-test:tracing:\(av_monotonic_us())"
        let result = try traced(tracer, { RedisPool(configuration, maxConnections: 2) }) { redis in
            try await redis.set(key, "1")
            let replies = try await redis.pipeline([RedisCommand("INCR", key), RedisCommand("DEL", key)])
            return "\(replies.count)"
        }
        #expect(result == "2")

        let spans = tracer.finishedSpans
        let server = try #require(spans.first { $0.kind == .server })
        let set = try #require(spans.first { $0.operationName == "SET" })
        #expect(set.kind == .client)
        #expect(set.parentSpanID == server.spanID)
        #expect(set.attributes.get("db.system.name") == .string("redis"))
        #expect(set.attributes.get("db.namespace") == .string("0"))
        #expect(set.attributes.get("server.port") == .int64(Int64(configuration.port)))
        // Keys and values are the application's data, not the span's.
        var sawKey = false
        set.attributes.forEach { _, value in if "\(value)".contains(key) { sawKey = true } }
        #expect(!sawKey)
        let pipeline = try #require(spans.first { $0.operationName == "PIPELINE" })
        #expect(pipeline.attributes.get("db.operation.batch.size") == .int64(2))
    }

    @Test func aRefusedCommandCarriesItsCode() throws {
        let tracer = InMemoryTracer()
        let configuration = redis!
        let key = "garuda-test:tracing-wrong:\(av_monotonic_us())"
        let result = try traced(tracer, { RedisPool(configuration, maxConnections: 2) }) { redis in
            try await redis.set(key, "text")
            let pushed: String
            do {
                _ = try await redis.lpush(key, "x")
                pushed = "pushed"
            } catch {
                pushed = "threw \(error)"
            }
            _ = try await redis.del(key)
            return pushed
        }
        #expect(result.hasPrefix("threw"))
        let push = try #require(tracer.finishedSpans.first { $0.operationName == "LPUSH" })
        #expect(push.status?.code == .error)
        #expect(push.attributes.get("db.response.status_code") == .string("WRONGTYPE"))
    }
}
