import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

/// ByteBuffer intentionally has no `String` overload -- the server never builds
/// one. Tests bridge explicitly.
private func append(_ b: inout ByteBuffer, _ s: String) {
    let a = Array(s.utf8)
    a.withUnsafeBufferPointer { b.write($0.baseAddress!, $0.count) }
}

private func contents(_ b: borrowing ByteBuffer) -> String {
    String(decoding: UnsafeBufferPointer(start: b.readPointer, count: b.readableBytes),
           as: UTF8.self)
}

@Suite("Byte primitives")
struct ByteTests {

    @Test("decimal round-trips through the writer and the parser")
    func decimalRoundTrip() {
        let values = [0, 1, 9, 10, 99, 100, 12345, 1_000_000, Int(UInt32.max)]
        var buf = [UInt8](repeating: 0, count: 24)
        for v in values {
            let n = buf.withUnsafeMutableBufferPointer { writeDecimal(v, $0.baseAddress!) }
            let back = buf.withUnsafeBufferPointer { parseDecimal($0.baseAddress!, n) }
            #expect(back == v, "\(v)")
        }
    }

    @Test("a non-digit or an over-long run is rejected rather than truncated")
    func decimalRejects() {
        func p(_ s: String) -> Int {
            Array(s.utf8).withUnsafeBufferPointer { parseDecimal($0.baseAddress!, $0.count) }
        }
        #expect(p("12a") == -1)
        #expect(p("") == -1)
        #expect(p(" 12") == -1)
        #expect(p("99999999999999999999999") == -1)
    }

    @Test("hex parsing covers both cases and rejects junk")
    func hex() {
        func p(_ s: String) -> Int {
            Array(s.utf8).withUnsafeBufferPointer { parseHex($0.baseAddress!, $0.count) }
        }
        #expect(p("0") == 0)
        #expect(p("ff") == 255)
        #expect(p("FF") == 255)
        #expect(p("1a2B") == 0x1A2B)
        #expect(p("g") == -1)
        #expect(p("") == -1)
    }

    @Test("case-insensitive comparison folds only the input side")
    func caseInsensitive() {
        func eq(_ s: String, _ lit: StaticString) -> Bool {
            Array(s.utf8).withUnsafeBufferPointer {
                equalsLowercased($0.baseAddress!, $0.count, lit)
            }
        }
        #expect(eq("Content-Length", "content-length"))
        #expect(eq("CONTENT-LENGTH", "content-length"))
        #expect(eq("content-length", "content-length"))
        #expect(!eq("content-lengths", "content-length"))
        #expect(!eq("content", "content-length"))
    }

    @Test("token search matches whole tokens only")
    func tokenSearch() {
        func has(_ s: String, _ lit: StaticString) -> Bool {
            Array(s.utf8).withUnsafeBufferPointer {
                containsTokenLowercased($0.baseAddress!, $0.count, lit)
            }
        }
        #expect(has("close", "close"))
        #expect(has("keep-alive, close", "close"))
        #expect(has("Close", "close"))
        #expect(!has("closely", "close"))
        #expect(!has("disclose", "close"))
        #expect(has("100-continue", "100-continue"))
    }

    @Test("percent decoding handles valid escapes and leaves broken ones alone")
    func percentDecoding() {
        func decode(_ s: String) -> String {
            var src = Array(s.utf8)
            var dst = [UInt8](repeating: 0, count: src.count)
            let n = src.withUnsafeMutableBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    percentDecode(sp.baseAddress!, sp.count, into: dp.baseAddress!)
                }
            }
            return String(decoding: dst[0..<n], as: UTF8.self)
        }
        #expect(decode("/a%20b") == "/a b")
        #expect(decode("/a%2Fb") == "/a/b")
        #expect(decode("/plain") == "/plain")
        #expect(decode("/a%zzb") == "/a%zzb")     // invalid escape passes through
        #expect(decode("/trailing%2") == "/trailing%2")
        #expect(decode("%41%42%43") == "ABC")
    }

    @Test("tchar classification matches RFC 9110")
    func tokenChars() {
        for c in Array("abcXYZ019!#$%&'*+-.^_`|~".utf8) {
            #expect(isTokenChar(c), "\(Character(UnicodeScalar(c)))")
        }
        for c in Array(": ()<>@,;\\\"/[]?={}\t".utf8) {
            #expect(!isTokenChar(c), "\(Character(UnicodeScalar(c)))")
        }
        #expect(!isTokenChar(0))
        #expect(!isTokenChar(0x80))
    }
}

