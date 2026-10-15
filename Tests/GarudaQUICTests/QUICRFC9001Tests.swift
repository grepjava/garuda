//===----------------------------------------------------------------------===//
// RFC 9001 appendix A, the RFC's own bytes: the Initial keys of both sides,
// a client Initial (A.2) and a server Initial (A.3), sealed here and opened
// here. QUICPacketTests has A.1's client keys, A.5 and a server Initial at
// another packet number protected by aioquic (scripts/quic-vectors.py in
// Garuda 1 regenerates it). A.4 (Retry) has no counterpart: the server never
// sends one.
//===----------------------------------------------------------------------===//

import Testing
import VegaCrypto
@testable import GarudaQUIC

private func rfcHex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var nibble: UInt8? = nil
    for ch in s.utf8 {
        let v: UInt8
        switch ch {
        case 0x30...0x39: v = ch - 0x30
        case 0x61...0x66: v = ch - 0x61 + 10
        default: continue
        }
        if let high = nibble { out.append(high << 4 | v); nibble = nil } else { nibble = v }
    }
    return out
}

private let rfcDCID = rfcHex("8394c8f03e515708")

private func rfcLabel(_ secret: [UInt8], _ label: StaticString, _ length: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: length)
    let ok = secret.withUnsafeBufferPointer { s in
        out.withUnsafeMutableBufferPointer { o in
            quicExpandLabel(hash: .sha256, secret: s.baseAddress!, secretLen: s.count, label: label,
                            out: o.baseAddress!, outLen: length)
        }
    }
    #expect(ok)
    return out
}

@Test("the server's initial secrets match RFC 9001 appendix A.1")
func rfcServerInitialSecrets() {
    let initial = HKDF.extract(.sha256, salt: rfcHex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a"),
                               inputKeyMaterial: rfcDCID)
    let server = rfcLabel(initial, "server in", 32)
    #expect(server == rfcHex("3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"))
    #expect(rfcLabel(server, "quic key", 16) == rfcHex("cf3a5331653c364c88f0f379b6067e37"))
    #expect(rfcLabel(server, "quic iv", 12) == rfcHex("0ac1493ca1905853b0bba03e"))
    #expect(rfcLabel(server, "quic hp", 16) == rfcHex("c206b8d9b9f0f37644430b490eeaa314"))
}

private let rfcClientCrypto = rfcHex(
    "060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e86804fe3a47" +
    "f06a2b69484c00000413011302010000c000000010000e00000b6578616d706c652e636f" +
    "6dff01000100000a00080006001d0017001800100007000504616c706e00050005010000" +
    "0000003300260024001d00209370b2c9caa47fbabaf4559fedba753de171fa71f50f1ce1" +
    "5d43e994ec74d748002b0003020304000d0010000e040305030603020308040805080600" +
    "2d00020101001c00024001003900320408ffffffffffffffff05048000ffff07048000ff" +
    "ff0801100104800075300901100f088394c8f03e51570806048000ffff")
private let rfcClientHeader = rfcHex("c300000001088394c8f03e5157080000449e00000002")
private let rfcClientPacket = rfcHex(
    "c000000001088394c8f03e5157080000449e7b9aec34d1b1c98dd7689fb8ec11d242b123" +
    "dc9bd8bab936b47d92ec356c0bab7df5976d27cd449f63300099f3991c260ec4c60d17b3" +
    "1f8429157bb35a1282a643a8d2262cad67500cadb8e7378c8eb7539ec4d4905fed1bee1f" +
    "c8aafba17c750e2c7ace01e6005f80fcb7df621230c83711b39343fa028cea7f7fb5ff89" +
    "eac2308249a02252155e2347b63d58c5457afd84d05dfffdb20392844ae812154682e9cf" +
    "012f9021a6f0be17ddd0c2084dce25ff9b06cde535d0f920a2db1bf362c23e596d11a4f5" +
    "a6cf3948838a3aec4e15daf8500a6ef69ec4e3feb6b1d98e610ac8b7ec3faf6ad760b7ba" +
    "d1db4ba3485e8a94dc250ae3fdb41ed15fb6a8e5eba0fc3dd60bc8e30c5c4287e53805db" +
    "059ae0648db2f64264ed5e39be2e20d82df566da8dd5998ccabdae053060ae6c7b4378e8" +
    "46d29f37ed7b4ea9ec5d82e7961b7f25a9323851f681d582363aa5f89937f5a67258bf63" +
    "ad6f1a0b1d96dbd4faddfcefc5266ba6611722395c906556be52afe3f565636ad1b17d50" +
    "8b73d8743eeb524be22b3dcbc2c7468d54119c7468449a13d8e3b95811a198f3491de3e7" +
    "fe942b330407abf82a4ed7c1b311663ac69890f4157015853d91e923037c227a33cdd5ec" +
    "281ca3f79c44546b9d90ca00f064c99e3dd97911d39fe9c5d0b23a229a234cb36186c481" +
    "9e8b9c5927726632291d6a418211cc2962e20fe47feb3edf330f2c603a9d48c0fcb5699d" +
    "bfe5896425c5bac4aee82e57a85aaf4e2513e4f05796b07ba2ee47d80506f8d2c25e50fd" +
    "14de71e6c418559302f939b0e1abd576f279c4b2e0feb85c1f28ff18f58891ffef132eef" +
    "2fa09346aee33c28eb130ff28f5b766953334113211996d20011a198e3fc433f9f254101" +
    "0ae17c1bf202580f6047472fb36857fe843b19f5984009ddc324044e847a4f4a0ab34f71" +
    "9595de37252d6235365e9b84392b061085349d73203a4a13e96f5432ec0fd4a1ee65accd" +
    "d5e3904df54c1da510b0ff20dcc0c77fcb2c0e0eb605cb0504db87632cf3d8b4dae6e705" +
    "769d1de354270123cb11450efc60ac47683d7b8d0f811365565fd98c4c8eb936bcab8d06" +
    "9fc33bd801b03adea2e1fbc5aa463d08ca19896d2bf59a071b851e6c239052172f296bfb" +
    "5e72404790a2181014f3b94a4e97d117b438130368cc39dbb2d198065ae3986547926cd2" +
    "162f40a29f0c3c8745c0f50fba3852e566d44575c29d39a03f0cda721984b6f440591f35" +
    "5e12d439ff150aab7613499dbd49adabc8676eef023b15b65bfc5ca06948109f23f350db" +
    "82123535eb8a7433bdabcb909271a6ecbcb58b936a88cd4e8f2e6ff5800175f113253d8f" +
    "a9ca8885c2f552e657dc603f252e1a8e308f76f0be79e2fb8f5d5fbbe2e30ecadd220723" +
    "c8c0aea8078cdfcb3868263ff8f0940054da48781893a7e49ad5aff4af300cd804a6b627" +
    "9ab3ff3afb64491c85194aab760d58a606654f9f4400e8b38591356fbf6425aca26dc852" +
    "44259ff2b19c41b9f96f3ca9ec1dde434da7d2d392b905ddf3d1f9af93d1af5950bd493f" +
    "5aa731b4056df31bd267b6b90a079831aaf579be0a39013137aac6d404f518cfd4684064" +
    "7e78bfe706ca4cf5e9c5453e9f7cfd2b8b4c8d169a44e55c88d4a9a7f9474241e221af44" +
    "860018ab0856972e194cd934")

