//===----------------------------------------------------------------------===//
// A whole connection, in process: a QUICConnection serving a client written
// here, from the first Initial through the TLS 1.3 handshake to a stream
// carried each way under 1-RTT keys.
//
// GarudaQUIC is server-only, so the client is the test's own: a ClientHello
// built by hand, its key schedule straight from VegaCrypto (HKDF's
// expandLabel, not GarudaQUIC's quicExpandLabel), the server's Finished and
// CertificateVerify checked rather than trusted. Packets are protected with
// GarudaQUIC's QUICProtect, which the RFC vectors cover separately. The
// end-to-end test against an independent client (aioquic) comes with the
// listener.
//===----------------------------------------------------------------------===//

import Testing
import VegaCrypto
import VegaTLS
@testable import GarudaWire
@testable import GarudaQUIC

private func hsBytes(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
    [UInt8](UnsafeBufferPointer(start: p, count: n))
}

private func hsVarint(_ v: UInt64) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 8)
    let n = b.withUnsafeMutableBufferPointer { quicWriteVarint(v, $0.baseAddress!) }
    return Array(b[0..<n])
}

private func hsU16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
private func hsU24(_ v: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

/// #require of a value computed outside the macro, which can't take a
/// mutating call like a reader's.
private func need<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

private func needTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
    try #require(value, sourceLocation: sourceLocation)
}

private func cryptoFrame(offset: Int, _ data: [UInt8]) -> [UInt8] {
    [0x06] + hsVarint(UInt64(offset)) + hsVarint(UInt64(data.count)) + data
}

private func streamFrame(_ id: UInt64, _ data: [UInt8], fin: Bool) -> [UInt8] {
    [UInt8(0x08 | 0x02 | (fin ? 0x01 : 0))] + hsVarint(id) + hsVarint(UInt64(data.count)) + data
}

private func expandLabel(_ secret: [UInt8], _ label: String, _ context: [UInt8] = []) throws -> [UInt8] {
    try HKDF.expandLabel(.sha256, secret: secret, label: label, context: context, length: 32)
}

/// A QUIC v1 client with exactly what this test needs: one cipher suite
/// (TLS_AES_128_GCM_SHA256), X25519, everything delivered in order.
private final class TestClient {
    let originalDCID = QUICConnectionID.random()
    let scid = QUICConnectionID.random()
    var serverCID = QUICConnectionID()
    var keys = [QUICKeyPair](repeating: QUICKeyPair(), count: 3)
    var nextPacketNumber: [UInt64] = [0, 0, 0]
    var largestReceived: [Int64] = [-1, -1, -1]
    var cryptoIn: [[UInt8]] = [[], [], []]
    var cryptoConsumed = [0, 0, 0]

    let kex: KeyExchange
    var transcript: Hash
    var handshakeSecret: [UInt8] = []
    var clientHandshakeSecret: [UInt8] = []
    var serverHandshakeSecret: [UInt8] = []
    var finishedMessage: [UInt8] = []

    var alpn: [UInt8] = []
    var serverParameters: QUICTransportParameters?
    var certificate: [UInt8] = []
    var certificateVerified = false
    var serverFinishedVerified = false
    var handshakeDone = false
    var streams: [UInt64: [UInt8]] = [:]
    var finished: Set<UInt64> = []
    var closeCode: UInt64?

