import CPeregrine
import Testing
@testable import PeregrineCore
@testable import PeregrineQUIC

/// Hex, so vectors can be pasted in the shape the RFC prints them.
private func qhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var nibble: UInt8? = nil
    for ch in s.utf8 {
        let v: UInt8
        switch ch {
        case 0x30...0x39: v = ch - 0x30
        case 0x61...0x66: v = ch - 0x61 + 10
        case 0x41...0x46: v = ch - 0x41 + 10
        default: continue
        }
        if let high = nibble { out.append(high << 4 | v); nibble = nil } else { nibble = v }
    }
    return out
}

private func qhexString(_ b: [UInt8]) -> String {
    var s = ""
    for x in b {
        let hi = x >> 4, lo = x & 0xF
        s.append(Character(UnicodeScalar(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)))
        s.append(Character(UnicodeScalar(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)))
    }
    return s
}

// MARK: - Varints

@Test("varints round trip at every width boundary")
func varintWidths() {
    let cases: [(UInt64, Int)] = [
        (0, 1), (63, 1), (64, 2), (16383, 2), (16384, 4),
        (1_073_741_823, 4), (1_073_741_824, 8), (quicVarintMax, 8),
    ]
    var buf = [UInt8](repeating: 0, count: 8)
    for (value, width) in cases {
        let written = buf.withUnsafeMutableBufferPointer { quicWriteVarint(value, $0.baseAddress!) }
        #expect(written == width)
        #expect(quicVarintLength(value) == width)
        var r = buf.withUnsafeBufferPointer { QUICReader($0.baseAddress!, written) }
        #expect(r.varint() == value)
        #expect(r.isEmpty)
    }
}

@Test("varints match the RFC 9000 appendix A.1 encodings")
func varintVectors() {
    let cases: [(String, UInt64)] = [
        ("c2197c5eff14e88c", 151_288_809_941_952_652),
        ("9d7f3e7d", 494_878_333),
        ("7bbd", 15_293),
        ("25", 37),
        // The same value in a wider encoding: legal, and what makes it
        // possible to reserve room for a length before knowing it.
        ("4025", 37),
    ]
    for (encoded, value) in cases {
        let bytes = qhex(encoded)
        var r = bytes.withUnsafeBufferPointer { QUICReader($0.baseAddress!, $0.count) }
        #expect(r.varint() == value)
    }
}

@Test("a varint that runs off the end of the buffer is refused")
func varintTruncated() {
    let bytes: [UInt8] = [0xc2, 0x19, 0x7c]   // announces eight bytes, has three
    var r = bytes.withUnsafeBufferPointer { QUICReader($0.baseAddress!, $0.count) }
    #expect(r.varint() == nil)
    #expect(r.offset == 0)
}

@Test("a fixed-width varint writes the value in the width asked for")
func varintFixedWidth() {
    var buf = [UInt8](repeating: 0, count: 8)
    for width in [1, 2, 4, 8] where width > 1 || 37 < 64 {
        buf.withUnsafeMutableBufferPointer { quicWriteVarint(37, width: width, $0.baseAddress!) }
        var r = buf.withUnsafeBufferPointer { QUICReader($0.baseAddress!, width) }
        #expect(r.varint() == 37)
        #expect(r.offset == width)
    }
}

// MARK: - Packet numbers

@Test("a truncated packet number decodes to the nearest candidate")
func packetNumberDecoding() {
    // RFC 9000 appendix A.3.
    #expect(quicDecodePacketNumber(largestReceived: 0xa82f30ea,
                                   truncated: 0x9b32, bits: 16) == 0xa82f9b32)
    // The first packet of a connection, with nothing received yet.
    #expect(quicDecodePacketNumber(largestReceived: -1, truncated: 0, bits: 8) == 0)
    #expect(quicDecodePacketNumber(largestReceived: -1, truncated: 2, bits: 8) == 2)
    // A packet that arrives after a wrap of the low byte belongs above the
    // largest seen, not below it.
    #expect(quicDecodePacketNumber(largestReceived: 254, truncated: 1, bits: 8) == 257)
    // ...and a reordered one just below still decodes downwards.
    #expect(quicDecodePacketNumber(largestReceived: 257, truncated: 254, bits: 8) == 254)
}

@Test("a packet number is encoded in as few bytes as stay unambiguous")
func packetNumberLength() {
    #expect(quicPacketNumberLength(0, largestAcked: nil) == 1)
    #expect(quicPacketNumberLength(200, largestAcked: 199) == 1)
    #expect(quicPacketNumberLength(0xace8fe, largestAcked: 0xabe8b3) == 3)
    #expect(quicPacketNumberLength(0xac5c02, largestAcked: 0xabe8b3) == 2)
}

