//===----------------------------------------------------------------------===//
// Routes for scripts/websocket-test.py: a WebSocket per case the handshake,
// the framing and the close have to get right.
//
//   /ws/echo              echoes every message; how it ended, at /ws/last-close
//   /ws/sub               subprotocols chat.v2 and chat.v1
//   /ws/reject            refused by middleware with 403
//   /ws/room/:name        middleware adds a cookie; greets the room
//   /ws/close/:code       closes with the code and "bye", then reads on
//   /ws/return, /ws/throw a handler that returns, and one that throws
//   /ws/flood/:n/:size    n binary messages of size bytes, then "sent n"
//   /ws/silent/:ms        reads nothing for ms, then counts what it reads
//   /ws/ticks/:n          n ticks 20 ms apart, then closes
//===----------------------------------------------------------------------===//

import Garuda
import Synchronization

/// How the last WebSocket on /ws/echo or /ws/silent ended, as "<code> <reason>".
/// A connection stays on one shard, and the tests run one.
let lastWebSocketClose = Mutex("")

func addWebSocketRoutes(_ app: Application) {
    app.webSocket("/ws/echo") { (ws: WebSocket) async throws in
        for try await message in ws {
            try await ws.send(message)
        }
        lastWebSocketClose.withLock { $0 = "\(ws.closeCode ?? 0) \(ws.closeReason)" }
    }

    app.get("/ws/last-close") { _, response in
        response.send(lastWebSocketClose.withLock { $0 })
    }

    app.webSocket("/ws/sub", subprotocols: ["chat.v2", "chat.v1"]) { (ws: WebSocket) async throws in
        try await ws.send("\(ws.subprotocol ?? "none") of \(ws.offeredSubprotocols.joined(separator: ","))")
        for try await message in ws { try await ws.send(message) }
    }

    app.group("/ws/reject") {
        app.use { _, response, _ in response.send(status: .forbidden) }
        app.webSocket("/") { (ws: WebSocket) async throws in try await ws.send("should not open") }
    }

    app.group("/ws/room") {
        app.use { _, response, next in
            response.addHeader("set-cookie", "seen=1")
            try await next()
        }
        app.webSocket("/:name") { (ws: WebSocket, name: Path<String>) async throws in
            try await ws.send("welcome to \(name.value)")
            for try await message in ws { try await ws.send(message) }
        }
    }

    app.webSocket("/ws/close/:code") { (ws: WebSocket, code: Path<Int>) async throws in
        ws.close(code: UInt16(clamping: code.value), reason: "bye")
        // Messages sent before the client's close arrive are still read.
        while try await ws.receive() != nil {}
    }

    app.webSocket("/ws/return") { (_: WebSocket) async throws in }

    app.webSocket("/ws/throw") { (ws: WebSocket) async throws in
        _ = try await ws.receive()
        throw HTTPError(.internalServerError, "on purpose")
    }

    /// Sends n binary messages of `size` bytes as fast as the client takes
    /// them, then a text message saying how many went.
    app.webSocket("/ws/flood/:n/:size") { (ws: WebSocket, n: Path<Int>, size: Path<Int>) async throws in
        let payload = [UInt8](repeating: 0x61, count: size.value)
        var sent = 0
        for _ in 0..<n.value {
            try await ws.send(payload)
            sent += 1
        }
        try await ws.send("sent \(sent)")
        while try await ws.receive() != nil {}
    }

    /// Reads nothing for a while, so pings, closes and queueing are seen
    /// without the handler's help.
    app.webSocket("/ws/silent/:ms") { (ws: WebSocket, ms: Path<Int>) async throws in
        try await ws.sleep(milliseconds: UInt64(ms.value))
        var count = 0
        while try await ws.receive() != nil { count += 1 }
        lastWebSocketClose.withLock { $0 = "\(ws.closeCode ?? 0) read \(count)" }
    }

    app.webSocket("/ws/ticks/:n") { (ws: WebSocket, n: Path<Int>) async throws in
        for i in 1...max(1, n.value) {
            try await ws.send("tick \(i)")
            try await ws.sleep(milliseconds: 20)
        }
        ws.close()
    }
}
