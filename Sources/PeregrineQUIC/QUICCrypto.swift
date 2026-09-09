//===----------------------------------------------------------------------===//
// QUIC packet protection.
//
// QUIC does not use the TLS record layer. TLS supplies a traffic secret per
// direction per encryption level, and QUIC derives its own key, IV and header
// protection key from it, then protects each packet itself:
//
//  * The payload is sealed with an AEAD whose nonce is the static IV xored
//    with the packet number, and whose additional data is the packet header --
//    so the header cannot be edited without the tag failing.
//  * The packet number and the low bits of the first byte are then masked with
//    key stream derived from a sample of that same ciphertext. This is what
//    stops a middlebox reading the packet number, and it is why decryption has
//    to run backwards: unmask the header to learn the packet number, build the
//    nonce from it, then open the payload.
//
// The header protection key is split out from the AEAD key deliberately. A key
// update replaces the AEAD key and IV but leaves header protection alone for
// the life of the connection, and separating them is what lets three
// generations of AEAD keys -- previous, current and next -- coexist during an
// update without any of them owning something the others still need.
//
// Keys are trivial structs of raw pointers with an explicit destroy(), the
// same discipline as ByteBuffer, because packet protection is the hot path and
// a class here would put an atomic retain on every datagram.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// The three TLS 1.3 cipher suites QUIC permits.
public enum QUICCipher: UInt16 {
    case aes128GCMSHA256 = 0x1301
    case aes256GCMSHA384 = 0x1302
    case chacha20Poly1305SHA256 = 0x1303

    @inlinable
    public var aead: Int32 {
        switch self {
        case .aes128GCMSHA256: return Int32(PG_AEAD_AES128GCM)
        case .aes256GCMSHA384: return Int32(PG_AEAD_AES256GCM)
        case .chacha20Poly1305SHA256: return Int32(PG_AEAD_CHACHA20POLY1305)
        }
    }

    @inlinable
    public var hash: Int32 {
        self == .aes256GCMSHA384 ? Int32(PG_SHA384) : Int32(PG_SHA256)
    }

    @inlinable
    public var hashLength: Int { self == .aes256GCMSHA384 ? 48 : 32 }

    @inlinable
    public var keyLength: Int { self == .aes128GCMSHA256 ? 16 : 32 }
}

/// The AEAD tag is 16 bytes for every suite QUIC allows.
public let quicAEADTagLength = 16
/// Header protection samples 16 bytes, starting four bytes past the packet
/// number field -- four because that is the longest a packet number can be, so
/// the sample's position does not depend on the length being protected.
public let quicHPSampleLength = 16

// MARK: - Key schedule

/// HKDF-Expand-Label from TLS 1.3, which QUIC uses unchanged.
@discardableResult
public func quicExpandLabel(hash: Int32,
                            secret: UnsafePointer<UInt8>, secretLen: Int,
                            label: StaticString,
                            context: UnsafePointer<UInt8>? = nil, contextLen: Int = 0,
                            out: UnsafeMutablePointer<UInt8>, outLen: Int) -> Bool {
    // struct { uint16 length; opaque label<7..255>; opaque context<0..255>; }
    // with "tls13 " prefixed to the label.
    let total = 2 + 1 + 6 + label.utf8CodeUnitCount + 1 + contextLen
    var info = [UInt8](repeating: 0, count: total)
    var n = 0
    info[n] = UInt8(truncatingIfNeeded: outLen >> 8); n += 1
    info[n] = UInt8(truncatingIfNeeded: outLen); n += 1
    info[n] = UInt8(6 + label.utf8CodeUnitCount); n += 1
    for b in "tls13 ".utf8 { info[n] = b; n += 1 }
    for i in 0..<label.utf8CodeUnitCount { info[n] = label.utf8Start[i]; n += 1 }
    info[n] = UInt8(contextLen); n += 1
    if let context, contextLen > 0 {
        for i in 0..<contextLen { info[n] = context[i]; n += 1 }
    }
    return info.withUnsafeBufferPointer { buf in
        pg_hkdf_expand(hash, secret, secretLen, buf.baseAddress, n, out, outLen) == 0
    }
}

