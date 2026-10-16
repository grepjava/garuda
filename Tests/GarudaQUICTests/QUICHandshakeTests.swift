//===----------------------------------------------------------------------===//
// A whole connection, in process: a QUICConnection serving the tests' own
// client (Tests/QUICTestPeer), from the first Initial through the TLS 1.3
// handshake to a stream carried each way under 1-RTT keys. The end-to-end
// test against an independent client (aioquic) is scripts/http3-test.py.
//===----------------------------------------------------------------------===//

import Testing
import VegaCrypto
import VegaTLS
import QUICTestPeer
@testable import GarudaWire
@testable import GarudaQUIC

private func deliver(_ datagram: [UInt8], to server: QUICConnection, nowMs: UInt64) {
    var datagram = datagram
    datagram.withUnsafeMutableBufferPointer { server.receive($0.baseAddress!, $0.count, ecn: 0, nowMs: nowMs) }
}

/// Everything the server has to send, as the listener would drain it.
private func drain(_ server: QUICConnection, nowMs: UInt64) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var buffer = [UInt8](repeating: 0, count: 1500)
    while true {
        let n = buffer.withUnsafeMutableBufferPointer { server.nextDatagram($0.baseAddress!, $0.count, nowMs: nowMs) }
        if n == 0 { return out }
        out.append(Array(buffer[0..<n]))
    }
}

@Test("a server connection completes a TLS 1.3 handshake with a client and carries a stream each way")
func quicHandshakeAndStream() throws {
    let identity = try TLSIdentity.selfSigned(names: ["localhost"])
    let certificate = try CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
    let config = QUICServerConfig(certKey: certificate, alpn: [Array("h3".utf8)])
    let client = try QUICTestPeer()
    var now: UInt64 = 1_000

    // The client's first flight: a ClientHello in a padded Initial.
    let hello = client.clientHello(serverName: "localhost", alpn: ["h3"])
    let first = try client.packet(.initial, cryptoFrame(offset: 0, hello))
    #expect(first.count == QUICPacket.minimumInitialSize)

    // What the listener does with an Initial for no known connection: read
    // the header for the IDs and make one.
    let header = first.withUnsafeBufferPointer {
        QUICPacket.parseHeader($0.baseAddress!, $0.count, localCIDLength: quicLocalCIDLength)
    }
    #expect(header.isValid && header.type == .initial)
    #expect(header.dcid == client.originalDCID && header.scid == client.scid)
    let localCID = QUICConnectionID.random()
    let server = try #require(QUICConnection(config: config, version: header.version,
                                             clientDCID: header.dcid, clientSCID: header.scid,
                                             localCID: localCID, nowMs: now))
    deliver(first, to: server, nowMs: now)
    #expect(server.acceptedNewPacket)
    #expect(server.tlsAlert == nil)

    // The server's flight: ServerHello in an Initial, the rest in Handshake
    // packets, within three times what the client sent.
    let flight = drain(server, nowMs: now)
    #expect(!flight.isEmpty)
    #expect(flight.reduce(0) { $0 + $1.count } <= 3 * first.count)
    for datagram in flight { try client.receive(datagram) }
    #expect(client.serverCID == localCID)
    #expect(client.certificateVerified)
    #expect(client.serverFinishedVerified)
    #expect(client.alpn == Array("h3".utf8))
    let parameters = try #require(client.serverParameters)
    #expect(parameters.initialSourceCID == localCID)
    #expect(parameters.originalDestinationCID == client.originalDCID)
    #expect(client.closeCode == nil)
    #expect(server.status == .handshaking)

    // The client's Finished completes it.
    now += 10
    let finished = try client.packet(.handshake, client.ack(.handshake)
                                      + cryptoFrame(offset: 0, client.finishedMessage))
    deliver(finished, to: server, nowMs: now)
    #expect(server.tlsAlert == nil)
    #expect(server.status == .connected)
    #expect(server.handshakeComplete)
    #expect(server.selectedALPN == Array("h3".utf8))
    #expect(server.serverName == Array("localhost".utf8))
    let events = server.takeEvents()
    #expect(events.contains { $0.kind == .handshakeComplete })

    // A request on stream 0 under the 1-RTT keys.
    now += 10
    let request = try client.packet(.application, client.ack(.application)
                                    + streamFrame(0, Array("hello".utf8), fin: true))
    deliver(request, to: server, nowMs: now)
    let streamEvents = server.takeEvents()
    #expect(streamEvents.contains { $0.kind == .streamReadable && $0.streamID == 0 })
    #expect(streamEvents.contains { $0.kind == .streamFinished && $0.streamID == 0 })
    let stream = try #require(server.stream(0))
    #expect(hsBytes(stream.receive.ready.readPointer, stream.receive.ready.readableBytes) == Array("hello".utf8))
    #expect(stream.receive.finished)

    // And the answer, with HANDSHAKE_DONE ahead of it.
    let answer = Array("world".utf8)
    answer.withUnsafeBufferPointer { server.send(0, $0.baseAddress!, $0.count, fin: true) }
    for datagram in drain(server, nowMs: now) { try client.receive(datagram) }
    #expect(client.handshakeDone)
    #expect(client.streams[0] == answer)
    #expect(client.finished.contains(0))
    #expect(client.closeCode == nil)

    // A close goes out as a CONNECTION_CLOSE the client can read.
    server.close(0x100, application: true)
    for datagram in drain(server, nowMs: now + 1) { try client.receive(datagram) }
    #expect(client.closeCode == 0x100)
}

