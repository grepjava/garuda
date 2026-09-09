//===----------------------------------------------------------------------===//
// TLS 1.3, server side, for QUIC.
//
// This is the handshake without the record layer. QUIC carries handshake bytes
// in CRYPTO frames and derives its own packet protection from the traffic
// secrets, so what is needed from TLS is exactly three things: a negotiated
// cipher suite, a set of secrets at each encryption level, and proof that the
// peer is talking to the certificate we hold. OpenSSL's SSL_* API cannot give
// that -- it owns the records -- so the message flow is written out here on top
// of the primitives.
//
// Only what QUIC permits is implemented, which is less than it sounds: TLS 1.3
// exactly, no compression, no renegotiation, no session resumption or 0-RTT, no
// client certificates. A client offering only groups we do not have is refused
// rather than sent a HelloRetryRequest; every deployed client offers X25519.
//
// The transcript is the spine of the whole thing. Every message is hashed in
// the order it appears on the wire, and the hash at particular moments is what
// keys, the signature and the Finished values are derived from -- which is what
// makes tampering with any earlier message show up as a handshake failure
// rather than as something subtler later.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum TLSAlert {
    public static let closeNotify: UInt8 = 0
    public static let unexpectedMessage: UInt8 = 10
    public static let handshakeFailure: UInt8 = 40
    public static let illegalParameter: UInt8 = 47
    public static let decodeError: UInt8 = 50
    public static let decryptError: UInt8 = 51
    public static let protocolVersion: UInt8 = 70
    public static let internalError: UInt8 = 80
    public static let missingExtension: UInt8 = 109
    public static let unsupportedExtension: UInt8 = 110
    public static let noApplicationProtocol: UInt8 = 120
}

private enum HandshakeType {
    static let clientHello: UInt8 = 1
    static let serverHello: UInt8 = 2
    static let newSessionTicket: UInt8 = 4
    static let encryptedExtensions: UInt8 = 8
    static let certificate: UInt8 = 11
    static let certificateVerify: UInt8 = 15
    static let finished: UInt8 = 20
}

private enum ExtensionType {
    static let serverName: UInt16 = 0
    static let supportedGroups: UInt16 = 10
    static let signatureAlgorithms: UInt16 = 13
    static let alpn: UInt16 = 16
    static let supportedVersions: UInt16 = 43
    static let keyShare: UInt16 = 51
    static let quicTransportParameters: UInt16 = 57
}

private enum NamedGroup {
    static let x25519: UInt16 = 0x001d
    static let secp256r1: UInt16 = 0x0017
}

// MARK: - Length-prefixed writing

extension ByteBuffer {
    /// Reserves a length field and returns where it went, so the value can be
    /// filled in once its contents exist.
    @inline(__always)
    mutating func openLength(_ width: Int) -> Int {
        let offset = writerOffset
        for _ in 0..<width { writeByte(0) }
        return offset
    }

    @inline(__always)
    mutating func closeLength(_ offset: Int, _ width: Int) {
        let length = writerOffset - offset - width
        let p = pointer(at: offset)
        var i = 0
        while i < width {
            p[i] = UInt8(truncatingIfNeeded: length >> (8 * (width - 1 - i)))
            i += 1
        }
    }
}

// MARK: - The handshake

public final class TLSServerHandshake {
    public enum State {
        case waitingClientHello
        case waitingFinished
        case complete
        case failed
    }

    /// A traffic secret pair the connection should turn into packet keys.
    public struct Secrets {
        public var level: QUICLevel
        public var client: [UInt8]
        public var server: [UInt8]
        public var cipher: QUICCipher
    }

    // Configuration.
    private let certKey: OpaquePointer          // pg_certkey, owned by the caller
    private let alpnPreference: [[UInt8]]
    private var localParameters: QUICTransportParameters
    private let quicVersion: UInt32