// MARK: - Key derivation

/// RFC 9001 appendix A.1, verbatim.
@Test("initial secrets match RFC 9001 appendix A")
func initialSecrets() {
    let dcidBytes = qhex("8394c8f03e515708")
    let dcid = dcidBytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, $0.count)! }

    var initialSecret = [UInt8](repeating: 0, count: 32)
    let salt = qhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
    let extracted = dcid.withBytes { cid, len in
        salt.withUnsafeBufferPointer { s in
            initialSecret.withUnsafeMutableBufferPointer { out in
                pg_hkdf_extract(0, s.baseAddress, s.count, cid, len, out.baseAddress) == 32
            }
        }
    }
    #expect(extracted)
    #expect(qhexString(initialSecret)
            == "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44")

    var clientSecret = [UInt8](repeating: 0, count: 32)
    _ = initialSecret.withUnsafeBufferPointer { prk in
        clientSecret.withUnsafeMutableBufferPointer { out in
            quicExpandLabel(hash: 0, secret: prk.baseAddress!, secretLen: 32,
                            label: "client in", out: out.baseAddress!, outLen: 32)
        }
    }
    #expect(qhexString(clientSecret)
            == "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea")

    var key = [UInt8](repeating: 0, count: 16)
    var iv = [UInt8](repeating: 0, count: 12)
    var hp = [UInt8](repeating: 0, count: 16)
    _ = clientSecret.withUnsafeBufferPointer { s in
        key.withUnsafeMutableBufferPointer { k in
            iv.withUnsafeMutableBufferPointer { i in
                hp.withUnsafeMutableBufferPointer { h in
                    quicExpandLabel(hash: 0, secret: s.baseAddress!, secretLen: 32,
                                    label: "quic key", out: k.baseAddress!, outLen: 16)
                        && quicExpandLabel(hash: 0, secret: s.baseAddress!, secretLen: 32,
                                           label: "quic iv", out: i.baseAddress!, outLen: 12)
                        && quicExpandLabel(hash: 0, secret: s.baseAddress!, secretLen: 32,
                                           label: "quic hp", out: h.baseAddress!, outLen: 16)
                }
            }
        }
    }
    #expect(qhexString(key) == "1f369613dd76d5467730efcbe3b1a22d")
    #expect(qhexString(iv) == "fa044b2f42a3fd3b46fb255c")
    #expect(qhexString(hp) == "9f50449e04a0e810283a1e9933adedd2")
}

// MARK: - Packet protection

/// A server Initial packet: RFC 9001 appendix A.3's header and packet number,
/// protected by aioquic. The bytes come from an implementation that is not
/// this one, which is the point -- a round trip against ourselves would pass
/// with the labels or the nonce construction wrong.
private let serverInitialPacket = qhex(
    "c2000000010008f067a5502a4262b5004075f98245a58344746d776e4daaa45958a80db0" +
    "3a634936338147ac91029f9fd856f91cb1c0196b45de2e1fc6eff79c5fcae76146c9b367" +
    "b976118c9e85d60d14deea2f0b4375ca5f51dcf09104820d8b7c60a350fedd61370b99c2" +
    "905e41501ec29f2e4b0dff17a8721ecd9da9cbd7b04b291a135270")
private let serverInitialHeader = qhex(
    "c1000000010008f067a5502a4262b50040753a83")
private let serverInitialPayload = qhex(
    "02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc798" +
    "25df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60" +
    "993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304")

@Test("a server Initial packet from another implementation opens")
func openServerInitial() throws {
    let dcidBytes = qhex("8394c8f03e515708")
    let dcid = dcidBytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, $0.count)! }
    // A client's keys: what it receives is what the server sent.
    var keys = try #require(quicInitialKeys(destinationCID: dcid,
                                            version: QUICVersion.v1, isServer: false))
    defer { keys.destroy() }

    var packet = serverInitialPacket
    let opened: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        let header = QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8)
        #expect(header.isValid)
        #expect(header.type == .initial)
        #expect(header.version == QUICVersion.v1)
        #expect(header.dcid.length == 0)
        #expect(header.scid.length == 8)
        #expect(header.end == buf.count)
        return QUICProtect.open(buf.baseAddress!, pnOffset: header.pnOffset, end: header.end,
                                largestReceived: -1,
                                keys: keys.receive.keys, header: keys.receive.header)
    }
    let result = try #require(opened)
    #expect(result.packetNumber == 0x3a83)
    #expect(result.payloadLength == serverInitialPayload.count)
    let recovered = [UInt8](UnsafeBufferPointer(start: result.payload, count: result.payloadLength))
    #expect(recovered == serverInitialPayload)
    // The header is left unmasked, so the parsed packet number length is
    // readable afterwards.
    #expect(Array(packet[0..<serverInitialHeader.count]) == serverInitialHeader)
}

