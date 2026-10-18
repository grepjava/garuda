//===----------------------------------------------------------------------===//
// --compress: compressing response bodies for clients that accept it.
//
// What the client accepts is settled when the request is dispatched, from
// its Accept-Encoding (ContentCoding.swift in GarudaWire). Whether this
// response is worth compressing is settled from its own headers once they
// are final: text and its structured kin are, images and archives are not,
// nor a body the application encoded itself, one marked no-transform, a
// partial one, an event stream, or one too small to gain anything.
//
// A whole body is compressed at once and states its compressed length. A
// streamed one is compressed as it is written, each write flushed through
// so the client can read what the handler sent: chunked on HTTP/1.1, plain
// DATA on HTTP/2, and no Content-Length either way. The application's own
// declared length is still the limit on what it may write -- counted in its
// bytes, before compression.
//
// A response that could be compressed for some client says Vary:
// Accept-Encoding to every client, compressed or not, or a cache would hand
// one client's copy to the next. A strong ETag on a compressed body is sent
// weak: the bytes it named are not the ones sent.
//===----------------------------------------------------------------------===//

import VegaWire
import CVegaCompress
import GarudaWire

/// One response body's compressor.
final class ResponseEncoder: @unchecked Sendable {
    let coding: ContentCoding
    private let handle: UnsafeMutableRawPointer
    /// Where compressed bytes wait to be framed as a chunk, whose length has
    /// to be known before it is written.
    private var scratch = ByteBuffer()

    init?(_ coding: ContentCoding) {
        guard coding != .identity, let handle = cv_enc_new(Int32(coding.rawValue), 0) else { return nil }
        self.coding = coding
        self.handle = handle
    }

    deinit {
        cv_enc_free(handle)
        scratch.destroy()
    }

    /// Compresses `n` bytes onto `out`. `flush` makes everything so far
    /// readable by the client now; without it the codec keeps what it likes
    /// for a better ratio.
    func encode(_ p: UnsafePointer<UInt8>?, _ n: Int, flush: Bool, into out: inout ByteBuffer,
                chunked: Bool) -> Bool {
        run(p, n, flush ? CV_ENC_FLUSH : CV_ENC_CONTINUE, into: &out, chunked: chunked)
    }

    /// Ends the compressed stream.
    func finish(into out: inout ByteBuffer, chunked: Bool) -> Bool {
        run(nil, 0, CV_ENC_FINISH, into: &out, chunked: chunked)
    }

    private func run(_ p: UnsafePointer<UInt8>?, _ n: Int, _ mode: Int32, into out: inout ByteBuffer,
                     chunked: Bool) -> Bool {
        guard chunked else { return drive(p, n, mode, &out) }
        // The chunk size goes before the bytes, so they are gathered first.
        // Nothing is written when nothing came out: a zero-length chunk is
        // the end of the message, not an empty piece of it.
        scratch.clear()
        guard drive(p, n, mode, &scratch) else { return false }
        if scratch.readableBytes > 0 {
            HTTPResponseWriter.writeChunk(&out, UnsafePointer(scratch.readPointer), scratch.readableBytes)
            scratch.clear()
        }
        return true
    }

    private func drive(_ p: UnsafePointer<UInt8>?, _ n: Int, _ mode: Int32, _ out: inout ByteBuffer) -> Bool {
        var offset = 0
        var stalls = 0
        while true {
            // Room for roughly what went in, which text rarely exceeds; the
            // loop asks again when it does.
            out.reserve(max(1024, min(n - offset, 256 * 1024) + 64))
            var consumed = 0
            var produced = 0
            let rc = cv_enc_run(handle, p.map { $0 + offset }, n - offset, mode,
                                out.writePointer, out.writableBytes, &consumed, &produced)
            offset += consumed
            out.advanceWriter(produced)
            if rc < 0 { return false }
            if rc == 0 { return true }
            // A codec that asks to be called again and then does nothing with
            // the room it was given would otherwise spin here forever.
            if consumed == 0 && produced == 0 {
                stalls += 1
                if stalls > 2 { return false }
            } else {
                stalls = 0
            }
        }
    }
}

/// Whether this process can produce `coding`: brotli and zstd only where
/// their libraries are.
func codingUsable(_ coding: ContentCoding) -> Bool {
    coding != .identity && cv_enc_available(Int32(coding.rawValue)) == 1
}