    // Negotiated.
    public private(set) var state: State = .waitingClientHello
    public private(set) var alert: UInt8?
    public private(set) var cipher: QUICCipher = .aes128GCMSHA256
    public private(set) var selectedALPN: [UInt8] = []
    public private(set) var serverName: [UInt8] = []
    public private(set) var peerParameters = QUICTransportParameters()
    public private(set) var sawTransportParameters = false

    // Output, per encryption level. The connection drains these into CRYPTO
    // frames.
    public var initialOut = ByteBuffer()
    public var handshakeOut = ByteBuffer()
    /// Secrets waiting to be installed, in the order they become usable.
    public private(set) var pendingSecrets: [Secrets] = []

    // Working state.
    private var transcript: OpaquePointer?      // pg_hash_ctx
    private var kex: OpaquePointer?             // pg_kex
    private var handshakeSecret: [UInt8] = []
    private var clientHandshakeSecret: [UInt8] = []
    private var serverHandshakeSecret: [UInt8] = []
    private var incoming = [ByteBuffer](repeating: ByteBuffer(), count: 3)

    public init(certKey: OpaquePointer, alpn: [[UInt8]],
                parameters: QUICTransportParameters, version: UInt32) {
        self.certKey = certKey
        self.alpnPreference = alpn
        self.localParameters = parameters
        self.quicVersion = version
    }

    deinit {
        if let transcript { pg_hash_free(transcript) }
        if let kex { pg_kex_free(kex) }
        for i in 0..<incoming.count { incoming[i].destroy() }
        initialOut.destroy()
        handshakeOut.destroy()
        scrubSecrets()
    }

    private func scrubSecrets() {
        for i in 0..<handshakeSecret.count { handshakeSecret[i] = 0 }
        for i in 0..<clientHandshakeSecret.count { clientHandshakeSecret[i] = 0 }
        for i in 0..<serverHandshakeSecret.count { serverHandshakeSecret[i] = 0 }
    }

    public func takePendingSecrets() -> [Secrets] {
        let out = pendingSecrets
        pendingSecrets.removeAll(keepingCapacity: true)
        return out
    }

    private func fail(_ code: UInt8) {
        if alert == nil { alert = code }
        state = .failed
    }

    // MARK: Input

    /// Hands the handshake a run of contiguous CRYPTO bytes at one level.
    /// Ordering and gaps are the connection's problem; by the time bytes get
    /// here they are in sequence.
    public func receive(_ p: UnsafePointer<UInt8>, _ n: Int, level: QUICLevel) {
        if state == .failed || state == .complete { return }
        incoming[level.rawValue].write(p, n)
        processMessages(level: level)
    }

    private func processMessages(level: QUICLevel) {
        while state != .failed {
            let available = incoming[level.rawValue].readableBytes
            if available < 4 { return }
            let head = incoming[level.rawValue].readPointer
            let type = head[0]
            let length = (Int(head[1]) << 16) | (Int(head[2]) << 8) | Int(head[3])
            if available < 4 + length { return }

            // A handshake message is hashed exactly as it appeared, header and
            // all -- except the ClientHello, which cannot be hashed until its
            // cipher suite has chosen the hash.
            let message = head
            let total = 4 + length
            switch type {
            case HandshakeType.clientHello:
                if state != .waitingClientHello { fail(TLSAlert.unexpectedMessage); return }
                handleClientHello(message, total)
            case HandshakeType.finished:
                if state != .waitingFinished { fail(TLSAlert.unexpectedMessage); return }
                handleFinished(message, total)
            case HandshakeType.newSessionTicket, HandshakeType.certificate,
                 HandshakeType.certificateVerify:
                // Messages only a client sends, or only a server sends.
                fail(TLSAlert.unexpectedMessage)
                return
            default:
                fail(TLSAlert.unexpectedMessage)
                return
            }
            incoming[level.rawValue].consume(total)
        }
    }

    // MARK: ClientHello

