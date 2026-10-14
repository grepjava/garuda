//===----------------------------------------------------------------------===//
// Server-sent events: a streamed `text/event-stream` body.
//
//     app.get("/clock") { () async in
//         EventStream { events in
//             var tick = 0
//             while events.isOpen {
//                 tick += 1
//                 try await events.send("\(tick)", event: "tick", id: "\(tick)")
//                 try await events.sleep(for: .seconds(1))
//             }
//         }
//     }
//
// Each event is written as its own fields and a blank line, as the HTML
// standard's event-stream format has it: data split on its line breaks, one
// `data:` line each, so a multi-line payload arrives as the one string it was
// sent as. An event name and ID are single lines by definition, and a line
// break in either is replaced rather than allowed to start a field of its
// own. The body is a `ResponseBodyWriter`'s, so backpressure, cancellation
// and the protocol framing are the same as for any streamed response.
//
// A stream that goes quiet for `ServerConfig.eventKeepAlive` is sent a
// comment, whatever the handler is waiting on, so a proxy that closes idle
// connections sees traffic and a client that has gone is noticed when the
// write fails. Events are written whole, so a comment never lands inside
// one; a handler writing to `body` directly should write whole events too.
//
// The head goes at once -- a client's EventSource opens on it -- rather than
// with the first event, which may be a long way off.
//===----------------------------------------------------------------------===//

/// A comment line and the blank line that ends it: ignored by the client.
private let eventKeepAliveComment: [UInt8] = [0x3A, 0x0A, 0x0A]

/// The events of one `text/event-stream` response.
public final class EventSink: Sendable {
    public let body: ResponseBodyWriter

    init(_ body: ResponseBodyWriter, keepAlive: Duration?) {
        self.body = body
        let channel = body.channel
        channel.keepAlive(every: keepAlive ?? channel.keepAliveDefault, comment: eventKeepAliveComment)
    }

    /// Whether events still reach the client.
    public var isOpen: Bool { body.isOpen }

    /// Sends one event. `retry` asks the client to wait that many
    /// milliseconds before reconnecting, if the stream drops.
    public func send(_ data: String, event: String? = nil, id: String? = nil,
                     retry: Int? = nil) async throws(HandlerWaitError) {
        try await body.write(EventSink.encode(data, event: event, id: id, retry: retry))
    }

    /// A comment line, which the client ignores.
    public func comment(_ text: String = "") async throws(HandlerWaitError) {
        var out = ""
        EventSink.eachLine(text) { out += ":" + ($0.isEmpty ? "" : " " + $0) + "\n" }
        try await body.write(out + "\n")
    }

    /// Waits between events. Throws `cancelled` if the request ends first.
    public func sleep(for duration: Duration) async throws(HandlerWaitError) {
        try await body.sleep(for: duration)
    }

    public func sleep(milliseconds: UInt64) async throws(HandlerWaitError) {
        try await body.sleep(milliseconds: milliseconds)
    }

    /// Ends the stream now rather than when the handler returns.
    public func finish() { body.finish() }

    static func encode(_ data: String, event: String?, id: String?, retry: Int?) -> String {
        var out = ""
        if let event { out += "event: " + singleLine(event) + "\n" }
        // A NUL in an ID makes the client ignore the field, so it goes too.
        if let id { out += "id: " + singleLine(id).filter { $0 != "\0" } + "\n" }
        if let retry, retry >= 0 { out += "retry: \(retry)\n" }
        eachLine(data) { out += "data: " + $0 + "\n" }
        return out + "\n"
    }

    /// Calls `body` with each line of `text`, split on CRLF, CR or LF, the
    /// three the format recognises. An empty string is one empty line.
    static func eachLine(_ text: String, _ body: (Substring) -> Void) {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var i = start
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "\r" || c == "\n" {
                body(Substring(scalars[start..<i]))
                var next = scalars.index(after: i)
                if c == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                    next = scalars.index(after: next)
                }
                i = next
                start = next
            } else {
                i = scalars.index(after: i)
            }
        }
        body(Substring(scalars[start..<scalars.endIndex]))
    }

    static func singleLine(_ text: String) -> String {
        var out = ""
        var first = true
        eachLine(text) { line in
            if !first { out += " " }
            out += line
            first = false
        }
        return out
    }
}

/// A `text/event-stream` response, as a typed handler's answer. The events
/// are sent by `produce`, and the stream ends when it returns.
///
/// Sets `cache-control: no-cache` unless the handler set its own: an event
/// stream held by a cache is one that never arrives.
public struct EventStream: ResponseConvertible {
    public var status: HTTPStatus?
    /// Quiet before a keep-alive comment: nil for
    /// `ServerConfig.eventKeepAlive`, zero for none.
    public var keepAlive: Duration?
    let produce: @Sendable (EventSink) async throws -> Void

    public init(status: HTTPStatus? = nil, keepAlive: Duration? = nil,
                _ produce: @escaping @Sendable (EventSink) async throws -> Void) {
        self.status = status
        self.keepAlive = keepAlive
        self.produce = produce
    }

    public func write(to response: borrowing Response) throws {
        let produce = self.produce
        let keepAlive = self.keepAlive
        if !response.exchange.pointee.hasResponseHeader("cache-control") {
            response.addHeader("cache-control", "no-cache")
        }
        try StreamingBody(status: status, contentType: "text/event-stream") { body in
            let events = EventSink(body, keepAlive: keepAlive)
            try await body.flush()
            try await produce(events)
        }.write(to: response)
    }
}

extension Response {
    /// Starts a `text/event-stream` response and sends its head.
    /// `keepAlive` is the quiet before a keep-alive comment: nil for
    /// `ServerConfig.eventKeepAlive`, zero for none.
    public func eventStream(status: HTTPStatus? = nil, keepAlive: Duration? = nil) async -> EventSink {
        if !exchange.pointee.isStreamingAlready && !exchange.pointee.hasResponseHeader("cache-control") {
            addHeader("cache-control", "no-cache")
        }
        let body = stream(status: status, contentType: "text/event-stream")
        let events = EventSink(body, keepAlive: keepAlive)
        try? await body.flush()
        return events
    }
}

extension Exchange {
    /// Whether the handler has set a response header `name`, given in
    /// lowercase.
    func hasResponseHeader(_ name: StaticString) -> Bool {
        var found = false
        forEachResponseHeader { key, _ in
            if !found && key.equals(name) { found = true }
        }
        return found
    }

    var isStreamingAlready: Bool { channel != nil }
}