@Suite("ByteBuffer")
struct ByteBufferTests {

    @Test("writes accumulate and reads consume")
    func writeAndConsume() {
        var b = ByteBuffer(capacity: 8)
        defer { b.destroy() }
        b.write("hello")
        #expect(b.readableBytes == 5)
        b.consume(2)
        #expect(b.readableBytes == 3)
        #expect(b.readPointer[0] == UInt8(ascii: "l"))
        b.consume(3)
        #expect(b.isEmpty)
        // Draining resets the indices so the next write starts at the front.
        #expect(b.readerOffset == 0)
    }

    @Test("growth preserves contents across a reallocation")
    func growth() {
        var b = ByteBuffer(capacity: 4)
        defer { b.destroy() }
        let payload = String(repeating: "abcdefgh", count: 500)
        append(&b, payload)
        #expect(b.readableBytes == payload.count)
        let copy = String(decoding: UnsafeBufferPointer(start: b.readPointer,
                                                        count: b.readableBytes), as: UTF8.self)
        #expect(copy == payload)
    }

    @Test("compaction moves unread bytes to the front")
    func compaction() {
        var b = ByteBuffer(capacity: 32)
        defer { b.destroy() }
        b.write("0123456789")
        b.consume(6)
        b.compact()
        #expect(b.readerOffset == 0)
        #expect(b.readableBytes == 4)
        let s = String(decoding: UnsafeBufferPointer(start: b.readPointer, count: 4), as: UTF8.self)
        #expect(s == "6789")
    }

    @Test("decimal and hex writers append correctly")
    func numericWriters() {
        var b = ByteBuffer(capacity: 8)
        defer { b.destroy() }
        b.writeDecimal(0)
        b.writeByte(UInt8(ascii: "|"))
        b.writeDecimal(4096)
        b.writeByte(UInt8(ascii: "|"))
        b.writeHex(0)
        b.writeByte(UInt8(ascii: "|"))
        b.writeHex(4096)
        let s = String(decoding: UnsafeBufferPointer(start: b.readPointer,
                                                     count: b.readableBytes), as: UTF8.self)
        #expect(s == "0|4096|0|1000")
    }
}

@Suite("Buffer pool")
struct BufferPoolTests {

    @Test("blocks are recycled and oversized ones are released")
    func recycling() {
        var pool = BufferPool(blockSize: 64, maxRetained: 4)
        defer { pool.destroy() }

        let a = pool.take()
        #expect(a.allocatedCapacity == 64)
        #expect(pool.outstanding == 1)
        let firstAddress = UInt(bitPattern: a.pointer(at: 0))
        pool.give(a)
        #expect(pool.outstanding == 0)

        // LIFO: the block just returned is the one handed back next.
        let b = pool.take()
        #expect(UInt(bitPattern: b.pointer(at: 0)) == firstAddress)
        pool.give(b)

        // A buffer that outgrew the block size must not poison the pool.
        var big = pool.take()
        append(&big, String(repeating: "x", count: 500))
        #expect(big.allocatedCapacity > 64)
        pool.give(big)
        let c = pool.take()
        #expect(c.allocatedCapacity == 64)
        pool.give(c)
    }
}

@Suite("Chunked decoding")
struct ChunkedDecoderTests {