/// Zeroes a byte array that held key material rather than leaving it for the
/// allocator to hand to something else.
@inline(__always)
func quicScrub(_ bytes: inout [UInt8]) {
    for i in 0..<bytes.count { bytes[i] = 0 }
}

/// One AEAD generation: the key, the IV and the secret it came from.
public struct QUICKeys {
    @usableFromInline var aead: OpaquePointer?
    /// The static IV, split so the packet number can be xored into the low
    /// eight bytes with one operation.
    @usableFromInline var ivHi: UInt32 = 0
    @usableFromInline var ivLo: UInt64 = 0
    /// The traffic secret, kept so that a key update can derive the next one.
    @usableFromInline var secret: UnsafeMutablePointer<UInt8>?
    @usableFromInline var secretLen: Int = 0
    public var cipher: QUICCipher = .aes128GCMSHA256

    public init() {}

    @inlinable public var isValid: Bool { aead != nil }

    public static func derive(secret: UnsafePointer<UInt8>, secretLen: Int,
                              cipher: QUICCipher, version: UInt32) -> QUICKeys? {
        var keys = QUICKeys()
        keys.cipher = cipher
        let hash = cipher.hash
        let keyLen = cipher.keyLength

        var key = [UInt8](repeating: 0, count: 32)
        var iv = [UInt8](repeating: 0, count: 12)
        defer { quicScrub(&key); quicScrub(&iv) }

        // Version 2 renamed every label so that a middlebox cannot derive v2
        // keys with code that only knows v1.
        let ok: Bool = key.withUnsafeMutableBufferPointer { k in
            iv.withUnsafeMutableBufferPointer { i in
                if version == QUICVersion.v2 {
                    return quicExpandLabel(hash: hash, secret: secret, secretLen: secretLen,
                                           label: "quicv2 key", out: k.baseAddress!, outLen: keyLen)
                        && quicExpandLabel(hash: hash, secret: secret, secretLen: secretLen,
                                           label: "quicv2 iv", out: i.baseAddress!, outLen: 12)
                }
                return quicExpandLabel(hash: hash, secret: secret, secretLen: secretLen,
                                       label: "quic key", out: k.baseAddress!, outLen: keyLen)
                    && quicExpandLabel(hash: hash, secret: secret, secretLen: secretLen,
                                       label: "quic iv", out: i.baseAddress!, outLen: 12)
            }
        }
        if !ok { return nil }

        keys.aead = key.withUnsafeBufferPointer { pg_aead_new(cipher.aead, $0.baseAddress) }
        if keys.aead == nil { return nil }

        iv.withUnsafeBufferPointer { p in
            let b = p.baseAddress!
            keys.ivHi = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                      | (UInt32(b[2]) << 8) | UInt32(b[3])
            var lo: UInt64 = 0
            for i in 4..<12 { lo = (lo << 8) | UInt64(b[i]) }
            keys.ivLo = lo
        }

        keys.secret = UnsafeMutablePointer<UInt8>.allocate(capacity: secretLen)
        keys.secret!.update(from: secret, count: secretLen)
        keys.secretLen = secretLen
        return keys
    }

    /// The generation after this one. Header protection is not part of it: a
    /// key update leaves that key alone.
    public func nextGeneration(version: UInt32) -> QUICKeys? {
        guard let secret, secretLen > 0 else { return nil }
        var next = [UInt8](repeating: 0, count: secretLen)
        defer { quicScrub(&next) }
        let label: StaticString = version == QUICVersion.v2 ? "quicv2 ku" : "quic ku"
        let ok = next.withUnsafeMutableBufferPointer { out in
            quicExpandLabel(hash: cipher.hash, secret: secret, secretLen: secretLen,
                            label: label, out: out.baseAddress!, outLen: secretLen)
        }
        if !ok { return nil }
        return next.withUnsafeBufferPointer {
            QUICKeys.derive(secret: $0.baseAddress!, secretLen: secretLen,
                            cipher: cipher, version: version)
        }
    }

