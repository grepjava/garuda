//===----------------------------------------------------------------------===//
// TestClient: an application's routes, driven in-process.
//
//     let app = Application()
//     app.get("/user/:id") { (id: Path<Int>) in Text("user \(id.value)") }
//     #expect(try app.test.get("/user/7").text == "user 7")
//
// Each request is served on a fresh in-memory stream (VegaTest's `duplex`)
// by the same HTTP/1 connection task a shard runs for a socket: parsing,
// routing, extractors, handlers and the response writer all run as they do
// under load. Only the network is not there.
//===----------------------------------------------------------------------===//

@_spi(Testing) import Garuda
import GarudaWire
import Vega
import VegaIO
import VegaTest

/// A response as a test sees it.
public struct TestResponse: Sendable {
    public let status: HTTPStatus
    /// Every header as received, in order and with repeats.
    public let headers: [(name: String, value: String)]
    public let body: [UInt8]
    /// The informational (1xx) responses that came before this one, in order.
    public internal(set) var interim: [(status: HTTPStatus, headers: [(name: String, value: String)])] = []

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
    /// No complete response arrived in time.
    case timedOut
    /// The server closed the connection after `received` bytes, short of a
    /// complete response.
    case closed(received: Int)
    /// What came back was not an HTTP/1.1 response.
    case malformed
}

extension Application {
    /// A client for this application's routes, with the default
    /// configuration. Routes cannot be added once it is made.
    public var test: TestClient { TestClient(application: self, configuration: ServerConfig()) }

    /// A client for this application's routes, served with `configuration`'s
    /// limits and timeouts.
    public func testClient(configuration: ServerConfig = ServerConfig()) -> TestClient {
        TestClient(application: self, configuration: configuration)
    }
}

public final class TestClient: @unchecked Sendable {
    let application: Application
    let configuration: ServerConfig
    /// How long a request may take before it fails with `timedOut`.
    public var timeout: Duration = .seconds(5)
    /// The address and port the server sees the requests come from.
    public var remoteAddress = "127.0.0.1"
    public var remotePort = 49152

    /// Every test client's runtime: one per process, never shut down.
    static let runtime = Runtime(workers: 2)

    init(application: Application, configuration: ServerConfig) {
        self.application = application
        self.configuration = configuration
        application.prepareForTesting(configuration, threads: TestClient.runtime.workerCount)
    }

    // MARK: Requests

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

    public func put(_ path: String, body: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("PUT", path, headers: headers, body: Array(body.utf8))
    }

    public func put(_ path: String, body: [UInt8] = [], headers: [(String, String)] = []) throws -> TestResponse {
        try request("PUT", path, headers: headers, body: body)
    }

    public func patch(_ path: String, body: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("PATCH", path, headers: headers, body: Array(body.utf8))
    }

    public func patch(_ path: String, body: [UInt8] = [], headers: [(String, String)] = []) throws -> TestResponse {
        try request("PATCH", path, headers: headers, body: body)
    }

    public func delete(_ path: String, headers: [(String, String)] = []) throws -> TestResponse {
        try request("DELETE", path, headers: headers)
    }

    /// Sends `value` encoded as JSON, with its Content-Type.
    public func post(_ path: String, json value: some Encodable,
                     headers: [(String, String)] = []) throws -> TestResponse {
        try request("POST", path, headers: [("Content-Type", "application/json")] + headers,
                    body: try JSONCoder.encode(value))
    }

    public func put(_ path: String, json value: some Encodable,
                    headers: [(String, String)] = []) throws -> TestResponse {
        try request("PUT", path, headers: [("Content-Type", "application/json")] + headers,
                    body: try JSONCoder.encode(value))
    }

    public func patch(_ path: String, json value: some Encodable,
                      headers: [(String, String)] = []) throws -> TestResponse {
        try request("PATCH", path, headers: [("Content-Type", "application/json")] + headers,
                    body: try JSONCoder.encode(value))
    }