    private func handleClientHello(_ message: UnsafePointer<UInt8>, _ total: Int) {
        var r = QUICReader(message, total)
        _ = r.skip(4)                                   // handshake header
        guard let legacyVersion = r.uint16() else { return fail(TLSAlert.decodeError) }
        _ = legacyVersion                                // 0x0303, and meaningless in 1.3
        guard let random = r.take(32) else { return fail(TLSAlert.decodeError) }
        _ = random
        guard let sessionIDLength = r.byte(), sessionIDLength <= 32,
              let sessionID = r.take(Int(sessionIDLength))
        else { return fail(TLSAlert.decodeError) }
        let sessionIDEcho = [UInt8](UnsafeBufferPointer(start: sessionID,
                                                        count: Int(sessionIDLength)))

        guard let suitesLength = r.uint16(), suitesLength % 2 == 0,
              let suites = r.take(Int(suitesLength))
        else { return fail(TLSAlert.decodeError) }

        guard let compressionLength = r.byte(), compressionLength >= 1,
              let compression = r.take(Int(compressionLength))
        else { return fail(TLSAlert.decodeError) }
        // TLS 1.3 forbids compression, and a client that offers any is either
        // very old or trying something.
        var onlyNull = true
        for i in 0..<Int(compressionLength) where compression[i] != 0 { onlyNull = false }
        if !onlyNull { return fail(TLSAlert.illegalParameter) }

        guard let extensionsLength = r.uint16(),
              let extensions = r.take(Int(extensionsLength))
        else { return fail(TLSAlert.decodeError) }

        // --- Extensions -------------------------------------------------
        var offeredVersions13 = false
        var peerKeyShare: (group: UInt16, key: UnsafePointer<UInt8>, length: Int)?
        var signatureSchemes: [UInt16] = []
        var alpnOffers: [[UInt8]] = []
        var transportParametersSeen = false

        var e = QUICReader(extensions, Int(extensionsLength))
        while !e.isEmpty {
            guard let extType = e.uint16(), let extLength = e.uint16(),
                  let body = e.take(Int(extLength))
            else { return fail(TLSAlert.decodeError) }
            var b = QUICReader(body, Int(extLength))

            switch extType {
            case ExtensionType.supportedVersions:
                guard let listLength = b.byte(), listLength % 2 == 0 else {
                    return fail(TLSAlert.decodeError)
                }
                var i = 0
                while i < Int(listLength) {
                    guard let v = b.uint16() else { return fail(TLSAlert.decodeError) }
                    if v == 0x0304 { offeredVersions13 = true }
                    i += 2
                }

            case ExtensionType.keyShare:
                guard let sharesLength = b.uint16(), let shares = b.take(Int(sharesLength))
                else { return fail(TLSAlert.decodeError) }
                var s = QUICReader(shares, Int(sharesLength))
                while !s.isEmpty {
                    guard let group = s.uint16(), let keyLength = s.uint16(),
                          let key = s.take(Int(keyLength))
                    else { return fail(TLSAlert.decodeError) }
                    // First acceptable share wins, in the client's order --
                    // it put its preferred group first and there is nothing
                    // to gain by overruling it.
                    if peerKeyShare == nil
                        && (group == NamedGroup.x25519 || group == NamedGroup.secp256r1) {
                        peerKeyShare = (group, key, Int(keyLength))
                    }
                }

            case ExtensionType.signatureAlgorithms:
                guard let listLength = b.uint16(), listLength % 2 == 0,
                      let list = b.take(Int(listLength))
                else { return fail(TLSAlert.decodeError) }
                var s = QUICReader(list, Int(listLength))
                while let scheme = s.uint16() { signatureSchemes.append(scheme) }

            case ExtensionType.alpn:
                guard let listLength = b.uint16(), let list = b.take(Int(listLength))
                else { return fail(TLSAlert.decodeError) }
                var s = QUICReader(list, Int(listLength))
                while !s.isEmpty {
                    guard let nameLength = s.byte(), nameLength > 0,
                          let name = s.take(Int(nameLength))
                    else { return fail(TLSAlert.decodeError) }
                    alpnOffers.append([UInt8](UnsafeBufferPointer(start: name,
                                                                  count: Int(nameLength))))
                }

            case ExtensionType.serverName:
                guard let listLength = b.uint16(), let list = b.take(Int(listLength))
                else { return fail(TLSAlert.decodeError) }
                var s = QUICReader(list, Int(listLength))
                if let nameType = s.byte(), nameType == 0,
                   let nameLength = s.uint16(), let name = s.take(Int(nameLength)) {
                    serverName = [UInt8](UnsafeBufferPointer(start: name, count: Int(nameLength)))
                }

            case ExtensionType.quicTransportParameters:
                guard let parsed = QUICTransportParameters.decode(body, Int(extLength),
                                                                  fromServer: false)
                else { return fail(TLSAlert.illegalParameter) }
                peerParameters = parsed
                transportParametersSeen = true

            default:
                break
            }
        }

        if !offeredVersions13 { return fail(TLSAlert.protocolVersion) }
        // QUIC makes the transport parameters mandatory: without them there is
        // no agreement on flow control at all.
        if !transportParametersSeen { return fail(TLSAlert.missingExtension) }
        sawTransportParameters = true

        guard let chosenSuite = chooseCipherSuite(suites, Int(suitesLength)) else {
            return fail(TLSAlert.handshakeFailure)
        }
        cipher = chosenSuite

        guard let share = peerKeyShare else {
            // No HelloRetryRequest: see the note at the top of the file.
            return fail(TLSAlert.handshakeFailure)
        }
        guard let scheme = chooseSignatureScheme(signatureSchemes) else {
            return fail(TLSAlert.handshakeFailure)
        }
        if !alpnOffers.isEmpty {
            guard let chosen = chooseALPN(alpnOffers) else {
                return fail(TLSAlert.noApplicationProtocol)
            }
            selectedALPN = chosen
        }

        // The transcript can start now that the hash is known.
        transcript = pg_hash_new(cipher.hash)
        if transcript == nil { return fail(TLSAlert.internalError) }
        pg_hash_update(transcript, message, total)

        guard let shared = agree(group: share.group, peer: share.key, length: share.length) else {
            return fail(TLSAlert.handshakeFailure)
        }
        var sharedSecret = shared
        defer { quicScrub(&sharedSecret) }

        writeServerHello(sessionIDEcho: sessionIDEcho, group: share.group)
        if state == .failed { return }
        if !deriveHandshakeSecrets(sharedSecret) { return fail(TLSAlert.internalError) }
        if !writeServerFlight(scheme: scheme) { return }
        if !deriveApplicationSecrets() { return fail(TLSAlert.internalError) }
        state = .waitingFinished
    }

