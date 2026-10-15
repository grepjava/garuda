//===----------------------------------------------------------------------===//
// Routes for scripts/broadcast-test.py: publishing on a topic, and hearing it
// as an event stream and a long poll, on whichever shard the connection
// landed on. Each says which process that is.
//
//   POST /broadcast/:topic           publishes the body, with X-Event as its
//                                    event name; answers its number
//   POST /broadcast/:topic/blocking  the same, from a blocking pool thread
//   GET  /broadcast/:topic/events    forwards the topic as events, from
//                                    Last-Event-ID; ?keepalive=S
//   GET  /broadcast/:topic/poll      the next message as "id event data", or
//                                    204 after ?timeout=MS; ?after=ID
//   GET  /broadcast/:topic/ws        a WebSocket: "pid N" first, then each
//                                    message as "id event data"; text it is
//                                    sent is published
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda
import Vega

/// The value of `name` in a query string, undecoded.
func queryValue(_ query: String, _ name: String) -> String? {
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 && parts[0] == name { return String(parts[1]) }
    }
    return nil
}

func broadcastLine(_ message: BroadcastMessage) -> String {
    "\(message.id) \(message.event ?? "-") \(message.text)"
}

func addBroadcastRoutes(_ app: Application) {
    app.post("/broadcast/:topic") { request, response in
        let topic = Topic(request.parameter(0))
        let id = try topic.publish(request.body, event: request.header("x-event"))
        response.addHeader("x-worker-pid", "\(getpid())")
        response.send("\(id)")
    }

    app.post("/broadcast/:topic/blocking") { request, response in
        let topic = Topic(request.parameter(0))
        let body = request.body
        let event = request.header("x-event")
        let id = try await Runtime.blocking { try topic.publish(body, event: event) }
        response.addHeader("x-worker-pid", "\(getpid())")
        response.send("\(id)")
    }

    app.get("/broadcast/:topic/events") { request, response in
        let topic = Topic(request.parameter(0))
        let last = LastEventID(request.header("last-event-id"))
        let keepAlive = queryValue(request.query, "keepalive").flatMap { Int($0) }
        response.addHeader("x-worker-pid", "\(getpid())")
        let events = await response.eventStream(keepAlive: keepAlive.map { .seconds($0) })
        try await events.forward(topic, after: last)
    }

    app.get("/broadcast/:topic/poll") { request, response in
        let topic = Topic(request.parameter(0))
        let timeout = queryValue(request.query, "timeout").flatMap { UInt64($0) } ?? 1000
        let after = queryValue(request.query, "after").flatMap { BroadcastID($0) }
        response.addHeader("x-worker-pid", "\(getpid())")
        let messages = try response.subscribe(topic, after: after)
        switch try await messages.next(timeoutMilliseconds: timeout) {
        case .message(let message)?: response.send(broadcastLine(message))
        case .missed?: response.send("missed")
        case nil: response.send(status: .noContent)
        }
    }

    app.webSocket("/broadcast/:topic/ws") { (ws: WebSocket, name: Path<String>) async throws in
        let topic = Topic(name.value)
        let messages = try ws.subscribe(topic)
        try await ws.send("pid \(getpid())")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    switch try await messages.next() {
                    case .message(let message): try await ws.send(broadcastLine(message))
                    case .missed: try await ws.send("missed")
                    }
                }
            }
            group.addTask {
                while let incoming = try await ws.receive() {
                    if case .text(let text) = incoming { try topic.publish(text, event: "ws") }
                }
                messages.cancel()
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
            }
        }
    }
}