@Test("a client Initial seals to RFC 9001 appendix A.2's bytes, and a server opens it")
func rfcClientInitial() throws {
    let dcid = rfcDCID.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, $0.count)! }
    var client = try #require(quicInitialKeys(destinationCID: dcid, version: QUICVersion.v1, isServer: false))
    defer { client.destroy() }
    var server = try #require(quicInitialKeys(destinationCID: dcid, version: QUICVersion.v1, isServer: true))
    defer { server.destroy() }

    // 1162 bytes of frames: the CRYPTO frame, then PADDING.
    var payload = rfcClientCrypto
    payload += [UInt8](repeating: 0, count: 1162 - payload.count)
    var packet = rfcClientHeader + payload + [UInt8](repeating: 0, count: quicAEADTagLength)
    let sealed: Int? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 18, pnLength: 4, payloadLength: 1162,
                         packetNumber: 2, keys: client.send.keys, header: client.send.header)
    }
    #expect(sealed == 1200)
    #expect(packet == rfcClientPacket)

    var received = rfcClientPacket
    let opened: QUICProtect.Opened? = received.withUnsafeMutableBufferPointer { buf in
        let header = QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8)
        #expect(header.isValid)
        #expect(header.type == .initial)
        #expect(header.dcid == dcid)
        #expect(header.end == 1200)
        return QUICProtect.open(buf.baseAddress!, pnOffset: header.pnOffset, end: header.end,
                                largestReceived: -1,
                                keys: server.receive.keys, header: server.receive.header)
    }
    let result = try #require(opened)
    #expect(result.packetNumber == 2)
    #expect([UInt8](UnsafeBufferPointer(start: result.payload, count: result.payloadLength)) == payload)
}

private let rfcServerPayload = rfcHex(
    "02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc798" +
    "25df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60" +
    "993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304")
private let rfcServerHeader = rfcHex("c1000000010008f067a5502a4262b50040750001")
private let rfcServerPacket = rfcHex(
    "cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a5816b639" +
    "4100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7" +
    "684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06ed" +
    "bb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee")

@Test("a server Initial seals to RFC 9001 appendix A.3's bytes, and a client opens it")
func rfcServerInitial() throws {
    let dcid = rfcDCID.withUnsafeBufferPointer { QUICConnectionID($0.baseAddress!, $0.count)! }
    var server = try #require(quicInitialKeys(destinationCID: dcid, version: QUICVersion.v1, isServer: true))
    defer { server.destroy() }
    var client = try #require(quicInitialKeys(destinationCID: dcid, version: QUICVersion.v1, isServer: false))
    defer { client.destroy() }

    var packet = rfcServerHeader + rfcServerPayload + [UInt8](repeating: 0, count: quicAEADTagLength)
    let sealed: Int? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 18, pnLength: 2,
                         payloadLength: rfcServerPayload.count, packetNumber: 1,
                         keys: server.send.keys, header: server.send.header)
    }
    #expect(sealed == rfcServerPacket.count)
    #expect(packet == rfcServerPacket)

    var received = rfcServerPacket
    let opened: QUICProtect.Opened? = received.withUnsafeMutableBufferPointer { buf in
        let header = QUICPacket.parseHeader(buf.baseAddress!, buf.count, localCIDLength: 8)
        #expect(header.isValid)
        return QUICProtect.open(buf.baseAddress!, pnOffset: header.pnOffset, end: header.end,
                                largestReceived: -1,
                                keys: client.receive.keys, header: client.receive.header)
    }
    let result = try #require(opened)
    #expect(result.packetNumber == 1)
    #expect([UInt8](UnsafeBufferPointer(start: result.payload, count: result.payloadLength)) == rfcServerPayload)
}