    private func chooseCipherSuite(_ suites: UnsafePointer<UInt8>, _ length: Int) -> QUICCipher? {
        // Server preference: AES-128 first because it is what hardware
        // acceleration is universally present for, ChaCha20 for machines
        // without it, AES-256 only if a client insists.
        let preference: [QUICCipher] = [.aes128GCMSHA256, .chacha20Poly1305SHA256, .aes256GCMSHA384]
        for candidate in preference {
            var i = 0
            while i + 1 < length {
                let value = (UInt16(suites[i]) << 8) | UInt16(suites[i + 1])
                if value == candidate.rawValue { return candidate }
                i += 2
            }
        }
        return nil
    }

    private func chooseSignatureScheme(_ offered: [UInt16]) -> UInt16? {
        var mine = [UInt16](repeating: 0, count: 8)
        let n = mine.withUnsafeMutableBufferPointer {
            Int(pg_certkey_schemes(certKey, $0.baseAddress, 8))
        }
        if n == 0 { return nil }
        for i in 0..<n where offered.contains(mine[i]) { return mine[i] }
        return nil
    }

    private func chooseALPN(_ offered: [[UInt8]]) -> [UInt8]? {
        // Server preference, not the client's: which application protocol runs
        // is the server's decision.
        for candidate in alpnPreference where offered.contains(candidate) { return candidate }
        return nil
    }

