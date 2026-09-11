//===----------------------------------------------------------------------===//
// Starting points.
//
// A mutation fuzzer is only as good as what it starts from: random bytes never
// reach the interesting states of a parser, because almost none of them are a
// request at all. These are one valid example of each shape the parser has a
// branch for, so that a mutation lands in the middle of something the parser
// was already prepared to read.
//
// They are compiled in rather than checked in as files so that the fuzzer and
// the corpus test work in a bare checkout. `fuzz/corpus/` is for what a run
// finds afterwards, and for anything that once crashed.
//===----------------------------------------------------------------------===//

extension Fuzz {

    public static func seeds(for target: FuzzTarget) -> [[UInt8]] {
        switch target {
        case .httpHead: return httpHeadSeeds
        case .chunked: return chunkedSeeds
        case .hpack: return hpackSeeds
        case .websocket: return websocketSeeds
        case .quicPacket: return quicPacketSeeds
        }
    }

    private static var httpHeadSeeds: [[UInt8]] {
        [
            text("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"),
            text("GET /a?b=c HTTP/1.0\r\n\r\n"),
            text("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
                 + "Content-Type: text/plain\r\n\r\nhello"),
            text("POST /stream HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                 + "5\r\nhello\r\n0\r\n\r\n"),
            text("GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n"
                 + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"),
            text("GET http://example.com/absolute HTTP/1.1\r\nHost: example.com\r\n\r\n"),
            text("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"),
            text("GET / HTTP/1.1\r\nHost: x\r\nX-Repeated: 1\r\nX-Repeated: 2\r\n"
                 + "Cookie: a=1\r\nCookie: b=2\r\n\r\n"),
            text("HEAD / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n"),
        ]
    }

    private static var chunkedSeeds: [[UInt8]] {
        [
            text("5\r\nhello\r\n0\r\n\r\n"),
            text("0\r\n\r\n"),
            text("a\r\n0123456789\r\n0\r\n\r\n"),
            text("5;name=value\r\nhello\r\n0\r\n\r\n"),
            text("5\r\nhello\r\n0\r\nTrailer: value\r\n\r\n"),
            text("1\r\na\r\n1\r\nb\r\n1\r\nc\r\n0\r\n\r\n"),
            text("FFFFFFFF\r\n"),
        ]
    }

    private static var hpackSeeds: [[UInt8]] {
        [
            // RFC 7541 C.2.1: a literal field with incremental indexing.
            hex("400a637573746f6d2d6b65790d637573746f6d2d686561646572"),
            // C.2.2: a literal field without indexing.
            hex("040c2f73616d706c652f70617468"),
            // C.2.3: a never-indexed literal.
            hex("100870617373776f726406736563726574"),
            // C.2.4: an indexed field, :method GET.
            hex("82"),
            // C.3.1: a whole request head.
            hex("828684410f7777772e6578616d706c652e636f6d"),
            // C.4.1: the same, Huffman coded.
            hex("828684418cf1e3c2e5f23a6ba0ab90f4ff"),
            // A dynamic table size update followed by a field.
            hex("3fe11f82"),
        ]
    }

    private static var websocketSeeds: [[UInt8]] {
        [
            [0x81, 0x85, 1, 2, 3, 4, 0x69, 0x67, 0x6f, 0x68, 0x6e],   // masked "hello"
            [0x81, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f],               // unmasked "hello"
            [0x82, 0x7E, 0x01, 0x00] + [UInt8](repeating: 0xAB, count: 8),
            [0x89, 0x80, 1, 2, 3, 4],                                 // masked ping
            [0x8A, 0x00],                                             // pong
            [0x88, 0x82, 1, 2, 3, 4, 0x03, 0xEA],                     // close, 1001
            [0x01, 0x03, 0x61, 0x62, 0x63],                           // first text fragment
            [0x80, 0x7F, 0, 0, 0, 0, 0, 0, 0x10, 0x00],               // 64-bit length
        ]
    }

    private static var quicPacketSeeds: [[UInt8]] {
        var initialPacket: [UInt8] = [0xC3]                  // long header, Initial
        initialPacket += [0x00, 0x00, 0x00, 0x01]            // version 1
        initialPacket += [0x08] + [UInt8](repeating: 0x11, count: 8)   // dcid
        initialPacket += [0x08] + [UInt8](repeating: 0x22, count: 8)   // scid
        initialPacket += [0x00]                              // empty token
        initialPacket += [0x44, 0x40]                        // length, 2-byte varint
        initialPacket += [UInt8](repeating: 0x33, count: 0x40)

        var shortPacket: [UInt8] = [0x41]                    // short header
        shortPacket += [UInt8](repeating: 0x11, count: 8)    // dcid
        shortPacket += [UInt8](repeating: 0x44, count: 32)

        var retry: [UInt8] = [0xF0, 0x00, 0x00, 0x00, 0x01]
        retry += [0x08] + [UInt8](repeating: 0x11, count: 8)
        retry += [0x08] + [UInt8](repeating: 0x22, count: 8)
        retry += [UInt8](repeating: 0x55, count: 24)

        let versionNegotiation: [UInt8] = [0x80, 0, 0, 0, 0, 0x04, 1, 2, 3, 4,
                                           0x04, 5, 6, 7, 8, 0, 0, 0, 1]
        return [initialPacket, shortPacket, retry, versionNegotiation]
    }

    private static func text(_ s: String) -> [UInt8] { Array(s.utf8) }

    private static func hex(_ s: String) -> [UInt8] {
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
}