    /// Feeds `text` in slices of `step` bytes to prove the decoder resumes at
    /// any byte boundary.
    private func decode(_ text: String, step: Int,
                        maxTrailerBytes: Int = 32 * 1024) -> (String, ChunkedDecoder.Outcome) {
        var decoder = ChunkedDecoder(maxTrailerBytes: maxTrailerBytes)
        var out = [UInt8]()
        let pending = Array(text.utf8)
        var outcome = ChunkedDecoder.Outcome.needMore
        var offset = 0

        while offset < pending.count {
            let end = min(offset + step, pending.count)
            var consumedTotal = 0
            let slice = Array(pending[offset..<end])
            slice.withUnsafeBufferPointer { buf in
                var consumed = 0
                outcome = decoder.decode(buf.baseAddress!, buf.count, consumed: &consumed) { p, n in
                    out.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
                }
                consumedTotal = consumed
            }
            offset += consumedTotal
            if consumedTotal == 0 { break }
            if case .finished = outcome { break }
            if case .failure = outcome { break }
        }
        _ = pending
        return (String(decoding: out, as: UTF8.self), outcome)
    }

    @Test("a simple chunked body decodes whole")
    func simple() {
        let text = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let (body, outcome) = decode(text, step: text.utf8.count)
        #expect(body == "hello world")
        if case .finished = outcome {} else { Issue.record("expected finished") }
    }

    @Test("decoding resumes correctly at every byte boundary")
    func resumable() {
        let text = "5\r\nhello\r\na\r\n0123456789\r\n0\r\n\r\n"
        for step in 1...text.utf8.count {
            let (body, outcome) = decode(text, step: step)
            #expect(body == "hello0123456789", "step \(step)")
            if case .finished = outcome {} else { Issue.record("step \(step): not finished") }
        }
    }

    @Test("a trailer field ends where it ends, however the reads fell")
    func trailersResumable() {
        // Found by pgfuzz. A trailer field skipped in one read, and then its
        // own terminating LF arriving in the next, used to be read as the
        // empty line that ends the trailer section -- so the message ended a
        // line early for a peer that wrote slowly, and the CRLF it did not
        // consume became the start of whatever came next.
        let text = "1\r\na\r\n0\r\nX-Trailer: value\r\n\r\n"
        for step in 1...text.utf8.count {
            let (body, outcome) = decode(text, step: step)
            #expect(body == "a", "step \(step)")
            if case .finished = outcome {} else { Issue.record("step \(step): not finished") }
        }
        // The same line without the section terminator behind it is not the
        // end of anything, at any step.
        let unfinished = "1\r\na\r\n0\r\nX-Trailer: value\r\n"
        for step in 1...unfinished.utf8.count {
            let (_, outcome) = decode(unfinished, step: step)
            if case .finished = outcome { Issue.record("step \(step): finished early") }
        }
    }

    @Test("chunk extensions are skipped")
    func extensions() {
        let text = "5;name=value\r\nhello\r\n0\r\n\r\n"
        let (body, outcome) = decode(text, step: text.utf8.count)
        #expect(body == "hello")
        if case .finished = outcome {} else { Issue.record("expected finished") }
    }

    @Test("trailer fields are consumed before finishing")
    func trailers() {
        let text = "5\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n"
        let (body, outcome) = decode(text, step: text.utf8.count)
        #expect(body == "hello")
        if case .finished = outcome {} else { Issue.record("expected finished") }
    }

    @Test("a trailer section past its limit fails instead of going on forever")
    func trailersBounded() {
        // Trailers decode to no body, so the body limit never grows while they
        // arrive: without a ceiling of their own a peer could stream them for
        // as long as it liked and hold the connection for free.
        let field = "X-Pad: aaaaaaaaaaaaaaaaaaaa\r\n"
        let under = "1\r\na\r\n0\r\n" + String(repeating: field, count: 3) + "\r\n"
        let (body, ok) = decode(under, step: 8, maxTrailerBytes: 256)
        #expect(body == "a")
        if case .finished = ok {} else { Issue.record("a small trailer section should pass") }

        let over = "1\r\na\r\n0\r\n" + String(repeating: field, count: 40) + "\r\n"
        let (_, outcome) = decode(over, step: 8, maxTrailerBytes: 256)
        if case .failure(let e) = outcome {
            #expect(e.status == 431)
        } else {
            Issue.record("expected failure")
        }
    }

