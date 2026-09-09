import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

/// Decodes a hex string into bytes, so the RFC 7541 examples can be pasted in
/// the shape they appear in the document.
private func hex(_ s: String) -> [UInt8] {
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
        if let high = nibble {
            out.append(high << 4 | v)
            nibble = nil
        } else {
            nibble = v
        }
    }
    return out
}

private func decodeAll(_ decoder: inout HPACKDecoder, _ bytes: [UInt8]) throws -> [(String, String)] {
    var fields: [(String, String)] = []
    try bytes.withUnsafeBufferPointer { buf in
        try decoder.decode(buf.baseAddress!, buf.count) { span in
            let name = String(decoding: UnsafeBufferPointer(start: span.name,
                                                           count: span.nameLength), as: UTF8.self)
            let value = String(decoding: UnsafeBufferPointer(start: span.value,
                                                            count: span.valueLength), as: UTF8.self)
            fields.append((name, value))
        }
    }
    return fields
}

private func same(_ actual: [(String, String)], _ expected: [(String, String)]) -> Bool {
    actual.count == expected.count
        && zip(actual, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

@Suite("HPACK")
struct HPACKTests {

    @Test("the committed Huffman codes are the canonical ones for their lengths")
    func canonicalTable() {
        #expect(HPACKHuffman.tablesAreCanonical())
    }

    @Test("the Huffman code is complete")
    func kraftSum() {
        // A complete prefix code fills the space exactly: sum of 2^-length over
        // every symbol is 1. One mistyped length would break this.
        var total: UInt64 = 0
        for length in HPACKTables.huffmanLengths {
            total += UInt64(1) << (32 - UInt64(length))
        }
        #expect(total == UInt64(1) << 32)
    }

    @Test("integers round trip at every prefix width")
    func integers() throws {
        for prefix in 4...7 {
            for value in [0, 1, 10, 30, 31, 127, 128, 1337, 4096, 65535, 1 << 20] {
                var out = ByteBuffer()
                defer { out.destroy() }
                hpackWriteInteger(value, prefixBits: prefix, flags: 0, into: &out)
                var cursor = 0
                let back = try hpackReadInteger(UnsafePointer(out.readPointer),
                                                out.readableBytes, &cursor,
                                                prefixBits: prefix)
                #expect(back == value)
                #expect(cursor == out.readableBytes)
            }
        }
    }

    @Test("RFC 7541 C.2: literal field representations")
    func literals() throws {
        // C.2.1, with incremental indexing and a literal name.
        var decoder = HPACKDecoder()
        defer { decoder.destroy() }
        let fields = try decodeAll(&decoder, hex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"))
        #expect(same(fields, [("custom-key", "custom-header")]))
        #expect(decoder.dynamicEntryCount == 1)
        #expect(decoder.dynamicTableSize == 55)

        // C.2.2, literal without indexing and a static name index.
        var second = HPACKDecoder()
        defer { second.destroy() }
        let path = try decodeAll(&second, hex("040c 2f73 616d 706c 652f 7061 7468"))
        #expect(same(path, [(":path", "/sample/path")]))
        #expect(second.dynamicEntryCount == 0)

        // C.2.4, a single indexed field.
        var third = HPACKDecoder()
        defer { third.destroy() }
        #expect(same(try decodeAll(&third, hex("82")), [(":method", "GET")]))
    }

    @Test("RFC 7541 C.3: a request sequence without Huffman")
    func requestSequence() throws {
        var decoder = HPACKDecoder()
        defer { decoder.destroy() }

        let first = try decodeAll(&decoder, hex("8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"))
        #expect(same(first, [(":method", "GET"), (":scheme", "http"),
                             (":path", "/"), (":authority", "www.example.com")]))
        #expect(decoder.dynamicTableSize == 57)

        let second = try decodeAll(&decoder, hex("8286 84be 5808 6e6f 2d63 6163 6865"))
        #expect(same(second, [(":method", "GET"), (":scheme", "http"),
                              (":path", "/"), (":authority", "www.example.com"),
                              ("cache-control", "no-cache")]))
        #expect(decoder.dynamicTableSize == 110)

        let third = try decodeAll(&decoder, hex("8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65"))
        #expect(same(third, [(":method", "GET"), (":scheme", "https"),
                             (":path", "/index.html"), (":authority", "www.example.com"),
                             ("custom-key", "custom-value")]))
        #expect(decoder.dynamicTableSize == 164)
    }

    @Test("RFC 7541 C.4: the same requests Huffman coded")
    func huffmanRequestSequence() throws {
        var decoder = HPACKDecoder()
        defer { decoder.destroy() }

        let first = try decodeAll(&decoder, hex("8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"))
        #expect(same(first, [(":method", "GET"), (":scheme", "http"),
                             (":path", "/"), (":authority", "www.example.com")]))

        let second = try decodeAll(&decoder, hex("8286 84be 5886 a8eb 1064 9cbf"))
        #expect(same(second, [(":method", "GET"), (":scheme", "http"),
                              (":path", "/"), (":authority", "www.example.com"),
                              ("cache-control", "no-cache")]))

        let third = try decodeAll(&decoder, hex("8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"))
        #expect(same(third, [(":method", "GET"), (":scheme", "https"),
                             (":path", "/index.html"), (":authority", "www.example.com"),
                             ("custom-key", "custom-value")]))
    }

    @Test("RFC 7541 C.5: responses that evict from a small table")
    func responseEviction() throws {
        var decoder = HPACKDecoder(maxTableSize: 256)
        defer { decoder.destroy() }

        let first = try decodeAll(&decoder, hex("""
            4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133
            2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70
            6c65 2e63 6f6d
            """))
        #expect(same(first, [(":status", "302"), ("cache-control", "private"),
                             ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
                             ("location", "https://www.example.com")]))
        #expect(decoder.dynamicTableSize == 222)

        let second = try decodeAll(&decoder, hex("4803 3330 37c1 c0bf"))
        #expect(same(second, [(":status", "307"), ("cache-control", "private"),
                              ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
                              ("location", "https://www.example.com")]))
        #expect(decoder.dynamicTableSize == 222)

        let third = try decodeAll(&decoder, hex("""
            88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d
            54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049
            5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e
            3d31
            """))
        #expect(same(third, [(":status", "200"), ("cache-control", "private"),
                             ("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
                             ("location", "https://www.example.com"),
                             ("content-encoding", "gzip"),
                             ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1")]))
        #expect(decoder.dynamicEntryCount == 3)
    }

    @Test("what we encode is what a decoder reads back")
    func encodeRoundTrip() throws {
        let encoder = HPACKEncoder()
        var block = ByteBuffer()
        defer { block.destroy() }

        encoder.encodeStatus(200, into: &block)
        encoder.encodeStatus(451, into: &block)
        let fields = [("content-type", "text/plain; charset=utf-8"),
                      ("x-trace", "0123456789abcdef"),
                      ("server", "peregrine"),
                      ("x-empty", "")]
        for (name, value) in fields {
            var n = Array(name.utf8)
            var v = Array(value.utf8)
            n.withUnsafeBufferPointer { np in
                v.withUnsafeBufferPointer { vp in
                    encoder.encode(name: np.baseAddress!, nameLength: np.count,
                                   value: vp.baseAddress ?? UnsafePointer(bitPattern: 0x1000)!,
                                   valueLength: vp.count, into: &block)
                }
            }
        }

        var decoder = HPACKDecoder()
        defer { decoder.destroy() }
        var out: [(String, String)] = []
        try decoder.decode(UnsafePointer(block.readPointer), block.readableBytes) { span in
            out.append((String(decoding: UnsafeBufferPointer(start: span.name,
                                                            count: span.nameLength), as: UTF8.self),
                        String(decoding: UnsafeBufferPointer(start: span.value,
                                                             count: span.valueLength), as: UTF8.self)))
        }
        #expect(out.count == 6)
        #expect(out[0] == (":status", "200"))
        #expect(out[1] == (":status", "451"))
        #expect(out[2] == ("content-type", "text/plain; charset=utf-8"))
        #expect(out[5] == ("x-empty", ""))
        // The encoder never grows the peer's table.
        #expect(decoder.dynamicEntryCount == 0)
    }

    @Test("Huffman strings round trip, including every byte value")
    func huffmanRoundTrip() throws {
        var input = [UInt8](0...255)
        input.append(contentsOf: Array("the quick brown fox".utf8))
        var encoded = ByteBuffer()
        var decoded = ByteBuffer()
        defer { encoded.destroy(); decoded.destroy() }
        input.withUnsafeBufferPointer { p in
            HPACKHuffman.encode(p.baseAddress!, p.count, into: &encoded)
        }
        let n = try HPACKHuffman.decode(UnsafePointer(encoded.readPointer),
                                        encoded.readableBytes, into: &decoded)
        #expect(n == input.count)
        let back = Array(UnsafeBufferPointer(start: decoded.readPointer, count: n))
        #expect(back == input)
    }

    @Test("malformed blocks are rejected rather than guessed at")
    func rejections() throws {
        func fails(_ bytes: [UInt8], _ expected: HPACKError) -> Bool {
            var decoder = HPACKDecoder()
            defer { decoder.destroy() }
            do {
                try bytes.withUnsafeBufferPointer { buf in
                    try decoder.decode(buf.baseAddress!, buf.count) { _ in }
                }
                return false
            } catch let error as HPACKError {
                return error == expected
            } catch {
                return false
            }
        }

        #expect(fails(hex("80"), .badIndex))            // index 0
        #expect(fails(hex("be"), .badIndex))            // empty dynamic table
        #expect(fails(hex("0004 6162"), .truncated))    // name shorter than declared
        #expect(fails(hex("00"), .truncated))           // no name at all
        // Huffman padding that is not the EOS prefix.
        #expect(fails(hex("0000 8100"), .badHuffman))
        // A dynamic table size update of 4097, one past the maximum.
        #expect(fails(hex("3fe2 1f"), .badTableSize))
    }
}