@Test("sealing reproduces the other implementation's bytes exactly")
func sealServerInitial() throws {
    let dcidBytes = qhex("8394c8f03e515708")
    let dcid = dcidBytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, $0.count)! }
    var keys = try #require(quicInitialKeys(destinationCID: dcid,
                                            version: QUICVersion.v1, isServer: true))
    defer { keys.destroy() }

    var packet = serverInitialHeader + serverInitialPayload
    packet.append(contentsOf: [UInt8](repeating: 0, count: quicAEADTagLength))
    let sealed: Int? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 18, pnLength: 2,
                         payloadLength: serverInitialPayload.count,
                         packetNumber: 0x3a83,
                         keys: keys.send.keys, header: keys.send.header)
    }
    #expect(sealed == serverInitialPacket.count)
    #expect(packet == serverInitialPacket)
}

/// RFC 9001 appendix A.5, which is the RFC's own bytes: a ChaCha20-Poly1305
/// short-header packet carrying a single PING.
@Test("a ChaCha20 short-header packet matches RFC 9001 appendix A.5")
func chachaShortHeader() throws {
    let secret = qhex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b")
    let expected = qhex("4cfe4189655e5cd55c41f69080575d7999c25a5bfb")

    var direction = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 32,
                      cipher: .chacha20Poly1305SHA256, version: QUICVersion.v1)
    })
    defer { direction.destroy() }

    // Open. A short header has no connection ID here, so the packet number
    // starts at byte one.
    var packet = expected
    let opened: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.open(buf.baseAddress!, pnOffset: 1, end: buf.count,
                         largestReceived: 654_360_563,
                         keys: direction.keys, header: direction.header)
    }
    let result = try #require(opened)
    #expect(result.packetNumber == 654_360_564)
    #expect(result.payloadLength == 1)
    #expect(result.payload[0] == 0x01)     // PING
    #expect(result.keyPhase == false)

    // Seal the same thing back.
    var rebuilt = qhex("4200bff4") + [0x01] + [UInt8](repeating: 0, count: quicAEADTagLength)
    let sealed: Int? = rebuilt.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 1, pnLength: 3, payloadLength: 1,
                         packetNumber: 654_360_564,
                         keys: direction.keys, header: direction.header)
    }
    #expect(sealed == expected.count)
    #expect(rebuilt == expected)
}

@Test("a packet that will not open leaves its header readable")
func failedOpenIsClean() throws {
    let secret = qhex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b")
    var direction = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 32,
                      cipher: .chacha20Poly1305SHA256, version: QUICVersion.v1)
    })
    defer { direction.destroy() }

    var packet = qhex("4cfe4189655e5cd55c41f69080575d7999c25a5bfb")
    packet[packet.count - 1] ^= 0x01        // a flipped bit in the tag
    let original = packet
    let opened: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.open(buf.baseAddress!, pnOffset: 1, end: buf.count,
                         largestReceived: 654_360_563,
                         keys: direction.keys, header: direction.header)
    }
    #expect(opened == nil)
    // The header is put back, so the packet is still worth a log line. The
    // payload is not: it was decrypted in place before the tag was checked.
    #expect(Array(packet[0..<4]) == Array(original[0..<4]))
}

@Test("AES-256-GCM protects a full-size packet")
func aes256RoundTrip() throws {
    var secret = [UInt8](repeating: 0, count: 48)
    for i in 0..<48 { secret[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
    var direction = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 48,
                      cipher: .aes256GCMSHA384, version: QUICVersion.v1)
    })
    defer { direction.destroy() }

    // A short header with an eight-byte connection ID and a four-byte packet
    // number: thirteen bytes before the payload.
    let headerLength = 13
    let payloadLength = 1200 - headerLength - quicAEADTagLength
    var packet = [UInt8](repeating: 0, count: 1200)
    packet[0] = 0x43                        // short header, 4-byte packet number
    for i in 1..<9 { packet[i] = UInt8(i) } // connection ID
    for i in headerLength..<(headerLength + payloadLength) {
        packet[i] = UInt8(truncatingIfNeeded: i)
    }
    let plaintext = Array(packet[headerLength..<(headerLength + payloadLength)])

    let sealed: Int? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 9, pnLength: 4,
                         payloadLength: payloadLength, packetNumber: 0x1234_5678,
                         keys: direction.keys, header: direction.header)
    }
    #expect(sealed == 1200)

    let opened: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.open(buf.baseAddress!, pnOffset: 9, end: 1200,
                         largestReceived: 0x1234_5677,
                         keys: direction.keys, header: direction.header)
    }
    let result = try #require(opened)
    #expect(result.packetNumber == 0x1234_5678)
    #expect([UInt8](UnsafeBufferPointer(start: result.payload,
                                        count: result.payloadLength)) == plaintext)
}