    @Test("a malformed chunk size fails instead of guessing")
    func malformed() {
        let (_, outcome) = decode("zz\r\nhello\r\n", step: 32)
        if case .failure = outcome {} else { Issue.record("expected failure") }
    }

    @Test("a chunk not terminated by CRLF fails")
    func badTerminator() {
        let (_, outcome) = decode("5\r\nhelloXX0\r\n\r\n", step: 32)
        if case .failure = outcome {} else { Issue.record("expected failure") }
    }
}

@Suite("Response writing")
struct ResponseWriterTests {

    private func rendered(_ build: (inout ByteBuffer) -> Void) -> String {
        var b = ByteBuffer(capacity: 128)
        defer { b.destroy() }
        build(&b)
        return String(decoding: UnsafeBufferPointer(start: b.readPointer,
                                                    count: b.readableBytes), as: UTF8.self)
    }

    @Test("status lines carry the right reason phrase")
    func statusLines() {
        #expect(rendered { HTTPResponseWriter.writeStatusLine(&$0, status: 200) }
                == "HTTP/1.1 200 OK\r\n")
        #expect(rendered { HTTPResponseWriter.writeStatusLine(&$0, status: 404) }
                == "HTTP/1.1 404 Not Found\r\n")
        #expect(rendered { HTTPResponseWriter.writeStatusLine(&$0, status: 599) }
                == "HTTP/1.1 599 Server Error\r\n")
    }

    @Test("a header containing CR or LF is refused (response splitting)")
    func responseSplitting() {
        func write(_ name: String, _ value: String) -> Bool {
            var b = ByteBuffer(capacity: 64)
            defer { b.destroy() }
            var n = Array(name.utf8)
            var v = Array(value.utf8)
            return n.withUnsafeMutableBufferPointer { np in
                v.withUnsafeMutableBufferPointer { vp in
                    HTTPResponseWriter.writeHeader(
                        &b,
                        name: ByteSpan(UnsafePointer(np.baseAddress!), np.count),
                        value: ByteSpan(UnsafePointer(vp.baseAddress!), vp.count))
                }
            }
        }
        #expect(write("X-Safe", "value"))
        #expect(!write("X-Bad", "a\r\nX-Injected: 1"))
        #expect(!write("X-Bad", "a\nb"))
        #expect(!write("Bad Name", "v"))
        #expect(!write("X:Bad", "v"))
    }

    @Test("chunk framing is correct, including the terminator")
    func chunkFraming() {
        let out = rendered { buf in
            var data = Array("hello".utf8)
            data.withUnsafeMutableBufferPointer { p in
                HTTPResponseWriter.writeChunk(&buf, UnsafePointer(p.baseAddress!), p.count)
            }
            HTTPResponseWriter.writeLastChunk(&buf)
        }
        #expect(out == "5\r\nhello\r\n0\r\n\r\n")
    }

    @Test("statuses that forbid a body are recognised")
    func bodilessStatuses() {
        #expect(HTTPResponseWriter.statusForbidsBody(204))
        #expect(HTTPResponseWriter.statusForbidsBody(304))
        #expect(HTTPResponseWriter.statusForbidsBody(100))
        #expect(!HTTPResponseWriter.statusForbidsBody(200))
        #expect(!HTTPResponseWriter.statusForbidsBody(404))
    }
}

@Suite("HTTP date cache")
struct DateCacheTests {

    @Test("the cached Date header is a well-formed IMF-fixdate")
    func format() {
        let cache = DateCache()
        defer { cache.destroy() }
        let s = String(decoding: UnsafeBufferPointer(start: cache.bytes, count: cache.count),
                       as: UTF8.self)
        #expect(s.count == 29)
        #expect(s.hasSuffix(" GMT"))
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        #expect(days.contains(String(s.prefix(3))))
        #expect(Array(s)[3] == ",")
        #expect(Array(s)[19] == ":")
        #expect(Array(s)[22] == ":")
    }
}