    private func agree(group: UInt16, peer: UnsafePointer<UInt8>, length: Int) -> [UInt8]? {
        let kexGroup = group == NamedGroup.x25519 ? PG_KEX_X25519 : PG_KEX_P256
        guard let k = pg_kex_new(Int32(kexGroup)) else { return nil }
        kex = k
        var shared = [UInt8](repeating: 0, count: 64)
        let n = shared.withUnsafeMutableBufferPointer {
            Int(pg_kex_derive(k, peer, length, $0.baseAddress, $0.count))
        }
        if n <= 0 { return nil }
        shared.removeLast(shared.count - n)
        return shared
    }

    // MARK: ServerHello

    private func writeServerHello(sessionIDEcho: [UInt8], group: UInt16) {
        var message = ByteBuffer(capacity: 256)
        defer { message.destroy() }

        message.writeByte(HandshakeType.serverHello)
        let bodyLength = message.openLength(3)
        message.writeUInt16BE(0x0303)                    // legacy_version

        var random = [UInt8](repeating: 0, count: 32)
        let ok = random.withUnsafeMutableBufferPointer {
            pg_random_bytes($0.baseAddress, 32) == 0
        }
        if !ok { return fail(TLSAlert.internalError) }
        random.withUnsafeBufferPointer { message.write($0.baseAddress!, 32) }

        message.writeByte(UInt8(sessionIDEcho.count))
        sessionIDEcho.withUnsafeBufferPointer {
            if $0.count > 0 { message.write($0.baseAddress!, $0.count) }
        }
        message.writeUInt16BE(cipher.rawValue)
        message.writeByte(0)                             // legacy_compression_method

        let extensionsLength = message.openLength(2)
        // supported_versions: this is where 1.3 is actually agreed, the
        // legacy_version field above being frozen at 1.2 for middleboxes.
        message.writeUInt16BE(ExtensionType.supportedVersions)
        message.writeUInt16BE(2)
        message.writeUInt16BE(0x0304)

        message.writeUInt16BE(ExtensionType.keyShare)
        let keyShareLength = message.openLength(2)
        message.writeUInt16BE(group)
        let keyLength = message.openLength(2)
        var publicKey = [UInt8](repeating: 0, count: 128)
        let n = publicKey.withUnsafeMutableBufferPointer {
            Int(pg_kex_public(kex, $0.baseAddress, $0.count))
        }
        if n <= 0 { return fail(TLSAlert.internalError) }
        publicKey.withUnsafeBufferPointer { message.write($0.baseAddress!, n) }
        message.closeLength(keyLength, 2)
        message.closeLength(keyShareLength, 2)
        message.closeLength(extensionsLength, 2)
        message.closeLength(bodyLength, 3)

        emit(&message, level: .initial)
    }

    // MARK: The rest of the server's flight

