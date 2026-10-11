import Testing
import CAvian
@testable import Garuda

// Offloaded routes: extracted on the worker, run on its blocking pool, and
// answered back on the worker, which serves other requests meanwhile.

/// A gate a pool thread waits at until the test opens it.
private final class Gate: @unchecked Sendable {
    let lock = av_mutex_new()!
    let opened = av_cond_new()!
    var open = false

    deinit {
        av_cond_free(opened)
        av_mutex_free(lock)
    }

    func wait() {
        av_mutex_lock(lock)
        while !open { av_cond_wait(opened, lock) }
        av_mutex_unlock(lock)
    }

    func release() {
        av_mutex_lock(lock)
        open = true
        av_cond_broadcast(opened)
        av_mutex_unlock(lock)
    }
}

/// Opened by the test to let `/held` finish.
private let heldGate = Gate()

private struct Order: Codable, Sendable {
    var item: String
    var quantity: Int
}

private struct Who: Decodable, Sendable {
    var who: String
}

private struct Receipt: Codable, Sendable {
    var line: String
    var onWorker: Bool
}

/// Whether the calling thread is a worker's.
private func onAWorker() -> Bool { av_worker_current() != nil }

/// A connection kept open, written to and read from by hand, so a test can
/// leave one request outstanding while another is answered.
private final class Wire {
    let client: TestClient
    let fd: Int32
    let slot: Int
    private let capacity = 16384
    private let buffer: UnsafeMutablePointer<UInt8>
    private var got = 0
    private var closed = false

    init(_ client: TestClient) throws {
        self.client = client
        let opened = try client.connect()
        fd = opened.client
        slot = opened.slot
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = av_close(fd)
    }

    func send(_ request: String) {
        var request = request
        request.withUTF8 { _ = av_write(fd, $0.baseAddress!, $0.count) }
    }

    /// Bytes waiting now, without turning the worker.
    @discardableResult
    func pending() -> Int {
        while got < capacity {
            let n = av_read(fd, buffer + got, capacity - got)
            if n <= 0 { break }
            got += n
        }
        return got
    }

    /// Turns until one whole response has arrived, then takes it out of the
    /// buffer and returns its status.
    func receiveStatus(turns: Int = 5_000) -> Int? {
        for _ in 0..<turns {
            client.turn()
            pending()
            guard let total = completeLength(), total == got else { continue }
            let code = status()
            got = 0
            return code
        }
        return nil
    }

    private func status() -> Int? {
        guard got > 12 else { return nil }
        var i = 9
        var code = 0
        while i < got, buffer[i] >= 48, buffer[i] <= 57 {
            code = code * 10 + Int(buffer[i] - 48)
            i += 1
        }
        return code > 0 ? code : nil
    }

    /// The length of the response at the start of the buffer once all of it
    /// is there. Every response here states a Content-Length.
    private func completeLength() -> Int? {
        var end = 0
        while end + 3 < got {
            if buffer[end] == 13 && buffer[end + 1] == 10
                && buffer[end + 2] == 13 && buffer[end + 3] == 10 { break }
            end += 1
        }
        guard end + 3 < got else { return nil }
        let name: StaticString = "\r\ncontent-length: "
        var i = 0
        while i < end {
            var matched = 0
            while matched < name.utf8CodeUnitCount && i + matched < end
                    && (buffer[i + matched] | (matched >= 2 ? 0x20 : 0)) == name.utf8Start[matched] {
                matched += 1
            }
            if matched == name.utf8CodeUnitCount {
                var length = 0
                var d = i + matched
                while d < end && buffer[d] >= 48 && buffer[d] <= 57 {
                    length = length * 10 + Int(buffer[d] - 48)
                    d += 1
                }
                let total = end + 4 + length
                return total <= got ? total : nil
            }
            i += 1
        }
        return nil
    }
}

@Suite("Offloaded routes", .serialized)
struct OffloadTests {
    private func offloadApp() -> Application {
        let app = Application()
        app.offload.get("/sum/:n") { (n: Path<Int>) -> String in
            "\((1...n.value).reduce(0, +)) \(onAWorker() ? "worker" : "pool")"
        }
        app.offload.post("/order") { (order: Body<Order>, query: Query<Who>) -> JSON<Receipt> in
            JSON(Receipt(line: "\(order.value.quantity) x \(order.value.item) for \(query.value.who)",
                         onWorker: onAWorker()))
        }
        app.offload.get("/refused") { () throws -> String in throw HTTPError.conflict("no") }
        app.offload.get("/held") { () -> String in
            heldGate.wait()
            return "held"
        }
        app.group("/api") {
            app.offload.get("/ping") { () -> Text in Text("pong") }
        }
        app.get("/quick") { "quick" }
        return app
    }

    /// The handler runs on a pool thread, not the worker, and what it
    /// returns is the response.
    @Test func anOffloadedHandlerRunsOffTheWorkerAndAnswers() throws {
        let client = offloadApp().test
        #expect(try client.get("/sum/100").text == "5050 pool")
        #expect(try client.get("/api/ping").text == "pong")
    }

    /// Extractors are taken on the worker before the handler goes, and a
    /// value the handler returns is written back there.
    @Test func extractorsAndTheAnswerCrossToThePoolAndBack() throws {
        let client = offloadApp().test
        let response = try client.post("/order?who=ana", json: Order(item: "tea", quantity: 2))
        #expect(response.status == 200)
        #expect(response.text.contains(#""line":"2 x tea for ana""#))
        #expect(response.text.contains(#""onWorker":false"#))
        // A body that does not decode is refused on the worker, before the
        // pool is asked for anything.
        #expect(try client.post("/order", body: "{", headers: [("content-type", "application/json")]).status == 400)
    }

    @Test func whatTheHandlerThrowsIsTheStatus() throws {
        #expect(try offloadApp().test.get("/refused").status == 409)
    }

    /// While an offloaded handler runs, its worker answers other requests.
    @Test func theWorkerServesOthersWhileAnOffloadedHandlerRuns() throws {
        let client = offloadApp().test
        let held = try Wire(client)
        held.send("GET /held HTTP/1.1\r\nHost: test\r\n\r\n")
        for _ in 0..<10 { client.turn() }
        let other = try Wire(client)
        other.send("GET /quick HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(other.receiveStatus() == 200)
        #expect(held.pending() == 0)
        heldGate.release()
        #expect(held.receiveStatus() == 200)
    }
}