    @inlinable
    public func nonce(_ packetNumber: UInt64, _ out: UnsafeMutablePointer<UInt8>) {
        quicWriteUInt32BE(ivHi, out)
        quicWriteUInt64BE(ivLo ^ packetNumber, out + 4)
    }

    public mutating func destroy() {
        if let aead { pg_aead_free(aead) }
        if let secret {
            secret.update(repeating: 0, count: secretLen)
            secret.deallocate()
        }
        aead = nil
        secret = nil
        secretLen = 0
    }
}

/// The header protection key, which lives as long as the encryption level.
public struct QUICHeaderKey {
    @usableFromInline var hp: OpaquePointer?
    public init() {}

    @inlinable public var isValid: Bool { hp != nil }

    public static func derive(secret: UnsafePointer<UInt8>, secretLen: Int,
                              cipher: QUICCipher, version: UInt32) -> QUICHeaderKey? {
        var key = [UInt8](repeating: 0, count: 32)
        defer { quicScrub(&key) }
        let ok = key.withUnsafeMutableBufferPointer { k in
            quicExpandLabel(hash: cipher.hash, secret: secret, secretLen: secretLen,
                            label: version == QUICVersion.v2 ? "quicv2 hp" : "quic hp",
                            out: k.baseAddress!, outLen: cipher.keyLength)
        }
        if !ok { return nil }
        var out = QUICHeaderKey()
        out.hp = key.withUnsafeBufferPointer { pg_hp_new(cipher.aead, $0.baseAddress) }
        return out.hp == nil ? nil : out
    }

    /// Five bytes of mask from a 16-byte sample of the packet's ciphertext.
    @inlinable
    public func mask(_ sample: UnsafePointer<UInt8>,
                     _ out: UnsafeMutablePointer<UInt8>) -> Bool {
        guard let hp else { return false }
        return pg_hp_mask(hp, sample, out) == 0
    }

    public mutating func destroy() {
        if let hp { pg_hp_free(hp) }
        hp = nil
    }
}

/// One direction of one encryption level.
public struct QUICDirection {
    public var header = QUICHeaderKey()
    public var keys = QUICKeys()
    public init() {}
    @inlinable public var isValid: Bool { keys.isValid && header.isValid }
    public mutating func destroy() {
        keys.destroy()
        header.destroy()
    }
}

public struct QUICKeyPair {
    public var send = QUICDirection()
    public var receive = QUICDirection()
    public init() {}
    public mutating func destroy() {
        send.destroy()
        receive.destroy()
    }
}

/// Builds both halves of a direction from a traffic secret.
public func quicDirection(secret: UnsafePointer<UInt8>, secretLen: Int,
                          cipher: QUICCipher, version: UInt32) -> QUICDirection? {
    guard let keys = QUICKeys.derive(secret: secret, secretLen: secretLen,
                                     cipher: cipher, version: version),
          let header = QUICHeaderKey.derive(secret: secret, secretLen: secretLen,
                                            cipher: cipher, version: version)
    else { return nil }
    var d = QUICDirection()
    d.keys = keys
    d.header = header
    return d
}

// MARK: - Initial keys

/// The salt that makes Initial keys derivable by anyone who saw the first
/// packet. Initial protection is not a secret -- it exists so a middlebox has
/// to parse QUIC correctly to touch the packet, not so that it cannot read it.
private let initialSaltV1: [UInt8] = [
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
    0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
]
private let initialSaltV2: [UInt8] = [
    0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
    0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9,
]