    private func writeServerFlight(scheme: UInt16) -> Bool {
        var message = ByteBuffer(capacity: 1024)
        defer { message.destroy() }

        // EncryptedExtensions. ALPN and the transport parameters go here
        // rather than in the ServerHello: they are only sent encrypted.
        message.writeByte(HandshakeType.encryptedExtensions)
        var body = message.openLength(3)
        let extensions = message.openLength(2)
        if !selectedALPN.isEmpty {
            message.writeUInt16BE(ExtensionType.alpn)
            let extLength = message.openLength(2)
            let listLength = message.openLength(2)
            message.writeByte(UInt8(selectedALPN.count))
            selectedALPN.withUnsafeBufferPointer { message.write($0.baseAddress!, $0.count) }
            message.closeLength(listLength, 2)
            message.closeLength(extLength, 2)
        }
        message.writeUInt16BE(ExtensionType.quicTransportParameters)
        let paramsLength = message.openLength(2)
        localParameters.encode(into: &message, isServer: true)
        message.closeLength(paramsLength, 2)
        message.closeLength(extensions, 2)
        message.closeLength(body, 3)
        emit(&message, level: .handshake)

        // Certificate.
        message.clear()
        message.writeByte(HandshakeType.certificate)
        body = message.openLength(3)
        message.writeByte(0)                             // no request context
        let listLength = message.openLength(3)
        let count = Int(pg_certkey_chain_count(certKey))
        if count == 0 { fail(TLSAlert.internalError); return false }
        for i in 0..<count {
            let needed = Int(pg_certkey_cert_der(certKey, Int32(i), nil, 0))
            if needed <= 0 { fail(TLSAlert.internalError); return false }
            let certLength = message.openLength(3)
            message.reserve(needed)
            let written = Int(pg_certkey_cert_der(certKey, Int32(i),
                                                  message.writePointer, needed))
            if written != needed { fail(TLSAlert.internalError); return false }
            message.advanceWriter(written)
            message.closeLength(certLength, 3)
            message.writeUInt16BE(0)                     // per-certificate extensions
        }
        message.closeLength(listLength, 3)
        message.closeLength(body, 3)
        emit(&message, level: .handshake)

        // CertificateVerify. The signature covers a fixed preamble and the
        // transcript so far, which is what binds the certificate to this
        // handshake rather than to a recording of an earlier one.
        message.clear()
        message.writeByte(HandshakeType.certificateVerify)
        body = message.openLength(3)
        message.writeUInt16BE(scheme)
        let signatureLength = message.openLength(2)

        var toSign = ByteBuffer(capacity: 256)
        defer { toSign.destroy() }
        for _ in 0..<64 { toSign.writeByte(0x20) }
        toSign.write("TLS 1.3, server CertificateVerify")
        toSign.writeByte(0)
        var digest = [UInt8](repeating: 0, count: 48)
        let digestLength = digest.withUnsafeMutableBufferPointer {
            Int(pg_hash_snapshot(transcript, $0.baseAddress))
        }
        if digestLength <= 0 { fail(TLSAlert.internalError); return false }
        digest.withUnsafeBufferPointer { toSign.write($0.baseAddress!, digestLength) }

        message.reserve(1024)
        let signed = Int(pg_certkey_sign(certKey, scheme,
                                         toSign.readPointer, toSign.readableBytes,
                                         message.writePointer, 1024))
        if signed <= 0 { fail(TLSAlert.internalError); return false }
        message.advanceWriter(signed)
        message.closeLength(signatureLength, 2)
        message.closeLength(body, 3)
        emit(&message, level: .handshake)

        // Finished: proof that whoever chose these keys also saw every message
        // in the transcript.
        message.clear()
        message.writeByte(HandshakeType.finished)
        body = message.openLength(3)
        guard let verify = finishedValue(secret: serverHandshakeSecret) else {
            fail(TLSAlert.internalError)
            return false
        }
        verify.withUnsafeBufferPointer { message.write($0.baseAddress!, $0.count) }
        message.closeLength(body, 3)
        emit(&message, level: .handshake)
        return true
    }

    /// Appends a finished message to its level's output and to the transcript,
    /// which must happen together and in that order everywhere.
    private func emit(_ message: inout ByteBuffer, level: QUICLevel) {
        pg_hash_update(transcript, message.readPointer, message.readableBytes)
        if level == .initial {
            initialOut.write(message.readPointer, message.readableBytes)
        } else {
            handshakeOut.write(message.readPointer, message.readableBytes)
        }
    }

    // MARK: Key schedule

