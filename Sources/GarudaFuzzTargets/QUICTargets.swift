//===----------------------------------------------------------------------===//
// QUIC past the packet header: the ClientHello a connection is made from, and
// the frames inside a packet that has decrypted.
//
// Both run a real server connection in process, sans I/O, against the tests'
// own client (Tests/QUICTestPeer): datagrams are handed across as arrays and
// the clock is a number, so a run is quick and repeatable. A packet that does
// not decrypt never reaches the frame parser, which is why these cannot be
// fed raw bytes the way `quic-packet` is: the input is sealed under the
// connection's keys first.
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import QUICTestPeer
import VegaCrypto
import VegaTLS

enum QUICFixture {
    /// One certificate for every connection: making one is far slower than
    /// a handshake.
    static let certificate: CertificateKey = {
        let identity = try! TLSIdentity.selfSigned(names: ["localhost"])
        return try! CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
    }()

    nonisolated(unsafe) static let config = QUICServerConfig(certKey: certificate, alpn: [Array("h3".utf8)])

    /// A certificate with enough names that the server's first flight is
    /// more than three times a client's Initial, so the limit on what it may
    /// send before the address is validated is reached, not merely obeyed.
    nonisolated(unsafe) static let largeConfig: QUICServerConfig = {
        let names = ["localhost"] + (0..<160).map { "name-\($0).localhost.example" }
        let identity = try! TLSIdentity.selfSigned(names: names)
        let key = try! CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
        return QUICServerConfig(certKey: key, alpn: [Array("h3".utf8)])
    }()

    static let nowMs: UInt64 = 1_000

    static func deliver(_ datagram: [UInt8], to server: QUICConnection, nowMs: UInt64 = nowMs) {
        var datagram = datagram
        datagram.withUnsafeMutableBufferPointer { server.receive($0.baseAddress!, $0.count, ecn: 0, nowMs: nowMs) }
    }

    /// Everything the server has to send, as the listener would drain it.
    static func drain(_ server: QUICConnection, nowMs: UInt64 = nowMs) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var buffer = [UInt8](repeating: 0, count: 1500)
        // Bounded: a connection that never stops producing is a finding of
        // its own, not a reason for the fuzzer to hang.
        for _ in 0..<4096 {
            let n = buffer.withUnsafeMutableBufferPointer { server.nextDatagram($0.baseAddress!, $0.count, nowMs: nowMs) }
            if n == 0 { return out }
            out.append(Array(buffer[0..<n]))
        }
        return out
    }

    /// A server for the client's first Initial, made as the listener makes
    /// one: from the IDs in the header.
    static func server(for first: [UInt8], config: QUICServerConfig = config) -> QUICConnection? {
        let header = first.withUnsafeBufferPointer {
            QUICPacket.parseHeader($0.baseAddress!, $0.count, localCIDLength: quicLocalCIDLength)
        }
        guard header.isValid, header.type == .initial else { return nil }
        return QUICConnection(config: config, version: header.version, clientDCID: header.dcid,
                              clientSCID: header.scid, localCID: QUICConnectionID.random(), nowMs: nowMs)
    }

    /// A connection through its handshake, both ends.
    static func connected() throws -> (client: QUICTestPeer, server: QUICConnection) {
        let client = try QUICTestPeer()
        let hello = client.clientHello(serverName: "localhost", alpn: ["h3"])
        let first = try client.packet(.initial, cryptoFrame(offset: 0, hello))
        guard let server = server(for: first) else { throw QUICTestPeerError("no server for the Initial") }
        deliver(first, to: server)
        for datagram in drain(server) { try client.receive(datagram) }
        let finished = try client.packet(.handshake, client.ack(.handshake)
                                         + cryptoFrame(offset: 0, client.finishedMessage))
        deliver(finished, to: server)
        guard server.status == .connected else { throw QUICTestPeerError("the handshake did not complete") }
        for datagram in drain(server) { try client.receive(datagram) }
        _ = server.takeEvents()
        return (client, server)
    }
}

extension Fuzz {

    // MARK: - QUIC frames

