//===----------------------------------------------------------------------===//
// TestClient: an application's routes, driven in-process.
//
// A test client owns one worker, built as a worker process builds its own but
// with no listener. Each request takes a fresh socket pair: one end is adopted
// into a connection slot the way an accepted connection is, the request is
// written into the other, and the worker's loop is turned by hand until the
// whole response has come back. Parsing, routing, handlers, continuations and
// the response sink all run as they do under load; only the network is not
// there.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CGaruda
import GarudaCore

public struct TestResponse {
    public let status: HTTPStatus
    /// Every header as received, in order and with repeats.
    public let headers: [(name: String, value: String)]
    public let body: [UInt8]

    /// The body as text, with invalid UTF-8 repaired.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The first value of `name`, compared without regard to case, or nil.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
    }

    /// Every value of `name`, in order.
    public func headers(named name: String) -> [String] {
        let wanted = name.lowercased()
        return headers.filter { $0.name.lowercased() == wanted }.map { $0.value }
    }

    /// The body read as `type`, for an answer that is JSON.
    public func json<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONCoder.decode(type, from: body)
    }
}

public enum TestClientError: Error, Equatable {
    /// No complete response arrived within `timeoutMillis`.
    case timedOut
    /// The worker closed the connection after `received` bytes, short of a
    /// complete response.
    case closed(received: Int)
    /// A socket pair could not be made (the errno), or the worker had no
    /// slot for it (0).
    case socket(Int32)
    /// What came back was not an HTTP/1.1 response.
    case malformed
}

public final class TestClient {
    let application: Application
    let worker: UnsafeMutablePointer<Worker>
    /// How long a request may take before it fails with `timedOut`.
    public var timeoutMillis: UInt64 = 5_000

    init(application: Application, configuration: ServerConfig) {
        guard let poller = Poller(maxEvents: 64) else {
            fatalError("cannot create a readiness poller for the test client")
        }
        self.application = application
        worker = UnsafeMutablePointer<Worker>.allocate(capacity: 1)
        worker.initialize(to: Worker(config: configuration, listenFD: -1, poller: poller))
        worker.pointee.application = application.compile()
        // A test gets the state a forked worker builds, built the same way.
        // A factory that throws stops a worker's start-up; here there is no
        // worker to stop, so it stops the test.
        onWorker {
            do {
                try worker.pointee.buildState(worker.pointee.application, index: 0)
            } catch {
                fatalError("a state factory threw in the test client: \(error)")
            }
        }
    }

    deinit {
        onWorker {
            worker.pointee.tearDownState(worker.pointee.application)
            worker.pointee.destroy()
        }
        worker.deinitialize(count: 1)
        worker.deallocate()
    }

    public func get(_ path: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("GET", path, headers: headers)
    }

    public func head(_ path: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("HEAD", path, headers: headers)
    }

    public func post(_ path: String, body: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("POST", path, headers: headers, body: Array(body.utf8))
    }

    public func post(_ path: String, body: [UInt8] = [], headers: [(String, String)] = []) throws -> TestResponse {
        try request("POST", path, headers: headers, body: body)
    }

    public func put(_ path: String, body: [UInt8] = [], headers: [(String, String)] = []) throws -> TestResponse {
        try request("PUT", path, headers: headers, body: body)
    }

    public func delete(_ path: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("DELETE", path, headers: headers)
    }

    /// Sends an HTTP/1.1 request. Host is added unless given, and
    /// Content-Length for a body unless a length or Transfer-Encoding is.
    public func request(_ method: String, _ path: String, headers: [(String, String)] = [],
                        body: [UInt8] = []) throws -> TestResponse {
        func given(_ name: String) -> Bool { headers.contains { $0.0.lowercased() == name } }
        var bytes = Array("\(method) \(path) HTTP/1.1\r\n".utf8)
        if !given("host") { bytes += Array("host: test\r\n".utf8) }
        for (name, value) in headers { bytes += Array("\(name): \(value)\r\n".utf8) }
        if !body.isEmpty && !given("content-length") && !given("transfer-encoding") {
            bytes += Array("content-length: \(body.count)\r\n".utf8)
        }
        bytes += Array("\r\n".utf8)
        bytes += body
        return try exchange(bytes, bodyless: method == "HEAD")
    }

    /// Sends `bytes` exactly as given and returns the first final response,
    /// for a request none of the helpers can build. `bodyless` is for a
    /// response to HEAD, which declares a length it does not send.
    public func send(raw bytes: [UInt8], bodyless: Bool = false) throws -> TestResponse {
        try exchange(bytes, bodyless: bodyless)
    }

    // MARK: The exchange

    /// A socket pair with the worker's end adopted into a connection slot:
    /// the client's descriptor, the slot and its generation.
    func connect() throws -> (client: Int32, slot: Int, generation: UInt32) {
        var fds: [Int32] = [-1, -1]
        #if canImport(Glibc)
        let made = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #else
        let made = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #endif
        guard made == 0 else { throw TestClientError.socket(pg_errno()) }
        for fd in fds {
            _ = pg_set_nonblock(fd)
            _ = pg_set_cloexec(fd)
        }
        let address: StaticString = "127.0.0.1"
        let slot = worker.pointee.adoptConnection(fds[0], address: address.utf8Start,
                                                  addressLength: address.utf8CodeUnitCount,
                                                  port: 1)
        guard slot >= 0 else {
            _ = pg_close(fds[1])
            throw TestClientError.socket(0)
        }
        return (fds[1], slot, worker.pointee.table[slot].pointee.generation)
    }

