//===----------------------------------------------------------------------===//
// Server-sent events: a streamed `text/event-stream` body.
//
//     app.get("/clock") { () async in
//         EventStream { events in
//             var tick = 0
//             while events.isOpen {
//                 tick += 1
//                 try await events.send("\(tick)", event: "tick", id: "\(tick)")
//                 try await events.sleep(milliseconds: 1000)
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
// A stream that goes quiet for `--sse-keep-alive` seconds is sent a comment
// by the worker, whatever the handler is waiting on, so a proxy that closes
// idle connections sees traffic and a client that has gone is noticed when the
// write fails. Events are written whole, so a comment never lands inside one;
// a handler writing to `body` directly should write whole events too.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// A comment line and the blank line that ends it: ignored by the client.
private let eventKeepAliveComment: [UInt8] = [0x3A, 0x0A, 0x0A]

/// The events of one `text/event-stream` response.
public final class EventSink: @unchecked Sendable {
    public let body: ResponseBodyWriter

    init(_ body: ResponseBodyWriter) {
        self.body = body
    }

    /// Whether events still reach the client.
    public var isOpen: Bool { body.isOpen }

    /// Sends one event. `retry` asks the client to wait that many
    /// milliseconds before reconnecting, if the stream drops.
    public func send(_ data: String, event: String? = nil, id: String? = nil,
                     retry: Int? = nil) async throws(HandlerWaitError) {
        try await body.write(EventSink.encode(data, event: event, id: id, retry: retry))
    }

    /// A comment line, which the client ignores. Worth sending every so often
    /// on a quiet stream, so proxies that close idle connections see traffic.
    public func comment(_ text: String = "") async throws(HandlerWaitError) {
        var out = ""
        EventSink.eachLine(text) { out += ":" + ($0.isEmpty ? "" : " " + $0) + "\n" }
        try await body.write(out + "\n")
    }

    /// Waits between events, as `ResponseBodyWriter.sleep` does.
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
        var start = text.unicodeScalars.startIndex
        var i = start
        let scalars = text.unicodeScalars
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

/// A `text/event-stream` response, as a typed async handler's answer. The
/// events are sent by `produce`, and the stream ends when it returns.
///
/// Sets `cache-control: no-cache` unless the handler set its own: an event
/// stream held by a cache is one that never arrives.
public struct EventStream: ResponseConvertible {
    public var status: HTTPStatus?
    /// Seconds of quiet before a keep-alive comment: nil for
    /// `--sse-keep-alive`, 0 for none.
    public var keepAlive: Int?
    let produce: (EventSink) async throws -> Void

    public init(status: HTTPStatus? = nil, keepAlive: Int? = nil,
                _ produce: sending @escaping (EventSink) async throws -> Void) {
        self.status = status
        self.keepAlive = keepAlive
        self.produce = produce
    }

    public func write(to response: borrowing Response) throws {
        let produce = self.produce
        if response.isActive && !response.worker.pointee.hasHeader(response.slot, "cache-control") {
            response.addHeader("cache-control", "no-cache")
        }
        response.startStream(status: status, contentType: "text/event-stream") { body in
            try await produce(EventSink(body))
        }
        if response.isActive {
            response.worker.pointee.armEventKeepAlive(response.slot, seconds: keepAlive)
        }
    }
}

extension Response {
    /// Starts a `text/event-stream` response from an async handler, and sends
    /// its head now.
    /// `keepAlive` is the seconds of quiet before a keep-alive comment: nil
    /// for `--sse-keep-alive`, 0 for none.
    public func eventStream(status: HTTPStatus? = nil, keepAlive: Int? = nil) -> EventSink {
        if isActive && !worker.pointee.hasHeader(slot, "cache-control") {
            addHeader("cache-control", "no-cache")
        }
        let sink = EventSink(stream(status: status, contentType: "text/event-stream"))
        if isActive { worker.pointee.armEventKeepAlive(slot, seconds: keepAlive) }
        return sink
    }
}

extension Worker {
    /// Starts an event stream's keep-alive comments, once its head has gone.
    mutating func armEventKeepAlive(_ slot: Int, seconds: Int?) {
        let c = table[slot]
        // A HEAD, or a response a hook answered in its place, has no body.
        guard c.pointee.flags.contains(.streamingResponse) else { return }
        let ms = seconds.map { UInt64(max(0, $0)) &* 1000 } ?? config.eventKeepAliveMs
        c.pointee.eventKeepAliveMs = UInt32(min(ms, UInt64(UInt32.max)))
        c.pointee.eventKeepAliveDue = av_monotonic_ms() &+ ms
    }

    /// Sends a quiet event stream its comment. Nothing is sent to one whose
    /// client has stopped reading: a writer is already waiting on it, and the
    /// request timeout deals with it.
    mutating func sendEventKeepAlive(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.state == .dispatching, c.pointee.flags.contains(.streamingResponse),
              !c.pointee.flags.contains(.responseComplete) else {
            c.pointee.eventKeepAliveMs = 0
            return
        }
        c.pointee.eventKeepAliveDue = av_monotonic_ms() &+ UInt64(c.pointee.eventKeepAliveMs)
        guard !hasWriterWaiting(slot) else { return }
        _ = eventKeepAliveComment.withUnsafeBufferPointer { streamBody(slot, $0.baseAddress!, $0.count) }
    }

    /// Whether the handler has set a response header named `name`, which is
    /// given in lowercase.
    func hasHeader(_ slot: Int, _ name: StaticString) -> Bool {
        var found = false
        let count = name.utf8CodeUnitCount
        forEachHeaderRecord(table[slot].pointee.responseHeaders) { key, _ in
            if key.count == count && equalsLowercased(key.base, count, name) { found = true }
        }
        return found
    }
}