/// Derives both directions of Initial keys from the connection ID the client
/// chose for its first packet.
public func quicInitialKeys(destinationCID: QUICConnectionID,
                            version: UInt32,
                            isServer: Bool) -> QUICKeyPair? {
    let salt = version == QUICVersion.v2 ? initialSaltV2 : initialSaltV1
    var initialSecret = [UInt8](repeating: 0, count: 32)
    var clientSecret = [UInt8](repeating: 0, count: 32)
    var serverSecret = [UInt8](repeating: 0, count: 32)
    defer {
        quicScrub(&initialSecret)
        quicScrub(&clientSecret)
        quicScrub(&serverSecret)
    }

    let extracted = destinationCID.withBytes { cid, len in
        salt.withUnsafeBufferPointer { s in
            initialSecret.withUnsafeMutableBufferPointer { out in
                pg_hkdf_extract(Int32(PG_SHA256), s.baseAddress, s.count,
                                cid, len, out.baseAddress) == 32
            }
        }
    }
    if !extracted { return nil }

    let ok = initialSecret.withUnsafeBufferPointer { prk in
        clientSecret.withUnsafeMutableBufferPointer { c in
            serverSecret.withUnsafeMutableBufferPointer { s in
                quicExpandLabel(hash: Int32(PG_SHA256), secret: prk.baseAddress!, secretLen: 32,
                                label: "client in", out: c.baseAddress!, outLen: 32)
                    && quicExpandLabel(hash: Int32(PG_SHA256), secret: prk.baseAddress!, secretLen: 32,
                                       label: "server in", out: s.baseAddress!, outLen: 32)
            }
        }
    }
    if !ok { return nil }

    let mine = isServer ? serverSecret : clientSecret
    let theirs = isServer ? clientSecret : serverSecret

    guard let send = mine.withUnsafeBufferPointer({
              quicDirection(secret: $0.baseAddress!, secretLen: 32,
                            cipher: .aes128GCMSHA256, version: version)
          }),
          let receive = theirs.withUnsafeBufferPointer({
              quicDirection(secret: $0.baseAddress!, secretLen: 32,
                            cipher: .aes128GCMSHA256, version: version)
          })
    else { return nil }

    var pair = QUICKeyPair()
    pair.send = send
    pair.receive = receive
    return pair
}

// MARK: - Packet protection