    /// A client that sends `bytes`, lets the worker take `turns` turns, and
    /// goes away without reading the answer. The worker closes its end at
    /// once, cancelling whatever the request was waiting on.
    func abandon(_ bytes: [UInt8], turns: Int) throws {
        let (client, slot, generation) = try connect()
        _ = bytes.withUnsafeBufferPointer { pg_write(client, $0.baseAddress!, $0.count) }
        for _ in 0..<turns { turn() }
        _ = pg_close(client)
        let c = worker.pointee.table[slot]
        if c.pointee.state != .free && c.pointee.generation == generation {
            onWorker { worker.pointee.closeConnection(slot) }
        }
    }

    func exchange(_ bytes: [UInt8], bodyless: Bool) throws -> TestResponse {
        let (client, slot, generation) = try connect()
        defer { hangUp(client, slot: slot, generation: generation) }

        let deadline = pg_monotonic_ms() + timeoutMillis
        var written = 0
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if written < bytes.count {
                let n = bytes.withUnsafeBufferPointer {
                    pg_write(client, $0.baseAddress! + written, bytes.count - written)
                }
                if n > 0 { written += n }
            }
            turn()
            var closed = false
            while true {
                let n = chunk.withUnsafeMutableBufferPointer {
                    pg_read(client, $0.baseAddress!, $0.count)
                }
                if n > 0 {
                    received.append(contentsOf: chunk[0..<n])
                    continue
                }
                if n == 0 { closed = true }
                break
            }
            if let response = try TestResponse.parse(received, bodyless: bodyless, closed: closed) {
                return response
            }
            if closed { throw TestClientError.closed(received: received.count) }
            if pg_monotonic_ms() > deadline { throw TestClientError.timedOut }
        }
    }

    /// One turn of the worker's loop, as `runSynchronousLoop` takes it, with
    /// a short wait so that a request waiting on a timer does not spin.
    func turn() {
        onWorker {
            let n = worker.pointee.poller.wait(timeoutMillis: 1)
            if n > 0 { worker.pointee.processEvents(n) }
            worker.pointee.fireDueTimers()
            worker.pointee.drainReadyQueue()
            worker.pointee.runHandlerTasks()
            worker.pointee.sweepTimeouts()
        }
    }

    /// Runs `body` with this client's worker current on the calling thread, as
    /// the engine expects of anything that touches a worker: its handler
    /// tasks run only on a thread their worker is current on.
    func onWorker<R>(_ body: () throws -> R) rethrows -> R {
        let previous = currentWorker
        currentWorker = worker
        defer { currentWorker = previous }
        return try body()
    }

    /// Closes the client's end and turns the loop until the worker has let go
    /// of the connection, so the next request starts from an idle worker.
    func hangUp(_ client: Int32, slot: Int, generation: UInt32) {
        _ = pg_close(client)
        for _ in 0..<1_000 {
            let c = worker.pointee.table[slot]
            if c.pointee.state == .free || c.pointee.generation != generation { return }
            turn()
        }
        onWorker { worker.pointee.closeConnection(slot) }
    }
}

// MARK: - Parsing a response

extension TestResponse {
    /// The first final response in `bytes`, or nil while it is incomplete.
    static func parse(_ bytes: [UInt8], bodyless: Bool, closed: Bool) throws -> TestResponse? {
        var start = 0
        while true {
            guard let end = headEnd(bytes, from: start) else { return nil }
            let text = String(decoding: bytes[start..<end], as: UTF8.self)
            var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard !lines.isEmpty else { throw TestClientError.malformed }
            let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
            guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
                  let status = Int(statusLine[1]) else {
                throw TestClientError.malformed
            }
            var headers: [(name: String, value: String)] = []
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { throw TestClientError.malformed }
                let name = String(line[..<colon])
                let value = line[line.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
                headers.append((name, String(value)))
            }
            let bodyStart = end + 4
            // An interim response: the final one follows it.
            if status >= 100 && status < 200 {
                start = bodyStart
                continue
            }
            func value(_ name: String) -> String? {
                headers.first { $0.name.lowercased() == name }?.value
            }
            if bodyless || status == 204 || status == 304 {
                return TestResponse(status: HTTPStatus(status), headers: headers, body: [])
            }
            if let length = value("content-length").flatMap({ Int($0) }) {
                guard bytes.count - bodyStart >= length else { return nil }
                return TestResponse(status: HTTPStatus(status), headers: headers,
                                    body: Array(bytes[bodyStart..<(bodyStart + length)]))
            }
            if value("transfer-encoding")?.lowercased() == "chunked" {
                guard let body = try dechunk(bytes, from: bodyStart) else { return nil }
                return TestResponse(status: HTTPStatus(status), headers: headers, body: body)
            }
            // Neither: the body runs to the close.
            guard closed else { return nil }
            return TestResponse(status: HTTPStatus(status), headers: headers, body: Array(bytes[bodyStart...]))
        }
    }

    /// Where the head starting at `from` ends: the index of its blank line's CR.
    static func headEnd(_ bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 3 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                return i
            }
            i += 1
        }
        return nil
    }

    /// A chunked body from `from`, or nil while it is incomplete. Trailers are
    /// not expected.
    static func dechunk(_ bytes: [UInt8], from: Int) throws -> [UInt8]? {
        var body: [UInt8] = []
        var i = from
        while true {
            var lineEnd = i
            while lineEnd + 1 < bytes.count && !(bytes[lineEnd] == 13 && bytes[lineEnd + 1] == 10) {
                lineEnd += 1
            }
            guard lineEnd + 1 < bytes.count else { return nil }
            let sizeText = String(decoding: bytes[i..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16) else { throw TestClientError.malformed }
            i = lineEnd + 2
            if size == 0 {
                guard i + 1 < bytes.count else { return nil }
                return body
            }
            guard bytes.count >= i + size + 2 else { return nil }
            body.append(contentsOf: bytes[i..<(i + size)])
            i += size + 2
        }
    }
}