    private func expand(_ secret: [UInt8], _ label: StaticString,
                        context: [UInt8], length: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: length)
        let ok = secret.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                context.withUnsafeBufferPointer { c in
                    quicExpandLabel(hash: cipher.hash, secret: s.baseAddress!,
                                    secretLen: s.count, label: label,
                                    context: c.count > 0 ? c.baseAddress : nil,
                                    contextLen: c.count,
                                    out: o.baseAddress!, outLen: length)
                }
            }
        }
        return ok ? out : nil
    }

    private func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: cipher.hashLength)
        let n = salt.withUnsafeBufferPointer { s in
            ikm.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in
                    Int(pg_hkdf_extract(cipher.hash,
                                        s.count > 0 ? s.baseAddress : nil, s.count,
                                        i.count > 0 ? i.baseAddress : nil, i.count,
                                        o.baseAddress))
                }
            }
        }
        return n == cipher.hashLength ? out : nil
    }

    private func transcriptHash() -> [UInt8]? {
        var digest = [UInt8](repeating: 0, count: 48)
        let n = digest.withUnsafeMutableBufferPointer {
            Int(pg_hash_snapshot(transcript, $0.baseAddress))
        }
        if n <= 0 { return nil }
        digest.removeLast(digest.count - n)
        return digest
    }

    private func emptyHash() -> [UInt8]? {
        var digest = [UInt8](repeating: 0, count: 48)
        let n = digest.withUnsafeMutableBufferPointer {
            Int(pg_hash(cipher.hash, "", 0, $0.baseAddress))
        }
        if n <= 0 { return nil }
        digest.removeLast(digest.count - n)
        return digest
    }

    private func deriveHandshakeSecrets(_ shared: [UInt8]) -> Bool {
        let zeros = [UInt8](repeating: 0, count: cipher.hashLength)
        guard let early = extract(salt: [], ikm: zeros),
              let empty = emptyHash(),
              let derived = expand(early, "derived", context: empty, length: cipher.hashLength),
              let handshake = extract(salt: derived, ikm: shared),
              let hash = transcriptHash(),
              let client = expand(handshake, "c hs traffic", context: hash,
                                  length: cipher.hashLength),
              let server = expand(handshake, "s hs traffic", context: hash,
                                  length: cipher.hashLength)
        else { return false }

        handshakeSecret = handshake
        clientHandshakeSecret = client
        serverHandshakeSecret = server
        pendingSecrets.append(Secrets(level: .handshake, client: client, server: server,
                                      cipher: cipher))
        return true
    }

    private func deriveApplicationSecrets() -> Bool {
        let zeros = [UInt8](repeating: 0, count: cipher.hashLength)
        guard let empty = emptyHash(),
              let derived = expand(handshakeSecret, "derived", context: empty,
                                   length: cipher.hashLength),
              let master = extract(salt: derived, ikm: zeros),
              let hash = transcriptHash(),
              let client = expand(master, "c ap traffic", context: hash,
                                  length: cipher.hashLength),
              let server = expand(master, "s ap traffic", context: hash,
                                  length: cipher.hashLength)
        else { return false }
        pendingSecrets.append(Secrets(level: .application, client: client, server: server,
                                      cipher: cipher))
        return true
    }

    private func finishedValue(secret: [UInt8]) -> [UInt8]? {
        guard let key = expand(secret, "finished", context: [], length: cipher.hashLength),
              let hash = transcriptHash()
        else { return nil }
        var out = [UInt8](repeating: 0, count: cipher.hashLength)
        let n = key.withUnsafeBufferPointer { k in
            hash.withUnsafeBufferPointer { h in
                out.withUnsafeMutableBufferPointer { o in
                    Int(pg_hmac(cipher.hash, k.baseAddress, k.count,
                                h.baseAddress, h.count, o.baseAddress))
                }
            }
        }
        return n == cipher.hashLength ? out : nil
    }

    // MARK: Client Finished

    private func handleFinished(_ message: UnsafePointer<UInt8>, _ total: Int) {
        let length = total - 4
        guard length == cipher.hashLength,
              let expected = finishedValue(secret: clientHandshakeSecret)
        else { return fail(TLSAlert.decryptError) }

        // Constant time: a comparison that stops at the first wrong byte tells
        // an attacker how much of a guess was right.
        var difference: UInt8 = 0
        for i in 0..<length { difference |= expected[i] ^ message[4 + i] }
        if difference != 0 { return fail(TLSAlert.decryptError) }

        pg_hash_update(transcript, message, total)
        state = .complete
        scrubSecrets()
    }
}