@Test("a ClientHello offering no cipher suite the server has fails with handshake_failure")
func quicHandshakeRefusesUnknownSuite() throws {
    let identity = try TLSIdentity.selfSigned(names: ["localhost"])
    let certificate = try CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
    let client = try QUICTestPeer()
    var hello = client.clientHello(serverName: "localhost", alpn: ["h3"])
    // The one suite offered, 0x1301, becomes 0x13ff.
    let suite = try #require((0..<(hello.count - 1)).first { hello[$0] == 0x13 && hello[$0 + 1] == 0x01 })
    hello[suite + 1] = 0xff
    let first = try client.packet(.initial, cryptoFrame(offset: 0, hello))
    let server = try #require(QUICConnection(config: QUICServerConfig(certKey: certificate, alpn: [Array("h3".utf8)]),
                                             version: QUICVersion.v1, clientDCID: client.originalDCID,
                                             clientSCID: client.scid, localCID: QUICConnectionID.random(),
                                             nowMs: 0))
    deliver(first, to: server, nowMs: 0)
    #expect(server.tlsAlert == TLSAlert.handshakeFailure)
    #expect(server.status == .closing)
    #expect(server.closeError == quicCryptoError(TLSAlert.handshakeFailure))
}

@Test("frames for a stream the server has retired are ignored, and the packets carrying them still count")
func quicRetiredStreamFramesAreIgnored() throws {
    let identity = try TLSIdentity.selfSigned(names: ["localhost"])
    let certificate = try CertificateKey(chainPEM: identity.certificateChain, keyPEM: identity.privateKey)
    let config = QUICServerConfig(certKey: certificate, alpn: [Array("h3".utf8)])
    let client = try QUICTestPeer()
    var now: UInt64 = 1_000
    let first = try client.packet(.initial, cryptoFrame(offset: 0, client.clientHello(serverName: "localhost",
                                                                                      alpn: ["h3"])))
    let header = first.withUnsafeBufferPointer {
        QUICPacket.parseHeader($0.baseAddress!, $0.count, localCIDLength: quicLocalCIDLength)
    }
    let server = try #require(QUICConnection(config: config, version: header.version,
                                             clientDCID: header.dcid, clientSCID: header.scid,
                                             localCID: QUICConnectionID.random(), nowMs: now))
    deliver(first, to: server, nowMs: now)
    for datagram in drain(server, nowMs: now) { try client.receive(datagram) }
    now += 10
    deliver(try client.finishedPacket(), to: server, nowMs: now)
    #expect(server.status == .connected)
    _ = server.takeEvents()

    // Stream 0 asked and answered, the answer acknowledged, and the stream
    // let go of: the server forgets it.
    now += 10
    deliver(try client.packet(.application, client.ack(.application) + streamFrame(0, [1, 2, 3], fin: true)),
            to: server, nowMs: now)
    [UInt8](repeating: 4, count: 3).withUnsafeBufferPointer { server.send(0, $0.baseAddress!, $0.count, fin: true) }
    for datagram in drain(server, nowMs: now) { try client.receive(datagram) }
    #expect(client.finished.contains(0))
    now += 10
    deliver(try client.packet(.application, client.ack(.application)), to: server, nowMs: now)
    server.releaseStream(0)
    #expect(server.stream(0) == nil)
    _ = server.takeEvents()

    // The client, not having heard its packets were acknowledged, sends
    // stream 0's bytes again, and resets it, beside a new request each time.
    // Neither old frame may cost the packet it shares.
    for (old, id) in [(streamFrame(0, [1, 2, 3], fin: true), UInt64(4)),
                      (resetStreamFrame(0, code: 0x10c, finalSize: 3), UInt64(8))] {
        now += 10
        deliver(try client.packet(.application, old + streamFrame(id, [5], fin: true)), to: server, nowMs: now)
        #expect(server.status == .connected)
        #expect(server.acceptedNewPacket, "the packet with a frame for a retired stream is taken")
        #expect(server.takeEvents().contains { $0.kind == .streamReadable && $0.streamID == id })
    }
}