extension Exchange {
    /// The request's Accept-Encoding, every line of it one list (RFC 9110
    /// section 5.3).
    func acceptEncoding() -> AcceptEncoding {
        var accept = AcceptEncoding()
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i &+= 1
            let name = slice(h.name)
            guard name.count == 15, equalsLowercased(name.base, 15, "accept-encoding") else { continue }
            let value = slice(h.value)
            accept.merge(AcceptEncoding(value.base, value.count))
        }
        return accept
    }

    /// Settles which coding an answer to this request may use, if it turns
    /// out to be one worth compressing.
    mutating func negotiateCoding() {
        acceptedCoding = acceptEncoding().choose(codingUsable)
    }

    /// What the response's headers say about compressing it, and the length
    /// the application declared, or -1. Says Vary: Accept-Encoding for a
    /// response that some client could have had compressed.
    mutating func compressionEligibility() -> (CompressionEligibility, declared: Int) {
        var eligibility = CompressionEligibility()
        var declared = -1
        forEachResponseHeader { name, value in
            eligibility.observe(name, value)
            if HTTPResponseWriter.classify(name) == .contentLength { declared = value.integer ?? -1 }
        }
        if eligibility.mayVary(status: status) && !eligibility.varyCovered {
            _ = addHeader(ByteSpan(StaticString("vary").utf8Start, 4),
                          ByteSpan(StaticString("Accept-Encoding").utf8Start, 15))
        }
        return (eligibility, declared)
    }

    /// Compresses a whole answer about to be written, when it should be:
    /// the body is replaced by its compressed form, and the head says so.
    /// `omitBody`: a HEAD, which says Vary as the GET would and is not
    /// encoded.
    mutating func compressAnswer(omitBody: Bool) {
        let (eligibility, declared) = compressionEligibility()
        let count = responseBodyCount
        let forbids = HTTPResponseWriter.statusForbidsBody(status)
        // A body that disagrees with its own length is sent as it is.
        let misframed = !forbids && declared >= 0 && declared != count
        guard !omitBody, !misframed else { return }
        let coding = eligibility.choose(offered: acceptedCoding, status: status, bodyAllowed: !forbids,
                                        declaredLength: count, minimumLength: compressMinimum)
        guard coding != .identity, let encoder = ResponseEncoder(coding) else { return }
        settleHeldBody()
        compressed.clear()
        guard encoder.encode(UnsafePointer(responseBody.readPointer), count, flush: false, into: &compressed,
                             chunked: false),
              encoder.finish(into: &compressed, chunked: false) else { return }
        swap(&responseBody, &compressed)
        announceCoding(coding)
    }

    /// The encoder for a streamed body about to start, or nil. `declared`
    /// is the length the application gave, or -1.
    mutating func streamEncoder(bodyless: Bool) -> ResponseEncoder? {
        let (eligibility, declared) = compressionEligibility()
        guard !bodyless else { return nil }
        let coding = eligibility.choose(offered: acceptedCoding, status: status, bodyAllowed: true,
                                        declaredLength: declared, minimumLength: compressMinimum)
        guard coding != .identity, let encoder = ResponseEncoder(coding) else { return nil }
        announceCoding(coding)
        return encoder
    }

    /// Says the response is in `coding`: Content-Encoding, no Content-Length
    /// of the unencoded body, and its strong ETags made weak.
    mutating func announceCoding(_ coding: ContentCoding) {
        var tags: [[UInt8]] = []
        forEachResponseHeader { name, value in
            if EntityTag.isName(name) && EntityTag.isStrong(value) {
                tags.append(Array(UnsafeBufferPointer(start: value.base, count: value.count)))
            }
        }
        let contentLength: StaticString = "content-length"
        removeResponseHeaders(named: UnsafeBufferPointer(start: contentLength.utf8Start,
                                                         count: contentLength.utf8CodeUnitCount))
        if !tags.isEmpty {
            let etag: StaticString = "etag"
            removeResponseHeaders(named: UnsafeBufferPointer(start: etag.utf8Start, count: 4))
            for tag in tags {
                let weak = Array("W/".utf8) + tag
                weak.withUnsafeBufferPointer {
                    _ = addHeader(ByteSpan(StaticString("etag").utf8Start, 4), ByteSpan($0.baseAddress!, $0.count))
                }
            }
        }
        let token = coding.token
        _ = addHeader(ByteSpan(StaticString("content-encoding").utf8Start, 16),
                      ByteSpan(token.utf8Start, token.utf8CodeUnitCount))
    }
}
