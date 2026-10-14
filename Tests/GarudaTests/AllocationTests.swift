@_spi(Testing) import Garuda
import CAllocationCounter
import GarudaTesting
import Testing
import Vega

/// What a handler sees on entry: the job it runs in and the allocations its
/// thread has made. Two entries in the same job have nothing between them
/// but the connection's own work for one request -- writing the previous
/// response, parsing the next head, routing, extracting -- and the previous
/// handler, so the difference in their counts is what one request costs.
final class AllocationProbe: @unchecked Sendable {
    let capacity = 1024
    let stamps: UnsafeMutablePointer<JobStamp>
    let counts: UnsafeMutablePointer<Int>
    var taken = 0

    init() {
        stamps = .allocate(capacity: capacity)
        counts = .allocate(capacity: capacity)
    }

    deinit {
        stamps.deallocate()
        counts.deallocate()
    }

    @inline(__always)
    func take() {
        guard taken < capacity else { return }
        stamps[taken] = Runtime.currentJobStamp
        counts[taken] = garuda_test_allocations()
        taken += 1
    }

    /// Allocations between consecutive entries in the same job, after the
    /// first `warmUp` requests, while buffers find their size: `between` for
    /// requests answered within a batch, `flushing` for the ones that wrote
    /// the batch out (every `depth`th). A flush goes to the test's in-memory
    /// stream, whose buffer is an array that doubles as it fills -- something
    /// a socket does not do -- so a flush may allocate, but only as often as
    /// that buffer doubles.
    func perRequest(warmUp: Int, depth: Int) -> (between: [Int], flushing: [Int]) {
        var between: [Int] = [], flushing: [Int] = []
        var i = max(1, warmUp)
        while i < taken {
            if stamps[i] == stamps[i - 1] {
                let cost = counts[i] - counts[i - 1]
                if i % depth == 0 { flushing.append(cost) } else { between.append(cost) }
            }
            i += 1
        }
        return (between, flushing)
    }
}

@Suite(.enabled(if: garuda_test_allocations() >= 0, "allocations are counted on glibc only"))
struct AllocationTests {
    func expectNoAllocations(_ probe: AllocationProbe, sourceLocation: SourceLocation = #_sourceLocation) {
        let depth = ServerConfig().pipelineDepth
        let (between, flushing) = probe.perRequest(warmUp: 2 * depth, depth: depth)
        #expect(between.count >= 50, "too few requests ran back to back in one job", sourceLocation: sourceLocation)
        #expect(between.allSatisfy { $0 == 0 }, "allocations per request: \(between)", sourceLocation: sourceLocation)
        #expect(flushing.reduce(0, +) <= 6, "allocations per flush: \(flushing)", sourceLocation: sourceLocation)
    }

    func pipelined(_ request: String, _ times: Int) -> [UInt8] {
        Array(String(repeating: request, count: times).utf8)
    }

    @Test func helloAllocatesNothing() throws {
        let probe = AllocationProbe()
        let app = Application()
        app.get("/hello") { _, response in
            probe.take()
            response.send("hello")
        }
        let responses = try app.test.sendPipelined(raw: pipelined("GET /hello HTTP/1.1\r\nHost: t\r\n\r\n", 200))
        #expect(responses.count == 200)
        expectNoAllocations(probe)
    }

    @Test func typedPathRouteAllocatesNothing() throws {
        let probe = AllocationProbe()
        let app = Application()
        app.get("/user/:id") { (id: Path<Int>) -> HTTPStatus in
            probe.take()
            return id.value > 0 ? .ok : .notFound
        }
        let responses = try app.test.sendPipelined(raw: pipelined("GET /user/12345 HTTP/1.1\r\nHost: t\r\n\r\n", 200))
        #expect(responses.count == 200)
        #expect(responses.allSatisfy { $0.status == 200 })
        expectNoAllocations(probe)
    }
}
