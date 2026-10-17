//===----------------------------------------------------------------------===//
// A QUIC v1 client with exactly what the tests need, for VegaQUICTests and
// the servers built on VegaQUIC alike.
//
// VegaQUIC is server-only, so the client is the tests' own: a ClientHello
// built by hand, its key schedule straight from VegaCrypto (HKDF's
// expandLabel, not VegaQUIC's quicExpandLabel), the server's Finished and
// CertificateVerify checked rather than trusted. Packets are protected with
// VegaQUIC's QUICProtect, which the RFC vectors cover separately. One cipher
// suite (TLS_AES_128_GCM_SHA256), X25519, and a path that loses nothing: what
// arrives out of order is not reordered, only what repeats is skipped.
//
// It reports what is wrong by throwing rather than through a test library, so
// it can be an ordinary target.
//===----------------------------------------------------------------------===//

import VegaQUIC
import VegaWire
import VegaCrypto
import VegaTLS

/// What the peer found wrong with what the server sent.
public struct QUICTestPeerError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func need<T>(_ value: T?, _ what: @autoclosure () -> String) throws -> T {
    guard let value else { throw QUICTestPeerError(what()) }
    return value
}

func needTrue(_ value: Bool, _ what: @autoclosure () -> String) throws {
    if !value { throw QUICTestPeerError(what()) }
}

public func hsBytes(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
    [UInt8](UnsafeBufferPointer(start: p, count: n))
}

public func hsVarint(_ v: UInt64) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 8)
    let n = b.withUnsafeMutableBufferPointer { quicWriteVarint(v, $0.baseAddress!) }
    return Array(b[0..<n])
}