@Test("a key update produces keys the previous generation cannot read")
func keyUpdate() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { secret[i] = UInt8(truncatingIfNeeded: i &* 11 &+ 5) }
    var first = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 32,
                      cipher: .aes128GCMSHA256, version: QUICVersion.v1)
    })
    defer { first.destroy() }
    var second = try #require(first.keys.nextGeneration(version: QUICVersion.v1))
    defer { second.destroy() }

    var packet = [UInt8](repeating: 0, count: 60)
    packet[0] = 0x40
    let payloadLength = 60 - 10 - quicAEADTagLength
    _ = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 9, pnLength: 1,
                         payloadLength: payloadLength, packetNumber: 7,
                         keys: second, header: first.header)
    }
    // Each attempt gets its own copy: opening is destructive.
    var forNew = packet
    let withNew: QUICProtect.Opened? = forNew.withUnsafeMutableBufferPointer { buf in
        QUICProtect.open(buf.baseAddress!, pnOffset: 9, end: 60, largestReceived: 6,
                         keys: second, header: first.header)
    }
    #expect(withNew != nil)
    // Header protection is unchanged by an update, so the header still comes
    // off with the old keys -- it is the AEAD that must refuse.
    let withOld: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.open(buf.baseAddress!, pnOffset: 9, end: 60, largestReceived: 6,
                         keys: first.keys, header: first.header)
    }
    #expect(withOld == nil)
}

// MARK: - Header parsing

@Test("a malformed long header is refused rather than guessed at")
func badLongHeaders() {
    // A connection ID longer than QUIC allows.
    let tooLong = qhex("c000000001ff") + [UInt8](repeating: 0xaa, count: 40)
    tooLong.withUnsafeBufferPointer { buf in
        #expect(!QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8).isValid)
    }
    // The fixed bit clear, on a version that is not version negotiation.
    let noFixedBit = qhex("800000000100000041ff")
    noFixedBit.withUnsafeBufferPointer { buf in
        #expect(!QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8).isValid)
    }
    // A length field that reaches past the end of the datagram.
    let overlongLength = qhex("c00000000100000044ff00")
    overlongLength.withUnsafeBufferPointer { buf in
        #expect(!QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8).isValid)
    }
    // A short header on a datagram too small to hold this server's own
    // connection ID.
    let tinyShort = qhex("4000")
    tinyShort.withUnsafeBufferPointer { buf in
        #expect(!QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8).isValid)
    }
}

@Test("coalesced packets report where the next one starts")
func coalescedPackets() {
    // An Initial with a five-byte body, followed by whatever comes next.
    var datagram = qhex("c00000000104aabbccdd0400112233" + "00" + "05")
    datagram.append(contentsOf: [1, 2, 3, 4, 5])
    datagram.append(contentsOf: [0x40, 0xff])
    datagram.withUnsafeBufferPointer { buf in
        let h = QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8)
        #expect(h.isValid)
        #expect(h.type == .initial)
        #expect(h.dcid.length == 4)
        #expect(h.scid.length == 4)
        #expect(h.token.count == 0)
        #expect(h.end == buf.count - 2)
    }
}

@Test("a connection ID keeps its bytes and compares by value")
func connectionIDs() {
    let bytes = qhex("0102030405060708090a0b0c0d0e0f1011121314")
    let cid = bytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, 20)! }
    #expect(cid.length == 20)
    let copy = cid.withBytes { p, n in [UInt8](UnsafeBufferPointer(start: p, count: n)) }
    #expect(copy == bytes)

    let shorter = bytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, 8)! }
    #expect(shorter != cid)
    let same = bytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, 8)! }
    #expect(same == shorter)

    // Longer than the protocol allows.
    #expect(bytes.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, 21) } == nil)

    // Two random connection IDs colliding would mean the generator is broken.
    #expect(QUICConnectionID.random() != QUICConnectionID.random())
    #expect(QUICConnectionID.random().length == UInt8(quicLocalCIDLength))
}