    /// Any method. A Host header is added unless `headers` has one, and a
    /// Content-Length whenever there is a body or the method usually carries
    /// one.
    public func request(_ method: String, _ path: String, headers: [(String, String)] = [],
                        body: [UInt8] = []) throws -> TestResponse {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        let names = headers.map { $0.0.lowercased() }
        if !names.contains("host") { head += "Host: test\r\n" }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        let carries = ["POST", "PUT", "PATCH"].contains(method)
        if (!body.isEmpty || carries) && !names.contains("content-length")
            && !names.contains("transfer-encoding") {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        return try send(raw: Array(head.utf8) + body, bodyless: method == "HEAD")
    }

    /// Writes `bytes` as they are, then reads the first response. `bodyless`
    /// says the request was a HEAD, so a Content-Length frames nothing.
    public func send(raw bytes: [UInt8], bodyless: Bool = false) throws -> TestResponse {
        try exchange(raw: bytes, bodyless: bodyless).first ?? { throw TestClientError.closed(received: 0) }()
    }

    /// Writes `bytes` as they are -- several requests, pipelined -- and
    /// returns every response that comes back before the server closes.
    public func sendPipelined(raw bytes: [UInt8]) throws -> [TestResponse] {
        try exchange(raw: bytes, bodyless: false)
    }

    // MARK: The exchange

    /// Serves `bytes` on a new connection, ends the client's side of it, and
    /// reads until the server closes.
    func exchange(raw bytes: [UInt8], bodyless: Bool) throws -> [TestResponse] {
        let app = application, config = configuration
        let address = remoteAddress, port = remotePort
        let limit = timeout
        let rt = TestClient.runtime
        // The state and start hooks, once per application, as a shard
        // builds them before it serves; what a factory threw, every time.
        try app.startForTesting(on: rt)
        let received: [UInt8] = try rt.block { () async throws -> [UInt8] in
            let pair = duplex(capacity: 1 << 20)
            rt.spawn(with: pair.second) { stream in
                await app.serveConnection(stream, config: config, remoteAddress: address, remotePort: port)
            }
            let client = pair.first
            do {
                return try await Runtime.withIODeadline(limit) { () async throws(IOError) -> [UInt8] in
                    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
                    defer { raw.deallocate() }
                    raw.copyBytes(from: bytes)
                    try await client.write(UnsafeRawBufferPointer(raw))
                    client.shutdownWrite()
                    var buffer = IOBuffer(capacity: 64 * 1024)
                    while true {
                        if buffer.spareCapacity < 16 * 1024 { buffer.reserveCapacity(buffer.capacity * 2) }
                        if try await client.read(into: &buffer) == 0 { break }
                    }
                    return buffer.withUnsafeBytes { Array($0) }
                }
            } catch let error as IOError where error == .timedOut {
                throw TestClientError.timedOut
            }
        }
        return try TestClient.parseResponses(received, bodyless: bodyless)
    }

    /// Every response in `bytes`, in order.
    static func parseResponses(_ bytes: [UInt8], bodyless: Bool) throws -> [TestResponse] {
        var responses: [TestResponse] = []
        var interim: [(status: HTTPStatus, headers: [(name: String, value: String)])] = []
        var at = 0
        let maxHeaders = 256
        let refs = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: maxHeaders)
        defer { refs.deallocate() }
        try bytes.withUnsafeBufferPointer { all in
            guard let start = all.baseAddress else { return }
            while at < all.count {
                let base = start + at
                var head = HTTPResponseHead()
                switch HTTPResponseParser.parse(base, all.count - at, maxHeadSize: 1 << 20,
                                                maxHeaders: maxHeaders, headers: refs, head: &head) {
                case .complete:
                    break
                case .incomplete:
                    throw TestClientError.closed(received: all.count)
                case .failure:
                    throw TestClientError.malformed
                }
                var headers: [(name: String, value: String)] = []
                for i in 0..<head.headerCount {
                    let name = refs[i].name.span(in: base), value = refs[i].value.span(in: base)
                    headers.append((String(decoding: UnsafeBufferPointer(start: name.base, count: name.count), as: UTF8.self),
                                    String(decoding: UnsafeBufferPointer(start: value.base, count: value.count), as: UTF8.self)))
                }
                at += head.headEnd
                if head.status >= 100 && head.status < 200 {
                    interim.append((HTTPStatus(head.status), headers))
                    continue
                }
                var body: [UInt8] = []
                switch head.framing(method: bodyless && responses.isEmpty ? .head : .get) {
                case .none:
                    break
                case .length(let n):
                    guard at + n <= all.count else { throw TestClientError.closed(received: all.count) }
                    body = Array(all[at..<(at + n)])
                    at += n
                case .chunked:
                    var decoder = ChunkedDecoder()
                    var consumed = 0
                    switch decoder.decode(start + at, all.count - at, consumed: &consumed, { p, n in
                        body.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
                    }) {
                    case .finished: at += consumed
                    case .needMore: throw TestClientError.closed(received: all.count)
                    case .failure: throw TestClientError.malformed
                    }
                case .untilClose:
                    body = Array(all[at...])
                    at = all.count
                }
                var response = TestResponse(status: HTTPStatus(head.status), headers: headers, body: body)
                response.interim = interim
                interim = []
                responses.append(response)
            }
        }
        return responses
    }
}