    /// The input as the payload of one 1-RTT packet on an established
    /// connection. Whatever the server makes of it, everything it sends back
    /// must be legible to the client -- packets that open under the keys and
    /// frames that parse -- because a server that answers garbage with
    /// garbage has let the input corrupt its own state.
    static func quicFrames(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let client: QUICTestPeer
        let server: QUICConnection
        do {
            (client, server) = try QUICFixture.connected()
        } catch {
            return "no connection to fuzz: \(error)"
        }
        let payload = Array(UnsafeBufferPointer(start: base, count: n))
        // An empty packet is not one a client can send; a PADDING frame is.
        guard let packet = try? client.packet(.application, payload.isEmpty ? [0] : payload) else {
            return "the client could not seal \(n) bytes"
        }
        QUICFixture.deliver(packet, to: server)
        _ = server.takeEvents()
        for datagram in QUICFixture.drain(server) {
            do {
                try client.receive(datagram)
            } catch {
                return "the server answered with what its client cannot read: \(error)"
            }
        }
        // Time passing is the other thing that makes a connection send: a
        // retransmission or an idle close must be as legible as an answer.
        let later = QUICFixture.nowMs + 60_000
        server.onTimeout(nowMs: later)
        for datagram in QUICFixture.drain(server, nowMs: later) {
            do {
                try client.receive(datagram)
            } catch {
                return "after a timeout, the server sent what its client cannot read: \(error)"
            }
        }
        return nil
    }

    // MARK: - ClientHello

    /// The input as a ClientHello, in the CRYPTO frames of a client's first
    /// Initials. The server is not yet sure the client is where it says, so
    /// the one thing it may never do is answer with more than three times
    /// what it was sent (RFC 9000 section 8.1): that is what keeps a forged
    /// source address from turning the server into an amplifier.
    static func tlsHello(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        guard let client = try? QUICTestPeer() else { return "no client" }
        let hello = Array(UnsafeBufferPointer(start: base, count: n))
        // In pieces small enough for one Initial each, as a client splits a
        // hello too large for one datagram.
        var datagrams: [[UInt8]] = []
        var offset = 0
        repeat {
            let end = min(hello.count, offset + 1000)
            guard let packet = try? client.packet(.initial, cryptoFrame(offset: offset, Array(hello[offset..<end]))) else {
                return "the client could not seal a CRYPTO frame"
            }
            datagrams.append(packet)
            offset = end
        } while offset < hello.count
        guard let server = QUICFixture.server(for: datagrams[0], config: QUICFixture.largeConfig) else {
            return "no server for the Initial"
        }
        var received = 0
        var sent = 0
        for datagram in datagrams {
            QUICFixture.deliver(datagram, to: server)
            received += datagram.count
            for answer in QUICFixture.drain(server) {
                sent += answer.count
                if let bad = coalesced(answer) { return bad }
            }
            if sent > 3 * received {
                return "\(sent) bytes sent for \(received) received, before the address was validated"
            }
        }
        // A probe timeout resends what was lost, and is held to the same
        // limit: the client has still proved nothing.
        let later = QUICFixture.nowMs + 1_500
        server.onTimeout(nowMs: later)
        for answer in QUICFixture.drain(server, nowMs: later) {
            sent += answer.count
            if let bad = coalesced(answer) { return bad }
        }
        if sent > 3 * received {
            return "\(sent) bytes sent for \(received) received, counting a retransmission"
        }
        return nil
    }

    /// The packets in a datagram the server sent, end to end, each one
    /// reading from where the last ended.
    private static func coalesced(_ datagram: [UInt8]) -> String? {
        datagram.withUnsafeBufferPointer { buf -> String? in
            var offset = 0
            while offset < buf.count {
                let h = QUICPacket.parseHeader(buf.baseAddress! + offset, buf.count - offset,
                                               localCIDLength: quicLocalCIDLength)
                guard h.isValid, h.end > 0 else {
                    return "the server sent a datagram whose packet at \(offset) does not parse"
                }
                offset += h.end
            }
            return nil
        }
    }
}