    init() throws {
        kex = try KeyExchange(.x25519)
        transcript = try Hash(.sha256)
        keys[QUICLevel.initial.rawValue] = try #require(
            quicInitialKeys(destinationCID: originalDCID, version: QUICVersion.v1, isServer: false))
    }

    deinit {
        for i in 0..<3 { keys[i].destroy() }
    }

    func clientHello(serverName: String, alpn offered: [String]) -> [UInt8] {
        var extensions: [UInt8] = []
        func add(_ type: Int, _ body: [UInt8]) { extensions += hsU16(type) + hsU16(body.count) + body }

        let name = Array(serverName.utf8)
        add(0, hsU16(name.count + 3) + [0] + hsU16(name.count) + name)                // server_name
        add(10, hsU16(2) + hsU16(0x001d))                                             // supported_groups
        let schemes = [0x0403, 0x0804, 0x0807, 0x0503]
        add(13, hsU16(schemes.count * 2) + schemes.flatMap { hsU16($0) })             // signature_algorithms
        let protocols = offered.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
        add(16, hsU16(protocols.count) + protocols)                                   // ALPN
        add(43, [2, 3, 4])                                                            // supported_versions
        add(51, hsU16(kex.publicKey.count + 4) + hsU16(0x001d) + hsU16(kex.publicKey.count)
                + kex.publicKey)                                                      // key_share

        var parameters = QUICTransportParameters()
        parameters.maxIdleTimeoutMs = 30_000
        parameters.initialMaxData = 1 << 20
        parameters.initialMaxStreamDataBidiLocal = 1 << 18
        parameters.initialMaxStreamDataBidiRemote = 1 << 18
        parameters.initialMaxStreamDataUni = 1 << 18
        parameters.initialMaxStreamsBidi = 100
        parameters.initialMaxStreamsUni = 100
        parameters.initialSourceCID = scid
        parameters.hasInitialSourceCID = true
        var encoded = ByteBuffer()
        defer { encoded.destroy() }
        parameters.encode(into: &encoded, isServer: false)
        add(57, hsBytes(encoded.readPointer, encoded.readableBytes))                  // transport parameters

        var body: [UInt8] = [3, 3] + SecureRandom.bytes(32) + [0]                    // no session ID
        body += hsU16(2) + hsU16(0x1301)
        body += [1, 0]
        body += hsU16(extensions.count) + extensions
        let message = [1] + hsU24(body.count) + body
        transcript.update(message)
        return message
    }

    /// One packet at a level, protected. An Initial is padded to fill a
    /// 1200-byte datagram, as a client's must be.
    func packet(_ level: QUICLevel, _ frames: [UInt8]) throws -> [UInt8] {
        let pn = nextPacketNumber[level.rawValue]
        nextPacketNumber[level.rawValue] += 1
        var header: [UInt8]
        if level == .application {
            header = [0x43]
            serverCID.withBytes { header += hsBytes($0, $1) }
        } else {
            header = [level == .initial ? 0xC3 : 0xE3, 0, 0, 0, 1]
            let dcid = serverCID.isEmpty ? originalDCID : serverCID
            header.append(dcid.length)
            dcid.withBytes { header += hsBytes($0, $1) }
            header.append(scid.length)
            scid.withBytes { header += hsBytes($0, $1) }
            if level == .initial { header.append(0) }                                 // no token
        }
        var payload = frames
        let overhead = header.count + (level == .application ? 0 : 2) + 4 + quicAEADTagLength
        if level == .initial && overhead + payload.count < 1200 {
            payload += [UInt8](repeating: 0, count: 1200 - overhead - payload.count)
        }
        if level != .application {
            let length = 4 + payload.count + quicAEADTagLength
            header += [UInt8(0x40 | (length >> 8)), UInt8(length & 0xFF)]
        }
        let pnOffset = header.count
        var out = header + [0, 0, 0, 0] + payload + [UInt8](repeating: 0, count: quicAEADTagLength)
        let direction = keys[level.rawValue].send
        let sealed = out.withUnsafeMutableBufferPointer { buf in
            QUICProtect.seal(buf.baseAddress!, pnOffset: pnOffset, pnLength: 4, payloadLength: payload.count,
                             packetNumber: pn, keys: direction.keys, header: direction.header)
        }
        #expect(sealed == out.count)
        return out
    }

    /// An ACK of everything received at a level: the server's packets
    /// arrive in order, so one range covers them.
    func ack(_ level: QUICLevel) -> [UInt8] {
        let largest = largestReceived[level.rawValue]
        if largest < 0 { return [] }
        return [0x02] + hsVarint(UInt64(largest)) + hsVarint(0) + hsVarint(0) + hsVarint(UInt64(largest))
    }

    func receive(_ datagram: [UInt8]) throws {
        var datagram = datagram
        try datagram.withUnsafeMutableBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let p = buf.baseAddress! + offset
                let header = QUICPacket.parseHeader(p, buf.count - offset, localCIDLength: Int(scid.length))
                try #require(header.isValid)
                #expect(header.dcid == scid)
                let level: QUICLevel
                switch header.type {
                case .initial: level = .initial
                case .handshake: level = .handshake
                case .oneRTT: level = .application
                default: Issue.record("a server sent a \(header.type) packet"); return
                }
                if level == .initial && serverCID.isEmpty { serverCID = header.scid }
                let direction = keys[level.rawValue].receive
                try #require(direction.isValid, "a packet at a level the client has no keys for")
                let opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                              largestReceived: largestReceived[level.rawValue],
                                              keys: direction.keys, header: direction.header)
                let packet = try #require(opened)
                largestReceived[level.rawValue] = max(largestReceived[level.rawValue], Int64(packet.packetNumber))
                try frames(packet.payload, packet.payloadLength, level)
                offset += header.end
            }
        }
    }

    private func frames(_ p: UnsafePointer<UInt8>, _ n: Int, _ level: QUICLevel) throws {
        var r = QUICReader(p, n)
        while !r.isEmpty {
            let type = try need(r.varint())
            switch type {
            case 0x00, 0x01:
                break
            case 0x02, 0x03:
                _ = try need(quicReadAckFrame(&r, hasECN: type == 0x03) { _, _ in })
            case 0x06:
                let offset = try need(r.varintAsInt())
                let length = try need(r.varintAsInt())
                let data = hsBytes(try need(r.take(length)), length)
                let have = cryptoIn[level.rawValue].count
                try #require(offset <= have, "CRYPTO data out of order")
                if offset + length > have { cryptoIn[level.rawValue] += data[(have - offset)...] }
                try handshakeMessages(level)
            case 0x08...0x0f:
                let id = try need(r.varint())
                let offset = type & 0x04 != 0 ? try need(r.varint()) : 0
                let length = type & 0x02 != 0 ? try need(r.varintAsInt()) : r.remaining
                let data = hsBytes(try need(r.take(length)), length)
                #expect(offset == UInt64(streams[id]?.count ?? 0))
                streams[id, default: []] += data
                if type & 0x01 != 0 { finished.insert(id) }
            case 0x10, 0x12, 0x13:
                _ = try need(r.varint())
            case 0x11:
                _ = try need(r.varint())
                _ = try need(r.varint())
            case 0x18:
                _ = try need(r.varint())
                _ = try need(r.varint())
                let length = try need(r.byte())
                try needTrue(r.skip(Int(length) + 16))
            case 0x1c, 0x1d:
                closeCode = try need(r.varint())
                return
            case 0x1e:
                handshakeDone = true
            default:
                Issue.record("unexpected frame type \(type) at level \(level)")
                return
            }
        }
    }

    private func handshakeMessages(_ level: QUICLevel) throws {
        while true {
            let buffer = cryptoIn[level.rawValue]
            let start = cryptoConsumed[level.rawValue]
            if buffer.count - start < 4 { return }
            let length = Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            if buffer.count - start < 4 + length { return }
            let message = Array(buffer[start..<(start + 4 + length)])
            cryptoConsumed[level.rawValue] += 4 + length
            let body = Array(message[4...])
            switch (level, message[0]) {
            case (.initial, 2): try serverHello(message, body)
            case (.handshake, 8): try encryptedExtensions(body); transcript.update(message)
            case (.handshake, 11): try certificateMessage(body); transcript.update(message)
            case (.handshake, 15): try certificateVerify(body); transcript.update(message)
            case (.handshake, 20): try serverFinished(message, body)
            default: Issue.record("unexpected handshake message \(message[0]) at \(level)")
            }
        }
    }

    private func serverHello(_ message: [UInt8], _ body: [UInt8]) throws {
        var i = 2 + 32
        let sessionID = Int(body[i]); i += 1 + sessionID
        #expect(Int(body[i]) << 8 | Int(body[i + 1]) == 0x1301)
        i += 3
        let extensionsEnd = i + 2 + (Int(body[i]) << 8 | Int(body[i + 1]))
        i += 2
        var peerKey: [UInt8] = []
        var version = 0
        while i < extensionsEnd {
            let type = Int(body[i]) << 8 | Int(body[i + 1])
            let length = Int(body[i + 2]) << 8 | Int(body[i + 3])
            let ext = Array(body[(i + 4)..<(i + 4 + length)])
            if type == 51 {
                #expect(Int(ext[0]) << 8 | Int(ext[1]) == 0x001d)
                peerKey = Array(ext[4...])
            }
            if type == 43 { version = Int(ext[0]) << 8 | Int(ext[1]) }
            i += 4 + length
        }
        #expect(version == 0x0304)
        transcript.update(message)

        let shared = try kex.sharedSecret(with: peerKey)
        let early = HKDF.extract(.sha256, salt: [], inputKeyMaterial: [UInt8](repeating: 0, count: 32))
        let derived = try expandLabel(early, "derived", Hash.sha256([]))
        handshakeSecret = HKDF.extract(.sha256, salt: derived, inputKeyMaterial: shared)
        let hash = transcript.snapshot()
        clientHandshakeSecret = try expandLabel(handshakeSecret, "c hs traffic", hash)
        serverHandshakeSecret = try expandLabel(handshakeSecret, "s hs traffic", hash)
        keys[QUICLevel.handshake.rawValue] = try install(send: clientHandshakeSecret, receive: serverHandshakeSecret)
    }

    private func install(send: [UInt8], receive: [UInt8]) throws -> QUICKeyPair {
        var pair = QUICKeyPair()
        pair.send = try #require(send.withUnsafeBufferPointer {
            quicDirection(secret: $0.baseAddress!, secretLen: 32, cipher: .aes128GCMSHA256, version: QUICVersion.v1)
        })
        pair.receive = try #require(receive.withUnsafeBufferPointer {
            quicDirection(secret: $0.baseAddress!, secretLen: 32, cipher: .aes128GCMSHA256, version: QUICVersion.v1)
        })
        return pair
    }

    private func encryptedExtensions(_ body: [UInt8]) throws {
        var i = 2
        while i < body.count {
            let type = Int(body[i]) << 8 | Int(body[i + 1])
            let length = Int(body[i + 2]) << 8 | Int(body[i + 3])
            let ext = Array(body[(i + 4)..<(i + 4 + length)])
            switch type {
            case 16: alpn = Array(ext[3...])
            case 57:
                serverParameters = ext.withUnsafeBufferPointer {
                    QUICTransportParameters.decode($0.baseAddress!, $0.count, fromServer: true)
                }
                try #require(serverParameters != nil)
            default: break
            }
            i += 4 + length
        }
    }

    private func certificateMessage(_ body: [UInt8]) throws {
        #expect(body[0] == 0)                                       // no request context
        let first = Int(body[4]) << 16 | Int(body[5]) << 8 | Int(body[6])
        certificate = Array(body[7..<(7 + first)])
    }

    private func certificateVerify(_ body: [UInt8]) throws {
        let scheme = UInt16(body[0]) << 8 | UInt16(body[1])
        let length = Int(body[2]) << 8 | Int(body[3])
        let signature = Array(body[4..<(4 + length)])
        let content = [UInt8](repeating: 0x20, count: 64) + Array("TLS 1.3, server CertificateVerify".utf8) + [0]
            + transcript.snapshot()
        let key = try PublicKey(certificateDER: certificate)
        certificateVerified = key.isValidSignature(signature, for: content,
                                                   scheme: TLSSignatureScheme(rawValue: scheme))
    }

    private func serverFinished(_ message: [UInt8], _ body: [UInt8]) throws {
        let finishedKey = try expandLabel(serverHandshakeSecret, "finished")
        serverFinishedVerified = HMAC.authenticationCode(.sha256, key: finishedKey, data: transcript.snapshot()) == body
        transcript.update(message)

        // The 1-RTT secrets come from the transcript through the server's
        // Finished; the client's Finished covers the same.
        let hash = transcript.snapshot()
        let derived = try expandLabel(handshakeSecret, "derived", Hash.sha256([]))
        let master = HKDF.extract(.sha256, salt: derived, inputKeyMaterial: [UInt8](repeating: 0, count: 32))
        let clientApplication = try expandLabel(master, "c ap traffic", hash)
        let serverApplication = try expandLabel(master, "s ap traffic", hash)
        keys[QUICLevel.application.rawValue] = try install(send: clientApplication, receive: serverApplication)

        let clientFinishedKey = try expandLabel(clientHandshakeSecret, "finished")
        let verify = HMAC.authenticationCode(.sha256, key: clientFinishedKey, data: hash)
        finishedMessage = [20] + hsU24(verify.count) + verify
    }
}

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
    let client = try TestClient()
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
    let client = try TestClient()
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
