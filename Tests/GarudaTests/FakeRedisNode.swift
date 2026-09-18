import CAvian
import AvianCore

// A Redis that says exactly what a test wants, on cue: the shared fake behind
// the scripted cluster and sentinel tests. Both ends are on this thread -- the
// worker turns, and every fake is pumped on each turn.

/// A Redis that authenticates anyone, answers `HELLO` for itself, and answers
/// each later read with the next reply in its script.
final class FakeRedisNode: @unchecked Sendable {
    struct Step {
        /// What the read must contain, or nil for anything.
        var expect: String?
        var reply: String?
        /// Closes the connection after answering -- and stops listening, so
        /// the node is gone rather than merely rude.
        var goAway = false
    }

    let fd: Int32
    let port: UInt16
    var script: [Step] = []
    private(set) var received: [String] = []
    private(set) var mismatches: [String] = []
    private var open: [Int32] = []
    private var next = 0
    private var listening = true

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        fd = opened
        port = av_local_port(opened)
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        if listening { _ = av_close(fd) }
    }

    var address: String { "127.0.0.1:\(port)" }

    func pump() {
        if listening {
            var address = [CChar](repeating: 0, count: 64)
            var peerPort: UInt16 = 0
            let peer = av_accept(fd, &address, 64, &peerPort)
            if peer >= 0 { open.append(peer) }
        }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            let text = String(decoding: buffer.prefix(got), as: UTF8.self)
            received.append(text)
            // The handshake is this node's own business, not the script's.
            if text.contains("HELLO") {
                write(peer, "%1\r\n$5\r\nproto\r\n:3\r\n")
                continue
            }
            guard next < script.count else { continue }
            let step = script[next]
            next += 1
            if let expect = step.expect, !text.contains(expect) {
                mismatches.append("\(port) expected \(expect) in \(text.debugDescription)")
            }
            if let reply = step.reply { write(peer, reply) }
            if step.goAway {
                for peer in open { _ = av_close(peer) }
                open.removeAll()
                if listening {
                    _ = av_close(fd)
                    listening = false
                }
                return
            }
        }
    }

    private func write(_ peer: Int32, _ text: String) {
        var bytes = text
        bytes.withUTF8 { _ = av_write(peer, $0.baseAddress!, $0.count) }
    }
}

/// A `CLUSTER SLOTS` reply: one range per node, each owned by a master with no
/// replicas.
func slotsReply(_ ranges: [(from: Int, to: Int, port: UInt16)]) -> String {
    var out = "*\(ranges.count)\r\n"
    for range in ranges {
        out += "*3\r\n:\(range.from)\r\n:\(range.to)\r\n"
        let id = "node\(range.port)"
        out += "*3\r\n$9\r\n127.0.0.1\r\n:\(range.port)\r\n$\(id.utf8.count)\r\n\(id)\r\n"
    }
    return out
}