public enum QUICProtect {
    /// Seals a packet that has been written out whole -- header and plaintext
    /// payload -- and masks its header.
    ///
    /// `packet` points at the first byte of the packet; the payload starts at
    /// `pnOffset + pnLength` and there must be `quicAEADTagLength` bytes of
    /// room past its end. The truncated packet number is written here rather
    /// than left to the caller: it is part of the additional data as well as
    /// of the nonce, and a header that disagrees with the number passed in
    /// would produce a packet that only fails to open at the far end.
    ///
    /// Returns the total protected length.
    public static func seal(_ packet: UnsafeMutablePointer<UInt8>,
                            pnOffset: Int, pnLength: Int, payloadLength: Int,
                            packetNumber: UInt64,
                            keys: QUICKeys, header: QUICHeaderKey) -> Int? {
        guard let aead = keys.aead else { return nil }
        let headerLength = pnOffset + pnLength
        for i in 0..<pnLength {
            packet[pnOffset + i] = UInt8(truncatingIfNeeded:
                packetNumber >> (8 &* (pnLength &- 1 &- i)))
        }

        var nonce = (UInt64(0), UInt32(0))
        let sealed: Int = withUnsafeMutableBytes(of: &nonce) { raw in
            let n = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            keys.nonce(packetNumber, n)
            let payload = packet + headerLength
            return Int(pg_aead_seal(aead, n, packet, headerLength,
                                    payload, payloadLength, payload))
        }
        if sealed < 0 { return nil }

        // The sample is taken from the ciphertext at a fixed distance from the
        // packet number field, so where it starts does not itself reveal how
        // long the packet number is.
        let sampleOffset = pnOffset + 4
        if sampleOffset + quicHPSampleLength > headerLength + sealed { return nil }

        var mask: (UInt32, UInt8) = (0, 0)
        let masked: Bool = withUnsafeMutableBytes(of: &mask) { raw in
            header.mask(packet + sampleOffset,
                        raw.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        if !masked { return nil }

        withUnsafeBytes(of: mask) { raw in
            let m = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // A long header protects four bits of the first byte, a short
            // header five: the extra bit is the key phase.
            let bits: UInt8 = (packet[0] & 0x80) != 0 ? 0x0F : 0x1F
            packet[0] ^= m[0] & bits
            for i in 0..<pnLength { packet[pnOffset + i] ^= m[1 + i] }
        }
        return headerLength + sealed
    }

    public struct Opened {
        public var packetNumber: UInt64
        public var payload: UnsafeMutablePointer<UInt8>
        public var payloadLength: Int
        public var keyPhase: Bool
        public var pnLength: Int
    }

    /// Removes header protection and opens a packet in place.
    ///
    /// `packet` is the start of the packet within the datagram and `end` is
    /// one past its last byte. The header is rewritten unmasked and the
    /// plaintext replaces the ciphertext, both in place: the datagram buffer
    /// belongs to the receiver and nothing else reads it afterwards.
    ///
    /// A nil return is ordinary: a packet that will not open is discarded
    /// without ceremony, since it may be a stray from an old key phase or
    /// from somebody spraying the port. The header is put back as it was, so
    /// the packet stays readable for a log line, but the payload is not --
    /// decryption happens in place and the AEAD has already written over it
    /// by the time the tag is found to be wrong. Nothing re-reads a packet
    /// that failed: which keys apply is decided by the header, never by
    /// trying one set after another.
    public static func open(_ packet: UnsafeMutablePointer<UInt8>,
                            pnOffset: Int, end: Int,
                            largestReceived: Int64,
                            keys: QUICKeys, header: QUICHeaderKey) -> Opened? {
        guard let aead = keys.aead else { return nil }
        let sampleOffset = pnOffset + 4
        if sampleOffset + quicHPSampleLength > end { return nil }

        var mask: (UInt32, UInt8) = (0, 0)
        let ok: Bool = withUnsafeMutableBytes(of: &mask) { raw in
            header.mask(packet + sampleOffset,
                        raw.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        if !ok { return nil }

        // The first byte has to be repaired before anything else can be read,
        // because it carries the packet number's length.
        var pnLength = 0
        var truncated: UInt64 = 0
        var keyPhase = false
        var first: UInt8 = 0
        withUnsafeBytes(of: mask) { raw in
            let m = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let isLong = (packet[0] & 0x80) != 0
            first = packet[0] ^ (m[0] & (isLong ? 0x0F : 0x1F))
            pnLength = Int(first & 0x03) + 1
            if !isLong { keyPhase = (first & 0x04) != 0 }
            for i in 0..<pnLength {
                packet[pnOffset + i] ^= m[1 + i]
                truncated = (truncated << 8) | UInt64(packet[pnOffset + i])
            }
        }
        if pnOffset + pnLength + quicAEADTagLength > end {
            // Undo, so a failed attempt leaves the packet as it was for the
            // next set of keys to try.
            withUnsafeBytes(of: mask) { raw in
                let m = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<pnLength { packet[pnOffset + i] ^= m[1 + i] }
            }
            return nil
        }
        let original = packet[0]
        packet[0] = first

        let headerLength = pnOffset + pnLength
        let packetNumber = quicDecodePacketNumber(largestReceived: largestReceived,
                                                  truncated: truncated,
                                                  bits: pnLength * 8)

        var nonce = (UInt64(0), UInt32(0))
        let plaintextLength: Int = withUnsafeMutableBytes(of: &nonce) { raw in
            let n = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            keys.nonce(packetNumber, n)
            let body = packet + headerLength
            return Int(pg_aead_open(aead, n, packet, headerLength,
                                    body, end - headerLength, body))
        }
        if plaintextLength < 0 {
            // Only the header is restored; see above.
            packet[0] = original
            withUnsafeBytes(of: mask) { raw in
                let m = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<pnLength { packet[pnOffset + i] ^= m[1 + i] }
            }
            return nil
        }

        return Opened(packetNumber: packetNumber,
                      payload: packet + headerLength,
                      payloadLength: plaintextLength,
                      keyPhase: keyPhase,
                      pnLength: pnLength)
    }
}
