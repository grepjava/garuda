//===----------------------------------------------------------------------===//
// Compressing a response body as it is written.
//
// The encoder sits between the application's bytes and the framing, and it is
// the same encoder for every transport: on HTTP/1.1 its output is chunked, on
// HTTP/2 and HTTP/3 the stream flushers turn it into DATA frames like any other
// body. What changes per transport is only where the Content-Encoding header
// goes, and that is in the writers.
//
// A compressed response has no Content-Length, because nobody knows it until
// the last byte. The application's own declared length is still enforced -- it
// is a promise about how much the application sends, and the checks against it
// are made on the bytes going in, not on the bytes coming out.
//
// Each body message the application sends is flushed through, so what it sent
// is what the client can read. A streaming response compressed any other way
// holds its bytes in the compressor until enough pile up, which for a progress
// report or a long poll is until it is too late.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// One response body's compressor, or nothing.
///
/// A plain struct holding a C handle, so that it can live in a connection
/// slot. Copies share the handle; whoever holds the last one
/// calls `destroy`.
public struct ResponseEncoder {
    public private(set) var coding: ContentCoding = .identity
    @usableFromInline var handle: UnsafeMutableRawPointer? = nil
    /// Where compressed bytes wait to be framed as a chunk, whose length has
    /// to be known before it is written.
    @usableFromInline var scratch = ByteBuffer()

    public init() {}

    @inlinable public var active: Bool { handle != nil }

    /// Begins compressing with `coding`. False when it cannot be had.
    public mutating func start(_ coding: ContentCoding) -> Bool {
        destroy()
        guard coding != .identity,
              let h = av_enc_new(Int32(coding.rawValue)) else { return false }
        handle = h
        self.coding = coding
        return true
    }

    /// Compresses `n` bytes onto `out`.
    ///
    /// `flush` makes everything so far readable by the client now; without it
    /// the compressor keeps what it likes for a better ratio.
    public mutating func encode(_ p: UnsafePointer<UInt8>, _ n: Int, flush: Bool,
                                into out: inout ByteBuffer, chunked: Bool) -> Bool {
        run(p, n, flush ? AV_ENC_FLUSH : AV_ENC_CONTINUE, into: &out, chunked: chunked)
    }

    /// Ends the compressed stream and releases the compressor.
    public mutating func finish(into out: inout ByteBuffer, chunked: Bool) -> Bool {
        let ok = run(nil, 0, AV_ENC_FINISH, into: &out, chunked: chunked)
        destroy()
        return ok
    }

    public mutating func destroy() {
        if let handle { av_enc_free(handle) }
        handle = nil
        coding = .identity
        scratch.destroy()
    }

    private mutating func run(_ p: UnsafePointer<UInt8>?, _ n: Int, _ mode: Int32,
                              into out: inout ByteBuffer, chunked: Bool) -> Bool {
        guard let handle else { return false }
        if chunked {
            // The chunk size goes before the bytes, so they are gathered first.
            // Nothing is written when nothing came out: a zero-length chunk is
            // the end of the message, not an empty piece of it.
            scratch.clear()
            if !ResponseEncoder.drive(handle, p, n, mode, &scratch) { return false }
            if scratch.readableBytes > 0 {
                HTTPResponseWriter.writeChunk(&out, UnsafePointer(scratch.readPointer),
                                              scratch.readableBytes)
                scratch.clear()
            }
            return true
        }
        return ResponseEncoder.drive(handle, p, n, mode, &out)
    }

    private static func drive(_ handle: UnsafeMutableRawPointer,
                              _ p: UnsafePointer<UInt8>?, _ n: Int, _ mode: Int32,
                              _ out: inout ByteBuffer) -> Bool {
        var offset = 0
        var stalls = 0
        while true {
            // Room for roughly what went in, which text rarely exceeds; the
            // loop asks again when it does.
            out.reserve(max(1024, min(n - offset, 256 * 1024) + 64))
            var consumed = 0
            var produced = 0
            let rc = av_enc_run(handle, p.map { $0 + offset }, n - offset, mode,
                                out.writePointer, out.writableBytes,
                                &consumed, &produced)
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

/// Whether this process can produce `coding`.
@inline(__always)
func codingUsable(_ coding: ContentCoding) -> Bool {
    coding != .identity && av_enc_available(Int32(coding.rawValue)) == 1
}

extension Worker {

    /// The request's `Accept-Encoding`, read while its head is still in hand.
    /// Several lines of it are one list (RFC 9110 section 5.3).
    func requestAcceptEncoding(_ slot: Int) -> AcceptEncoding {
        let c = table[slot]
        let base = c.pointee.headBase()
        var accept = AcceptEncoding()
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 15,
                  equalsLowercased(base + Int(h.name.offset), 15, "accept-encoding") else {
                continue
            }
            accept.merge(AcceptEncoding(base + Int(h.value.offset), Int(h.value.length)))
        }
        return accept
    }

    /// The coding for a response the application has just answered with, or
    /// identity. Says `Vary: Accept-Encoding` for any response a client that
    /// asked differently might have had compressed, whatever this client
    /// gets.
    mutating func chooseCoding(_ slot: Int, status: Int, count: Int, declared: Int, streaming: Bool,
                               forbids: Bool, suppress: Bool, misframed: Bool) -> ContentCoding {
        let c = table[slot]
        var eligibility = CompressionEligibility()
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            eligibility.observe(name, value)
        }
        if eligibility.mayVary(status: status) && !eligibility.varyCovered {
            addHeader(slot, "vary", "Accept-Encoding")
        }
        // A HEAD response describes the GET without a body to encode, and a
        // body that disagrees with its own length is sent as it is.
        guard !suppress, !misframed else { return .identity }
        return eligibility.choose(offered: c.pointee.acceptedCoding, status: status,
                                  bodyAllowed: !forbids,
                                  declaredLength: streaming ? declared : count,
                                  minimumLength: config.compressMinimumLength)
    }

    /// Says the response is in `coding`: Content-Encoding, no Content-Length
    /// of the unencoded body, and its strong ETags made weak, since the
    /// encoded bytes are not the ones they name.
    mutating func announceCoding(_ slot: Int, _ coding: ContentCoding) {
        let c = table[slot]
        var tags: [String] = []
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            if EntityTag.isName(name) && EntityTag.isStrong(value) { tags.append(value.string) }
        }
        let contentLength: StaticString = "content-length"
        UnsafeRawPointer(contentLength.utf8Start).withMemoryRebound(
            to: UInt8.self, capacity: contentLength.utf8CodeUnitCount) {
            removeResponseHeaders(slot, named: UnsafeBufferPointer(start: $0, count: contentLength.utf8CodeUnitCount))
        }
        if !tags.isEmpty {
            let etag: StaticString = "etag"
            UnsafeRawPointer(etag.utf8Start).withMemoryRebound(to: UInt8.self, capacity: 4) {
                removeResponseHeaders(slot, named: UnsafeBufferPointer(start: $0, count: 4))
            }
            for tag in tags { addHeader(slot, "etag", "W/" + tag) }
        }
        addHeader(slot, "content-encoding", "\(coding.token)")
    }

    /// Settles which coding a response to this request may use, if the
    /// response turns out to be one worth compressing.
    mutating func negotiateCoding(_ slot: Int) {
        let c = table[slot]
        c.pointee.acceptedCoding = config.compress
            ? requestAcceptEncoding(slot).choose(codingUsable)
            : .identity
    }
}