public func hsU16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
public func hsU24(_ v: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

public func cryptoFrame(offset: Int, _ data: [UInt8]) -> [UInt8] {
    [0x06] + hsVarint(UInt64(offset)) + hsVarint(UInt64(data.count)) + data
}

/// A STREAM frame with an offset and a length.
public func streamFrame(_ id: UInt64, offset: Int = 0, _ data: [UInt8], fin: Bool) -> [UInt8] {
    [UInt8(0x08 | 0x04 | 0x02 | (fin ? 0x01 : 0))] + hsVarint(id) + hsVarint(UInt64(offset))
        + hsVarint(UInt64(data.count)) + data
}

/// A RESET_STREAM frame.
public func resetStreamFrame(_ id: UInt64, code: UInt64, finalSize: Int) -> [UInt8] {
    [0x04] + hsVarint(id) + hsVarint(code) + hsVarint(UInt64(finalSize))
}

private func expandLabel(_ secret: [UInt8], _ label: String, _ context: [UInt8] = []) throws -> [UInt8] {
    try HKDF.expandLabel(.sha256, secret: secret, label: label, context: context, length: 32)
}

public final class QUICTestPeer {
    public let originalDCID: QUICConnectionID
    public let scid = QUICConnectionID.random()
    public var serverCID = QUICConnectionID()
    public var keys = [QUICKeyPair](repeating: QUICKeyPair(), count: 3)
    public var nextPacketNumber: [UInt64] = [0, 0, 0]
    public var largestReceived: [Int64] = [-1, -1, -1]
    var cryptoIn: [[UInt8]] = [[], [], []]
    var cryptoConsumed = [0, 0, 0]

    let kex: KeyExchange
    var transcript: Hash
    var handshakeSecret: [UInt8] = []
    var clientHandshakeSecret: [UInt8] = []
    var serverHandshakeSecret: [UInt8] = []
    public private(set) var finishedMessage: [UInt8] = []

    public private(set) var alpn: [UInt8] = []
    public private(set) var serverParameters: QUICTransportParameters?
    public private(set) var certificate: [UInt8] = []
    public private(set) var certificateVerified = false
    public private(set) var serverFinishedVerified = false
    public private(set) var handshakeDone = false
    /// What each stream carried from the server, in order.
    public var streams: [UInt64: [UInt8]] = [:]
    /// Streams the server finished.
    public var finished: Set<UInt64> = []
    /// Streams the server reset, with the code.
    public var resets: [UInt64: UInt64] = [:]
    /// Streams the server asked to stop sending on, with the code.
    public var stopSending: [UInt64: UInt64] = [:]
    public private(set) var closeCode: UInt64?
    /// The data of each PATH_CHALLENGE and PATH_RESPONSE the server sent.
    public var pathChallenges: [[UInt8]] = []
    public var pathResponses: [[UInt8]] = []
    /// The highest MAX_STREAMS (bidirectional) the server sent.
    public private(set) var maxStreamsBidi: UInt64 = 0
    /// The datagrams the server sent (RFC 9221), in order.
    public var datagrams: [[UInt8]] = []
    /// The largest DATAGRAM frame offered to the server; 0 offers none.
    public var maxDatagramFrameSize: UInt64 = 0

    /// `dcidLength`: how long the identifier the client invents for the
    /// server is, which RFC 9000 says must be at least eight bytes.
    public init(dcidLength: Int = 8) throws {
        originalDCID = QUICConnectionID.random(length: dcidLength)
        kex = try KeyExchange(.x25519)
        transcript = try Hash(.sha256)
        keys[QUICLevel.initial.rawValue] = try need(
            quicInitialKeys(destinationCID: originalDCID, version: QUICVersion.v1, isServer: false),
            "no Initial keys")
    }

    deinit {
        for i in 0..<3 { keys[i].destroy() }
    }

    /// A ClientHello offering `alpn`, with transport parameters that allow
    /// the server what it needs.
    public func clientHello(serverName: String, alpn offered: [String]) -> [UInt8] {
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
        parameters.maxDatagramFrameSize = maxDatagramFrameSize
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
    /// 1200-byte datagram, as a client's must be, unless `padded` is false.
    public func packet(_ level: QUICLevel, _ frames: [UInt8], padded: Bool = true) throws -> [UInt8] {
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
        if padded && level == .initial && overhead + payload.count < 1200 {
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
        try needTrue(sealed == out.count, "sealing a packet produced \(String(describing: sealed)) bytes")
        return out
    }

    /// An ACK of everything received at a level, in one range: what arrives
    /// on a path that loses nothing.
    public func ack(_ level: QUICLevel) -> [UInt8] {
        let largest = largestReceived[level.rawValue]
        if largest < 0 { return [] }
        return [0x02] + hsVarint(UInt64(largest)) + hsVarint(0) + hsVarint(0) + hsVarint(UInt64(largest))
    }

    /// The client's Finished, with an ACK of the server's Handshake packets.
    public func finishedPacket() throws -> [UInt8] {
        try packet(.handshake, ack(.handshake) + cryptoFrame(offset: 0, finishedMessage))
    }

    /// Whether the server's whole first flight has arrived.
    public var handshakeReceived: Bool { !finishedMessage.isEmpty }

    /// Takes one datagram from the server.
    public func receive(_ datagram: [UInt8]) throws {
        var datagram = datagram
        try datagram.withUnsafeMutableBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let p = buf.baseAddress! + offset
                let header = QUICPacket.parseHeader(p, buf.count - offset, localCIDLength: Int(scid.length))
                try needTrue(header.isValid, "a packet that does not parse")
                try needTrue(header.dcid == scid, "a packet for another connection ID")
                let level: QUICLevel
                switch header.type {
                case .initial: level = .initial
                case .handshake: level = .handshake
                case .oneRTT: level = .application
                default: throw QUICTestPeerError("a server sent a \(header.type) packet")
                }
                if level == .initial && serverCID.isEmpty { serverCID = header.scid }
                let direction = keys[level.rawValue].receive
                try needTrue(direction.isValid, "a packet at a level the client has no keys for")
                let opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                              largestReceived: largestReceived[level.rawValue],
                                              keys: direction.keys, header: direction.header)
                let packet = try need(opened, "a packet that does not open")
                largestReceived[level.rawValue] = max(largestReceived[level.rawValue], Int64(packet.packetNumber))
                try frames(packet.payload, packet.payloadLength, level)
                offset += header.end
            }
        }
    }

    private func frames(_ p: UnsafePointer<UInt8>, _ n: Int, _ level: QUICLevel) throws {
        var r = QUICReader(p, n)
        while !r.isEmpty {
            let type = try need(r.varint(), "a frame type")
            switch type {
            case 0x00, 0x01:
                break
            case 0x02, 0x03:
                _ = try need(quicReadAckFrame(&r, hasECN: type == 0x03) { _, _ in }, "an ACK frame")
            case 0x04:
                let id = try need(r.varint(), "RESET_STREAM")
                resets[id] = try need(r.varint(), "RESET_STREAM")
                _ = try need(r.varint(), "RESET_STREAM")
            case 0x05:
                let id = try need(r.varint(), "STOP_SENDING")
                stopSending[id] = try need(r.varint(), "STOP_SENDING")
            case 0x06:
                let offset = try need(r.varintAsInt(), "CRYPTO")
                let length = try need(r.varintAsInt(), "CRYPTO")
                let data = hsBytes(try need(r.take(length), "CRYPTO"), length)
                let have = cryptoIn[level.rawValue].count
                try needTrue(offset <= have, "CRYPTO data out of order")
                if offset + length > have { cryptoIn[level.rawValue] += data[(have - offset)...] }
                try handshakeMessages(level)
            case 0x08...0x0f:
                let id = try need(r.varint(), "STREAM")
                let offset = type & 0x04 != 0 ? try need(r.varintAsInt(), "STREAM") : 0
                let length = type & 0x02 != 0 ? try need(r.varintAsInt(), "STREAM") : r.remaining
                let data = hsBytes(try need(r.take(length), "STREAM"), length)
                let have = streams[id]?.count ?? 0
                // A repeat is skipped; a path that loses nothing reorders
                // nothing.
                try needTrue(offset <= have, "STREAM data out of order on \(id)")
                if offset + length > have { streams[id, default: []] += data[(have - offset)...] }
                if type & 0x01 != 0 { finished.insert(id) }
            case 0x10, 0x13, 0x14, 0x16, 0x17:
                _ = try need(r.varint(), "a one-varint frame")
            case 0x12:
                maxStreamsBidi = max(maxStreamsBidi, try need(r.varint(), "MAX_STREAMS"))
            case 0x11, 0x15:
                _ = try need(r.varint(), "a two-varint frame")
                _ = try need(r.varint(), "a two-varint frame")
            case 0x18:
                _ = try need(r.varint(), "NEW_CONNECTION_ID")
                _ = try need(r.varint(), "NEW_CONNECTION_ID")
                let length = try need(r.byte(), "NEW_CONNECTION_ID")
                try needTrue(r.skip(Int(length) + 16), "NEW_CONNECTION_ID")
            case 0x1a:
                pathChallenges.append(hsBytes(try need(r.take(8), "PATH_CHALLENGE"), 8))
            case 0x1b:
                pathResponses.append(hsBytes(try need(r.take(8), "PATH_RESPONSE"), 8))
            case 0x1c, 0x1d:
                closeCode = try need(r.varint(), "CONNECTION_CLOSE")
                return
            case 0x1e:
                handshakeDone = true
            case 0x30, 0x31:
                let length = type == 0x31 ? try need(r.varintAsInt(), "DATAGRAM") : r.remaining
                datagrams.append(hsBytes(try need(r.take(length), "DATAGRAM"), length))
            default:
                throw QUICTestPeerError("unexpected frame type \(type) at level \(level)")
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
            default: throw QUICTestPeerError("unexpected handshake message \(message[0]) at \(level)")
            }
        }
    }

    private func serverHello(_ message: [UInt8], _ body: [UInt8]) throws {
        var i = 2 + 32
        let sessionID = Int(body[i]); i += 1 + sessionID
        try needTrue(Int(body[i]) << 8 | Int(body[i + 1]) == 0x1301, "a cipher suite not offered")
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
                try needTrue(Int(ext[0]) << 8 | Int(ext[1]) == 0x001d, "a group not offered")
                peerKey = Array(ext[4...])
            }
            if type == 43 { version = Int(ext[0]) << 8 | Int(ext[1]) }
            i += 4 + length
        }
        try needTrue(version == 0x0304, "not TLS 1.3")
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
        pair.send = try need(send.withUnsafeBufferPointer {
            quicDirection(secret: $0.baseAddress!, secretLen: 32, cipher: .aes128GCMSHA256, version: QUICVersion.v1)
        }, "send keys")
        pair.receive = try need(receive.withUnsafeBufferPointer {
            quicDirection(secret: $0.baseAddress!, secretLen: 32, cipher: .aes128GCMSHA256, version: QUICVersion.v1)
        }, "receive keys")
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
                try needTrue(serverParameters != nil, "transport parameters that do not decode")
            default: break
            }
            i += 4 + length
        }
    }

    private func certificateMessage(_ body: [UInt8]) throws {
        try needTrue(body[0] == 0, "a certificate request context")
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
