//===----------------------------------------------------------------------===//
// Routes for scripts/webtransport-test.py: a WebTransport session per case
// the routing, the streams, the datagrams and the close have to get right.
//
//   /wt             streams and datagrams echoed with "echo:" in front; a
//                   peer's unidirectional stream is answered on a new one of
//                   ours
//   /wt-reject      refused by middleware with 403, so no session is made
//   /wt-push        opens a unidirectional and a bidirectional stream, then
//                   echoes
//   /wt-close       accepts, then closes with code 7 and "asked to"
//   /wt-return      accepts, and returns without closing
//   /wt-hold        accepts two streams, never reads the first, echoes the
//                   second
//   /wt-abort       reads one stream to its end, however it ends, and reports
//                   what arrived, and whether the peer reset it, on a stream
//                   of its own
//   /wt-report      waits for the session to end, then keeps the peer's close
//                   code and reason for GET /wt-last-close
//   /wt-room/:name  a typed route: middleware adds x-room, and the handler
//                   opens a stream saying "welcome to <name>"
//   /wt-count/:n    Path<Int>, so a name that is not a number is a 400
//===----------------------------------------------------------------------===//

import Garuda
import Synchronization

/// How the last /wt-report session ended, as "<code> <reason>". A QUIC
/// connection stays on one shard, and the tests run one.
let lastWebTransportClose = Mutex("")

/// Answers every stream and datagram the session brings until it ends.
func echo(_ session: WebTransportSession) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while let datagram = try await session.receiveDatagram() {
                session.sendDatagram(Array("echo:".utf8) + datagram)
            }
        }
        while let stream = try await session.acceptStream() {
            group.addTask {
                let body = try await stream.readAll(maxBytes: 8 << 20)
                let out = stream.isBidirectional ? stream : try session.openStream(bidirectional: false)
                try await out.write(Array("echo:".utf8) + body)
                out.finish()
            }
        }
        // The session is over; the datagram reader has returned nil too.
        try await group.waitForAll()
    }
}

func addWebTransportRoutes(_ app: Application) {
    app.onWebTransport("/wt") { _, session in
        try await echo(session)
    }

    app.group("/wt-reject") {
        app.use { _, response, _ in response.send(status: .forbidden) }
        app.onWebTransport("/") { _, session in try await echo(session) }
    }

    app.group("/wt-room") {
        app.use { _, response, next in
            response.addHeader("x-room", "yes")
            try await next()
        }
        app.webTransport("/:name") { (session: WebTransportSession, name: Path<String>) async throws in
            let out = try session.openStream(bidirectional: false)
            try await out.write(Array("welcome to \(name.value)".utf8))
            out.finish()
            while try await session.acceptStream() != nil {}
        }
    }

    app.webTransport("/wt-count/:n") { (session: WebTransportSession, n: Path<Int>) async throws in
        session.close(code: UInt32(clamping: n.value))
    }

    app.onWebTransport("/wt-push") { _, session in
        let uni = try session.openStream(bidirectional: false)
        try await uni.write(Array("push-uni".utf8))
        uni.finish()
        let bidi = try session.openStream(bidirectional: true)
        try await bidi.write(Array("push-bidi".utf8))
        bidi.finish()
        try await echo(session)
    }

    app.onWebTransport("/wt-return") { _, _ in }

    app.onWebTransport("/wt-close") { _, session in
        session.close(code: 7, reason: "asked to")
    }

    app.onWebTransport("/wt-hold") { _, session in
        guard let _ = try await session.acceptStream(),
              let live = try await session.acceptStream() else { return }
        let body = try await live.readAll()
        try await live.write(Array("echo:".utf8) + body)
        live.finish()
        // Stay open until the client has had its answer, so the held stream
        // is not simply abandoned with the session.
        while try await live.read() != nil {}
        while try await session.acceptStream() != nil {}
    }

    app.onWebTransport("/wt-abort") { _, session in
        guard let stream = try await session.acceptStream() else { return }
        let body = try await stream.readAll()
        let out = try session.openStream(bidirectional: false)
        try await out.write(Array((stream.wasAborted ? "aborted:" : "ended:").utf8) + body)
        out.finish()
        while try await session.acceptStream() != nil {}
    }

    app.onWebTransport("/wt-report") { _, session in
        // Returns only once the session has ended and every wait on it with it.
        while try await session.acceptStream() != nil {}
        lastWebTransportClose.withLock { $0 = "\(session.closeCode) \(session.closeReason)" }
    }

    app.get("/wt-last-close") { _, response in
        response.send(lastWebTransportClose.withLock { $0 })
    }
}
