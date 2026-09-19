//===----------------------------------------------------------------------===//
// A response read as it arrives, rather than held whole.
//
//     app.onAsync(.get, "/relay") { request, response in
//         let client = request.client
//         let upstream = try await client.stream(.get, "https://files.example/big.iso")
//         let body = response.stream(contentType: "application/octet-stream")
//         while let piece = try await upstream.next() {
//             try await body.write(piece)
//         }
//     }
//
// The body is not held to `maxBodyBytes` and is never all in memory at once.
// What limits how much waits here is the connection itself: over HTTP/1.1 a
// caller that stops reading leaves the bytes in the kernel, which stops the
// peer by TCP's window; over HTTP/2 the stream's window is opened only as the
// caller takes what came, so the peer is held to one window's worth.
//
// `nextEvent` reads the body as server-sent events, which is how most
// streaming APIs -- a model's tokens among them -- deliver what they produce.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import Tracing

/// A response whose body is read as it arrives. From `HTTPClient.stream`.
///
/// It belongs to the handler that made it, on its worker, as a Redis
/// subscription does: read it from that handler, or from a streamed response
/// the handler returns, which runs on the same worker. Read to the end, the
/// connection goes back to be used again; given up on with `cancel` -- or
/// dropped unread -- it is closed, or its HTTP/2 stream reset.
public final class ClientResponseStream: @unchecked Sendable {
    public let status: Int
    /// The reason phrase, which HTTP/2 does not have and HTTP/1.1 may leave
    /// empty.
    public let reason: String
    public let headers: [ClientHeader]
    /// The URL this response answered: the one asked for, or where the
    /// redirects followed led.
    public let url: String

    private var client: HTTPClient
    private var source: Source
    private var events = ServerSentEventParser()
    /// The call's span, when the worker traces: ended with the body.
    var span: (any Span)?

    enum Source {
        case h1(H1Body)
        case h2(H2Shared, H2Stream)
        case ended
    }

    init(_ client: HTTPClient, _ started: HTTPClient.Started, url: String) {
        self.client = client
        self.url = url
        switch started {
        case .h1(let head, let body):
            status = head.status
            reason = head.reason
            headers = head.headers
            source = .h1(body)
        case .h2(let shared, let stream):
            status = stream.status
            reason = ""
            headers = stream.headers
            source = .h2(shared, stream)
        }
    }

    deinit {
        // Given up on without a word. Only the worker's own thread may touch
        // the connection; anywhere else, the worker closes it when it goes.
        guard av_worker_current() == UnsafeMutableRawPointer(client.worker) else {
            span?.end()
            return
        }
        cancel()
    }

    /// The first value of `name`, compared without regard to case.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for field in headers where field.name.count == name.count {
            if field.name.lowercased() == wanted { return field.value }
        }
        return nil
    }

    /// The next piece of the body as it arrived, never empty, or nil once
    /// the body has ended. Waits at most `timeoutMilliseconds` for it.
    public func next() async throws(ClientError) -> [UInt8]? {
        do throws(ClientError) {
            switch source {
            case .h1(let body):
                let piece = try await body.next(client)
                if piece == nil { ended() }
                return piece
            case .h2(let shared, let stream):
                let piece = try await client.nextShared(shared, stream)
                if piece == nil { ended() }
                return piece
            case .ended:
                return nil
            }
        } catch {
            // Closed or reset already by whatever failed.
            source = .ended
            span?.fail(error, type: error.kind)
            span = nil
            throw error
        }
    }

    /// The rest of the body, read whole. `limit` defaults to the client's
    /// `maxBodyBytes`; past it this is `bodyTooLarge` and the rest is given up.
    public func collect(limit: Int? = nil) async throws(ClientError) -> [UInt8] {
        let most = limit ?? client.maxBodyBytes
        var all: [UInt8] = []
        while let piece = try await next() {
            if all.count + piece.count > most {
                cancel()
                throw .bodyTooLarge
            }
            all.append(contentsOf: piece)
        }
        return all
    }

    /// The next server-sent event in the body, or nil once the body has
    /// ended. A comment is skipped, `id` carries over to the events after it
    /// as the format says, and an event cut off by the end of the body is not
    /// returned. One event larger than the client's `maxBodyBytes` is
    /// `bodyTooLarge`.
    public func nextEvent() async throws(ClientError) -> ServerSentEvent? {
        while true {
            if let event = events.take() { return event }
            guard let piece = try await next() else { return nil }
            guard events.feed(piece, limit: client.maxBodyBytes) else {
                cancel()
                throw .bodyTooLarge
            }
        }
    }

    /// Stops reading. The connection is closed, or the HTTP/2 stream reset,
    /// since what is left on it is the rest of a body nobody will read.
    public func cancel() {
        switch source {
        case .h1(let body): body.close()
        case .h2(let shared, let stream): client.cancelShared(shared, stream)
        case .ended: break
        }
        ended()
    }

    private func ended() {
        source = .ended
        span?.answered(status)
        span = nil
    }

    /// The head is in: from here each read is bounded by the per-wait
    /// timeout alone, not the budget that got the stream this far.
    func startReading() {
        client.deadline = 0
        if case .h2(_, let stream) = source {
            stream.exchangeDeadline = 0
            stream.renew(at: av_monotonic_ms())
        }
    }
}

