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
// finds afterwards, and for anything that once crashed. Nothing here is
// random -- not even the ClientHello's key share -- so a run is reproducible
// from its seed.
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import QUICTestPeer

extension Fuzz {

    public static func seeds(for target: FuzzTarget) -> [[UInt8]] {
        switch target {
        case .httpHead: return httpHeadSeeds
        case .httpResponse: return httpResponseSeeds
        case .chunked: return chunkedSeeds
        case .hpack: return hpackSeeds
        case .qpack: return qpackSeeds
        case .websocket: return websocketSeeds
        case .quicPacket: return quicPacketSeeds
        case .quicFrames: return quicFrameSeeds
        case .tlsHello: return tlsHelloSeeds
        case .h2: return h2Seeds
        case .h3: return h3Seeds
        case .json: return jsonSeeds
        case .resp: return respSeeds
        case .postgres: return postgresSeeds
        }
    }

    private static var jsonSeeds: [[UInt8]] {
        [
            text("{}"),
            text("[]"),
            text("null"),
            text("true"),
            text("-0"),
            text("{\"a\":1,\"b\":[1,2,3],\"c\":{\"d\":null},\"e\":\"f\"}"),
            text("[1.5e10,-2,0.0001,1e-5,9223372036854775807]"),
            text("\"\\u00e9\\ud83d\\ude00\\n\\t\\\\\\\"\\/\""),
            text("{\"nested\":[[[[{\"deep\":true}]]]]}"),
            text("[\"\",\"a\",\"  \"]"),
            text("{\"dup\":1,\"dup\":2}"),
            text("  { \"spaced\" : [ 1 , 2 ] }  "),
        ]
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
            text("GET /%2e%2e/a%20b HTTP/1.1\r\nHost: x\r\n\r\n"),
            text("\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n"),
        ]
    }

    private static var httpResponseSeeds: [[UInt8]] {
        [
            text("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello"),
            text("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
            text("HTTP/1.1 204 No Content\r\n\r\n"),
            text("HTTP/1.1 304 Not Modified\r\nETag: \"x\"\r\n\r\n"),
            text("HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nuntil close"),
            text("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
            text("HTTP/1.1 301 Moved Permanently\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n"),
            text("HTTP/1.1 200 \r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n"),
            text("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"),
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

    private static var qpackSeeds: [[UInt8]] {
        [
            // :method GET, :scheme https, :path / -- all static.
            hex("0000d1d7c1"),
            // :authority, by static name, with a literal value.
            hex("0000d1d7c150096c6f63616c686f7374"),
            // A literal name and value.
            hex("0000 2378 2d61 0162"),
            // The encoder's own output, Huffman and all.
            qpackBlock([(":method", "POST"), (":scheme", "https"), (":authority", "example.com"),
                        (":path", "/upload?x=1"), ("content-type", "application/json"),
                        ("x-custom", "a value long enough to be worth Huffman coding")]),
            qpackBlock([(":status", "200"), ("content-length", "5"), ("set-cookie", "a=1")]),
        ]
    }

    private static var respSeeds: [[UInt8]] {
        [
            text("+OK\r\n"),
            text("-ERR unknown command\r\n:42\r\n"),
            text("$5\r\nhello\r\n$-1\r\n*-1\r\n"),
            text("*3\r\n:1\r\n*2\r\n+a\r\n$0\r\n\r\n_\r\n"),
            text("%2\r\n+k\r\n#t\r\n$1\r\nv\r\n,1.5e3\r\n"),
            text("~2\r\n(12345678901234567890\r\n,-inf\r\n"),
            text(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n"),
            text("|1\r\n+ttl\r\n:9\r\n*1\r\n=7\r\ntxt:abc\r\n"),
            text("!9\r\nERR nope!\r\n*1\r\n*1\r\n*1\r\n:0\r\n"),
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
            [0xC1, 0x85, 1, 2, 3, 4, 1, 2, 3, 4, 5, 0],               // RSV1: compressed
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

        // A token, then two packets coalesced: a Handshake after the Initial.
        var withToken: [UInt8] = [0xC0, 0, 0, 0, 1, 0x08] + [UInt8](repeating: 0x11, count: 8)
        withToken += [0x00, 0x04, 9, 9, 9, 9, 0x40, 0x20] + [UInt8](repeating: 0x66, count: 0x20)
        withToken += [0xE0, 0, 0, 0, 1, 0x08] + [UInt8](repeating: 0x11, count: 8)
        withToken += [0x00, 0x14] + [UInt8](repeating: 0x77, count: 0x14)
        return [initialPacket, shortPacket, retry, versionNegotiation, withToken]
    }

    /// Frame sequences a client sends in 1-RTT packets, and some it must not.
    private static var quicFrameSeeds: [[UInt8]] {
        let request: [UInt8] = Array("GET / HTTP/0.9\r\n".utf8)
        return [
            [0x01],                                                       // PING
            [0x00, 0x00, 0x00, 0x01],                                     // PADDING, then PING
            streamFrame(0, request, fin: true),
            streamFrame(0, offset: 5, request, fin: false) + streamFrame(0, Array(request.prefix(5)), fin: false),
            streamFrame(2, [0x00, 0x04, 0x00], fin: false),               // a uni stream
            resetStreamFrame(0, code: 0x10c, finalSize: 0),
            [0x05] + hsVarint(0) + hsVarint(0x10c),                       // STOP_SENDING
            [0x10] + hsVarint(1 << 24),                                   // MAX_DATA
            [0x11] + hsVarint(3) + hsVarint(1 << 20),                     // MAX_STREAM_DATA
            [0x12] + hsVarint(200), [0x13] + hsVarint(200),               // MAX_STREAMS
            [0x14] + hsVarint(100), [0x15] + hsVarint(0) + hsVarint(10),  // DATA_BLOCKED, STREAM_DATA_BLOCKED
            [0x16] + hsVarint(128), [0x17] + hsVarint(128),               // STREAMS_BLOCKED
            [0x18, 0x01, 0x00, 0x08] + [UInt8](repeating: 0x5a, count: 8) + [UInt8](repeating: 0xEE, count: 16),
            [0x19, 0x00],                                                 // RETIRE_CONNECTION_ID
            [0x1a, 1, 2, 3, 4, 5, 6, 7, 8],                               // PATH_CHALLENGE
            [0x1b, 1, 2, 3, 4, 5, 6, 7, 8],                               // PATH_RESPONSE, unasked
            [0x02, 0x00, 0x00, 0x00, 0x00],                               // ACK of nothing sent
            [0x03, 0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00],             // ACK_ECN
            [0x06, 0x00, 0x04, 0x04, 0x00, 0x00, 0x00],                   // CRYPTO under 1-RTT
            [0x07, 0x02, 0xAA, 0xBB],                                     // NEW_TOKEN, from a client
            [0x1e],                                                       // HANDSHAKE_DONE, from a client
            [0x31, 0x03, 0x61, 0x62, 0x63], [0x30, 0x61, 0x62],           // DATAGRAM
            [0x1c, 0x0a, 0x00, 0x03, 0x62, 0x61, 0x64],                   // CONNECTION_CLOSE
            [0x1d, 0x00, 0x00],                                           // CONNECTION_CLOSE, application
            [0x40, 0x21],                                                 // an unknown frame type
        ]
    }

    private static var tlsHelloSeeds: [[UInt8]] {
        [
            clientHello(serverName: "localhost", alpn: ["h3"]),
            clientHello(serverName: nil, alpn: ["h3"]),
            clientHello(serverName: "localhost", alpn: ["h3-29", "h3"]),
            // No protocol the server speaks: no_application_protocol.
            clientHello(serverName: "localhost", alpn: ["http/1.1"]),
            // A key share for a group the server has not got, beside the
            // supported_groups that would let it ask for another.
            clientHello(serverName: "localhost", alpn: ["h3"], group: 0x0017),
        ]
    }

    /// What follows the preface and SETTINGS on a client's connection.
    private static var h2Seeds: [[UInt8]] {
        // :method GET, :scheme http, :path /, :authority x.
        let get: [UInt8] = [0x82, 0x86, 0x84, 0x41, 0x01, 0x78]
        // :method POST, :scheme http, :path /echo.
        let post: [UInt8] = [0x83, 0x86, 0x44, 0x05] + Array("/echo".utf8)
        let big: [UInt8] = [0x82, 0x86, 0x44, 0x04] + Array("/big".utf8)
        return [
            h2Frame(0x1, 0x5, 1, get),                                     // HEADERS, END_STREAM | END_HEADERS
            h2Frame(0x1, 0x4, 1, post) + h2Frame(0x0, 0x1, 1, Array("hello".utf8)),
            h2Frame(0x1, 0x5, 1, big) + h2Frame(0x8, 0, 0, [0, 0x10, 0, 0]) + h2Frame(0x8, 0, 1, [0, 0x10, 0, 0]),
            h2Frame(0x1, 0x1, 1, Array(get.prefix(3))) + h2Frame(0x9, 0x4, 1, Array(get.dropFirst(3))),
            h2Frame(0x1, 0x2D, 1, [2] + [0, 0, 0, 0, 16] + get + [0, 0]),  // PADDED | PRIORITY
            h2Frame(0x6, 0, 0, [1, 2, 3, 4, 5, 6, 7, 8]),                   // PING
            h2Frame(0x4, 0, 0, [0, 4, 0, 0, 0, 0] + [0, 5, 0, 0, 0x40, 0]), // SETTINGS
            h2Frame(0x1, 0x4, 1, get) + h2Frame(0x3, 0, 1, [0, 0, 0, 8]),   // RST_STREAM
            h2Frame(0x2, 0, 3, [0, 0, 0, 1, 16]),                           // PRIORITY
            h2Frame(0x7, 0, 0, [0, 0, 0, 0, 0, 0, 0, 0]),                   // GOAWAY
            h2Frame(0x1, 0x5, 3, get) + h2Frame(0x1, 0x5, 1, get),          // streams out of order
            h2Frame(0xFA, 0, 0, [1, 2, 3]),                                 // an unknown type
        ]
    }

    /// A first byte choosing the stream (see HTTP3Target.swift), then its bytes.
    private static var h3Seeds: [[UInt8]] {
        let get = h3Headers([(":method", "GET"), (":scheme", "https"), (":authority", "localhost"), (":path", "/")])
        let post = h3Headers([(":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                              (":path", "/echo")])
        let big = h3Headers([(":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
                             (":path", "/big")])
        return [
            [0] + get,
            [0] + post + [0x00, 0x05] + Array("hello".utf8),
            [0] + big,
            [0] + post + [0x00, 0x02, 0x61, 0x62] + h3Headers([("x-trailer", "yes")]),
            [0] + [0x21, 0x02, 0x00, 0x00] + get,                           // a reserved frame type first
            [0] + Array(get.prefix(4)),                                     // ended inside HEADERS
            [1] + [0x07, 0x01, 0x00],                                       // GOAWAY
            [1] + [0x0d, 0x01, 0x04],                                       // MAX_PUSH_ID
            [1] + [0x04, 0x00],                                             // a second SETTINGS
            [2] + [0x02, 0x20],                                             // encoder stream: capacity 0
            [2] + [0x03, 0x80],                                             // decoder stream
            [2] + [0x21, 1, 2, 3],                                          // an unknown stream type
            [2] + [0x01, 0x00],                                             // a push stream, from a client
        ]
    }

    /// A backend's side of a connection's life, as message sequences.
    private static var postgresSeeds: [[UInt8]] {
        let ready = pgMessage("Z", [UInt8(ascii: "I")])
        let columns = pgInt16(2)
            + cString("id") + pgInt32(0) + pgInt16(0) + pgInt32(23) + pgInt16(4) + pgInt32(-1) + pgInt16(1)
            + cString("name") + pgInt32(16384) + pgInt16(2) + pgInt32(25) + pgInt16(-1) + pgInt32(-1) + pgInt16(0)
        let row = pgInt16(2) + pgInt32(4) + pgInt32(7) + pgInt32(5) + Array("hello".utf8)
        let arrays = pgInt16(2) + pgInt32(10) + Array("{1,NULL,3}".utf8) + pgInt32(-1)
        return [
            pgMessage("R", pgInt32(0)) + pgMessage("S", cString("server_version") + cString("18.6"))
                + pgMessage("K", pgInt32(1234) + pgInt32(5678)) + ready,
            pgMessage("R", pgInt32(5) + [1, 2, 3, 4]),                      // MD5, with its salt
            pgMessage("R", pgInt32(10) + cString("SCRAM-SHA-256") + [0]),
            pgMessage("R", pgInt32(11) + Array("r=abc,s=c2FsdA==,i=4096".utf8)),
            pgMessage("T", columns) + pgMessage("D", row) + pgMessage("C", cString("SELECT 1")) + ready,
            pgMessage("T", pgInt16(1) + cString("a") + pgInt32(0) + pgInt16(0) + pgInt32(1007) + pgInt16(-1)
                      + pgInt32(-1) + pgInt16(0)) + pgMessage("D", arrays),
            pgMessage("E", [UInt8(ascii: "S")] + cString("ERROR") + [UInt8(ascii: "C")] + cString("23505")
                      + [UInt8(ascii: "M")] + cString("duplicate key") + [UInt8(ascii: "n")] + cString("t_pkey") + [0]),
            pgMessage("N", [UInt8(ascii: "S")] + cString("NOTICE") + [UInt8(ascii: "M")] + cString("hi") + [0]),
            pgMessage("A", pgInt32(42) + cString("channel") + cString("payload")),
            pgMessage("t", pgInt16(2) + pgInt32(23) + pgInt32(25)),
            pgMessage("G", [0] + pgInt16(0)) + pgMessage("d", Array("1\t\\N\ta\\tb\n2\t\\\\N\t\\x\n".utf8))
                + pgMessage("c", []) + pgMessage("C", cString("COPY 2")),
            pgMessage("D", pgInt16(1) + pgInt32(16) + [0, 1, 0, 0, 0, 0, 0, 0, 0, 0x01, 0xE2, 0x40, 0, 0, 0, 0]),
        ]
    }

    // MARK: Builders

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

    private static func qpackBlock(_ fields: [(String, String)]) -> [UInt8] {
        var block = ByteBuffer()
        defer { block.destroy() }
        let encoder = QPACKEncoder()
        encoder.begin(into: &block)
        for (name, value) in fields {
            let n = Array(name.utf8), v = Array(value.utf8)
            n.withUnsafeBufferPointer { np in
                v.withUnsafeBufferPointer { vp in
                    encoder.encode(name: np.baseAddress!, nameLength: n.count,
                                   value: vp.baseAddress ?? np.baseAddress!, valueLength: v.count, into: &block)
                }
            }
        }
        return hsBytes(block.readPointer, block.readableBytes)
    }

    private static func h3Headers(_ fields: [(String, String)]) -> [UInt8] {
        let block = qpackBlock(fields)
        return hsVarint(1) + hsVarint(UInt64(block.count)) + block
    }

    private static func h2Frame(_ type: UInt8, _ flags: UInt8, _ stream: UInt32, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return [UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n),
                type, flags] + pgInt32(Int32(bitPattern: stream & 0x7FFF_FFFF)) + payload
    }

    private static func pgMessage(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue!] + pgInt32(Int32(body.count + 4)) + body
    }

    private static func pgInt32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }

    private static func pgInt16(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8(u >> 8), UInt8(u & 0xFF)]
    }

    private static func cString(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

    /// A ClientHello as the tests' client writes one, with every random
    /// field fixed. The key share is any 32 bytes: X25519 takes them all.
    private static func clientHello(serverName: String?, alpn offered: [String], group: Int = 0x001d) -> [UInt8] {
        var extensions: [UInt8] = []
        func add(_ type: Int, _ body: [UInt8]) { extensions += hsU16(type) + hsU16(body.count) + body }

        if let serverName {
            let name = Array(serverName.utf8)
            add(0, hsU16(name.count + 3) + [0] + hsU16(name.count) + name)      // server_name
        }
        add(10, hsU16(4) + hsU16(group) + hsU16(0x001d))                         // supported_groups
        let schemes = [0x0403, 0x0804, 0x0807, 0x0503]
        add(13, hsU16(schemes.count * 2) + schemes.flatMap { hsU16($0) })        // signature_algorithms
        let protocols = offered.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
        add(16, hsU16(protocols.count) + protocols)                              // ALPN
        add(43, [2, 3, 4])                                                       // supported_versions
        let share = [UInt8](repeating: 0x09, count: group == 0x001d ? 32 : 65)
        add(51, hsU16(share.count + 4) + hsU16(group) + hsU16(share.count) + share)   // key_share

        var parameters = QUICTransportParameters()
        parameters.maxIdleTimeoutMs = 30_000
        parameters.initialMaxData = 1 << 20
        parameters.initialMaxStreamDataBidiLocal = 1 << 18
        parameters.initialMaxStreamDataBidiRemote = 1 << 18
        parameters.initialMaxStreamDataUni = 1 << 18
        parameters.initialMaxStreamsBidi = 100
        parameters.initialMaxStreamsUni = 100
        // Any ID will do: the server only checks it against the header.
        parameters.initialSourceCID = [UInt8](repeating: 0x22, count: 8).withUnsafeBufferPointer {
            QUICConnectionID($0.baseAddress!, $0.count)!
        }
        parameters.hasInitialSourceCID = true
        var encoded = ByteBuffer()
        defer { encoded.destroy() }
        parameters.encode(into: &encoded, isServer: false)
        add(57, hsBytes(encoded.readPointer, encoded.readableBytes))             // transport parameters

        var body: [UInt8] = [3, 3] + [UInt8](repeating: 0x42, count: 32) + [0]   // no session ID
        body += hsU16(2) + hsU16(0x1301)
        body += [1, 0]
        body += hsU16(extensions.count) + extensions
        return [1] + hsU24(body.count) + body
    }
}