/// One server-sent event, as `ClientResponseStream.nextEvent` reads it.
public struct ServerSentEvent: Sendable, Equatable {
    /// The event's type: what its `event:` field said, or "message".
    public var event: String
    /// Its `data:` lines, joined with newlines.
    public var data: String
    /// The last event ID the stream has set, which carries over to later
    /// events until another `id:` changes it. What to send as
    /// `Last-Event-ID` when reconnecting.
    public var id: String?
    /// How long the server asked a client to wait before reconnecting, if
    /// this event said.
    public var retry: Int?

    public init(event: String = "message", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// The event-stream format, read from bytes as they arrive (the HTML
/// standard's "Server-sent events", section 9.2.6).
struct ServerSentEventParser {
    private var line: [UInt8] = []
    /// The last byte was a CR, so an LF straight after it ends nothing more.
    private var afterCR = false
    private var firstLine = true
    private var eventType: [UInt8] = []
    private var data: [UInt8] = []
    private var sawData = false
    private var lastEventID: String? = nil
    private var retry: Int? = nil
    private var ready: [ServerSentEvent] = []
    private var readyHead = 0

    /// Takes more of the stream. False when one line, or one event's data,
    /// passes `limit` bytes.
    mutating func feed(_ bytes: [UInt8], limit: Int) -> Bool {
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                afterCR = true
                endLine()
            case 0x0A:
                endLine()
            default:
                line.append(byte)
                if line.count + data.count > limit { return false }
            }
        }
        return data.count <= limit
    }

    /// The next whole event, if one is ready.
    mutating func take() -> ServerSentEvent? {
        guard readyHead < ready.count else { return nil }
        let event = ready[readyHead]
        readyHead += 1
        if readyHead == ready.count {
            ready.removeAll(keepingCapacity: true)
            readyHead = 0
        }
        return event
    }

    private mutating func endLine() {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            // A byte order mark at the very start is not part of the first
            // field's name.
            if line.count >= 3, line[0] == 0xEF, line[1] == 0xBB, line[2] == 0xBF {
                line.removeFirst(3)
            }
        }
        guard !line.isEmpty else {
            dispatch()
            return
        }
        // A comment: often a keep-alive, never an event.
        if line[0] == UInt8(ascii: ":") { return }
        let name: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            name = line[..<colon]
            value = line[(colon + 1)...]
            if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        } else {
            name = line[...]
            value = []
        }
        switch String(decoding: name, as: UTF8.self) {
        case "event":
            eventType = Array(value)
        case "data":
            data.append(contentsOf: value)
            data.append(0x0A)
            sawData = true
        case "id":
            // An ID with a NUL in it is ignored, as the format says.
            if !value.contains(0) { lastEventID = String(decoding: value, as: UTF8.self) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
               let ms = Int(String(decoding: value, as: UTF8.self)) {
                retry = ms
            }
        default:
            // Any other field is ignored.
            break
        }
    }

    /// A blank line: the event so far, if it has any data, is complete.
    private mutating func dispatch() {
        defer {
            eventType.removeAll(keepingCapacity: true)
            data.removeAll(keepingCapacity: true)
            sawData = false
            retry = nil
        }
        guard sawData else { return }
        if data.last == 0x0A { data.removeLast() }
        ready.append(ServerSentEvent(
            event: eventType.isEmpty ? "message" : String(decoding: eventType, as: UTF8.self),
            data: String(decoding: data, as: UTF8.self),
            id: lastEventID,
            retry: retry))
    }
}
