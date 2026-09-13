//===----------------------------------------------------------------------===//
// Turning a WSGI application's return value into response bytes.
//
// This is shared by the two execution models: the inline one, where the worker
// loop calls the application itself, and the pooled one, where a thread does.
// Both must produce byte-for-byte identical output, so the framing decision and
// the header serialisation live here rather than in either caller.
//
// Everything the builder needs about the request is captured in a snapshot
// first. That matters for the pooled path: a thread must not read connection
// state the loop could be changing underneath it, so it reads a copy taken at
// submit time instead.
//
// Framing is decided after the application returns, with full information:
//   * the application set Content-Length      -> pass it through
//   * the result is a list or tuple           -> sum the parts, set it ourselves
//   * HTTP/1.1 and unknown length             -> chunked
//   * HTTP/1.0 and unknown length             -> stream and close
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineWSGI

/// Everything about the request the response builder needs, copied so that it
/// stays valid however long the application runs.
public struct WSGIRequestSnapshot {
    public var httpMinor: UInt8 = 1
    public var keepAlive = true
    /// HEAD: send the headers, produce no body.
    public var suppressBody = false
    /// 29 bytes of IMF-fixdate. Borrowed; must outlive the call.
    public var date: UnsafePointer<UInt8>
    /// The Alt-Svc value advertising HTTP/3, or nil. Borrowed; lives for the
    /// process.
    public var altSvc: UnsafePointer<UInt8>? = nil
    public var altSvcLength = 0
    /// The Strict-Transport-Security value --hsts asked for, or nil. Borrowed;
    /// lives for the process.
    public var hsts: UnsafePointer<UInt8>? = nil
    public var hstsLength = 0
    /// This request's --request-id, or nil. Borrowed; the caller keeps it
    /// alive for as long as the snapshot is used.
    public var requestID: UnsafePointer<UInt8>? = nil
    public var requestIDLength = 0
    /// The response travels on a multiplexed stream (HTTP/2 or HTTP/3), where
    /// the head is a compressed header block rather than text, there is no
    /// transfer encoding, and the stream ending is the framing.
    public var multiplexed = false
    /// --compress, and the coding the client accepts best. Separate because a
    /// response that could be compressed says `Vary: Accept-Encoding` even to
    /// a client that accepts nothing.
    public var compress = false
    public var offeredCoding: ContentCoding = .identity
    public var compressMinimumLength = 1024

    public init(httpMinor: UInt8, keepAlive: Bool, suppressBody: Bool,
                date: UnsafePointer<UInt8>,
                altSvc: UnsafePointer<UInt8>? = nil, altSvcLength: Int = 0,
                hsts: UnsafePointer<UInt8>? = nil, hstsLength: Int = 0,
                requestID: UnsafePointer<UInt8>? = nil, requestIDLength: Int = 0,
                multiplexed: Bool = false,
                compress: Bool = false, offeredCoding: ContentCoding = .identity,
                compressMinimumLength: Int = 1024) {
        self.requestID = requestID
        self.requestIDLength = requestIDLength
        self.httpMinor = httpMinor
        self.keepAlive = keepAlive
        self.suppressBody = suppressBody
        self.date = date
        self.altSvc = altSvc
        self.altSvcLength = altSvcLength
        self.hsts = hsts
        self.hstsLength = hstsLength
        self.multiplexed = multiplexed
        self.compress = compress
        self.offeredCoding = offeredCoding
        self.compressMinimumLength = compressMinimumLength
    }
}

/// The outcome of serialising the response head.
public struct WSGIHeadPlan {
    public var ok = false
    public var status = 0
    public var chunked = false
    /// Recomputed: a `Connection: close` from the application turns it off, and
    /// an unknown length on HTTP/1.0 makes the close itself the framing.
    public var keepAlive = true
    /// HEAD, 204, 304 and 1xx: headers only.
    public var suppressBody = false
    /// The Content-Length that went out, or -1 when the framing is the end of
    /// the message rather than a declared length.
    public var declaredLength = -1
    /// The coding the body is compressed with. When it is not identity, no
    /// Content-Length went out and `declaredLength` is the application's own,
    /// enforced against what it produces.
    public var coding: ContentCoding = .identity
    /// A message for the log when `ok` is false.
    public var failure: StaticString = ""
}

/// Accounts a response body against the Content-Length its head declared.
///
/// A declared length is a promise about where the message ends, and on a
/// keep-alive connection it is the only thing that says so: bytes past it are
/// read as the start of the next response, and bytes short of it leave the
/// client waiting for a body that is never coming. So the length is enforced
/// rather than merely written. The wire keeps the promise whatever the
/// application does -- excess never reaches it -- and the caller closes the
/// connection afterwards, because a message that is not the length it declared
/// cannot be followed by another one.
///
/// This is the same contract the ASGI path applies through
/// `Connection.responseRemaining`; it lives here because a pooled WSGI thread
/// owns no connection to keep it on.
public struct WSGIBodyLimit {
    /// Bytes still owed, or -1 when nothing was declared -- then the framing
    /// is chunked or the end of the message, and there is nothing to enforce.
    public private(set) var remaining = -1
    /// The application produced more than it declared.
    public private(set) var overflowed = false

    public init() {}

    /// Begins accounting for a head that has just gone out.
    ///
    /// A suppressed body (HEAD, 204, 304) declares a length that nobody is
    /// going to send, so it is not accounted at all.
    public init(_ plan: WSGIHeadPlan) {
        if !plan.suppressBody { remaining = plan.declaredLength }
    }

    /// How many of `count` bytes may go out.
    public mutating func take(_ count: Int) -> Int {
        if remaining < 0 { return count }
        if count > remaining {
            overflowed = true
            let allowed = remaining
            remaining = 0
            return allowed
        }
        remaining -= count
        return count
    }

    /// Whether the finished message is the length the head promised. Only
    /// meaningful once the application has stopped producing.
    public var mismatched: Bool { overflowed || remaining > 0 }
}

/// The response head as a multiplexed connection needs it.
///
/// HTTP/2 and HTTP/3 compress their heads, and the compressor belongs to the
/// connection -- it is a table that both ends keep in step, so it can only be
/// touched by the thread that owns the connection. A WSGI application may be
/// running on a pool thread, which owns nothing. So the head is staged in this
/// neutral form, which any thread can write, and encoded on the loop thread
/// that owns the connection.
///
///     u32  length of everything after this field
///     u16  status
///     u16  header count
///     per header: u16 name length, u16 value length, name, value
///
/// The length prefix comes first so a reader can tell a head that is still
/// being written from one that is complete: the pool hands over bytes as they
/// are produced, and half a head is not something to start encoding.
public enum WSGIHeadBlock {
    public static let prefixLength = 4
    /// Long enough for anything a real response carries, short enough that a
    /// two-byte length is honest.
    public static let maxField = 65535

    @inlinable
    public static func begin(_ out: inout ByteBuffer) -> Int {
        let at = out.writerOffset
        for _ in 0..<8 { out.writeByte(0) }   // length, status, count
        return at
    }

    @inlinable
    public static func append(_ out: inout ByteBuffer,
                              name: ByteSpan, value: ByteSpan) -> Bool {
        if name.count > maxField || value.count > maxField { return false }
        out.writeByte(UInt8(truncatingIfNeeded: name.count >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: name.count))
        out.writeByte(UInt8(truncatingIfNeeded: value.count >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: value.count))
        out.write(name.base, name.count)
        out.write(value.base, value.count)
        return true
    }

    @inlinable
    public static func finish(_ out: inout ByteBuffer, at: Int,
                              status: Int, count: Int) {
        let total = out.writerOffset - at - prefixLength
        let p = out.pointer(at: at)
        p[0] = UInt8(truncatingIfNeeded: total >> 24)
        p[1] = UInt8(truncatingIfNeeded: total >> 16)
        p[2] = UInt8(truncatingIfNeeded: total >> 8)
        p[3] = UInt8(truncatingIfNeeded: total)
        p[4] = UInt8(truncatingIfNeeded: status >> 8)
        p[5] = UInt8(truncatingIfNeeded: status)
        p[6] = UInt8(truncatingIfNeeded: count >> 8)
        p[7] = UInt8(truncatingIfNeeded: count)
    }
}

public enum WSGIResponseBuilder {

    /// Serialises the status line and headers, and settles the framing.
    ///
    /// `result` is inspected but not consumed: a list or tuple return value can
    /// have its total length summed here, which is what lets an ordinary
    /// application get a Content-Length without declaring one.
    ///
    /// It is nil when the head is being sent from inside the application, on
    /// its first `write()`. There is no return value to measure then and there
    /// never will be one in time, so unless the application declared a
    /// Content-Length the framing is chunked.
    public static func writeHead(_ out: inout ByteBuffer,
                                 statusObj: PyObj,
                                 headerList: PyObj,
                                 startResponse: PyObj,
                                 result: PyObj?,
                                 snapshot: WSGIRequestSnapshot,
                                 capture: UnsafeMutablePointer<ResponseCapture>? = nil) -> WSGIHeadPlan {
        var plan = WSGIHeadPlan()
        plan.keepAlive = snapshot.keepAlive

        var statusLen: pg_ssize_t = 0
        guard let statusRaw = pg_str_latin1_data(statusObj, &statusLen)
                ?? pg_str_utf8_data(statusObj, &statusLen) else {
            pg_err_clear()
            plan.failure = "could not decode the response status"
            return plan
        }
        let statusPtr = UnsafeRawPointer(statusRaw).assumingMemoryBound(to: UInt8.self)
        let code = wsgiStatusCode(statusPtr, Int(statusLen))
        if code == 0 {
            plan.failure = "application returned a malformed status line"
            return plan
        }
        plan.status = code

        guard PySeq.isSequence(headerList) else {
            plan.failure = "start_response headers must be a list of pairs"
            return plan
        }

        out.reserve(512)
        // Two sinks, one walk. HTTP/1.1 gets text; a multiplexed stream gets
        // the neutral block, because the head has to survive a hand-off to the
        // thread that owns the compressor.
        var blockAt = 0
        var emitted = 0
        if snapshot.multiplexed {
            blockAt = WSGIHeadBlock.begin(&out)
        } else {
            HTTPResponseWriter.writeStatusLine(&out, raw: ByteSpan(statusPtr, Int(statusLen)))
        }

        /// Adds one header in whichever form this response is being built in.
        func emit(_ name: ByteSpan, _ value: ByteSpan) -> Bool {
            if snapshot.multiplexed {
                // The same check the text writer makes. A header that could
                // split an HTTP/1 response cannot split an HTTP/2 one, but it
                // is still not a header, and the two paths should refuse the
                // same things for the same reasons.
                var i = 0
                while i < name.count {
                    if !isTokenChar(name.base[i]) { return false }
                    i &+= 1
                }
                i = 0
                while i < value.count {
                    if !isFieldValueChar(value.base[i]) { return false }
                    i &+= 1
                }
                if !WSGIHeadBlock.append(&out, name: name, value: value) { return false }
                emitted += 1
                return true
            }
            return HTTPResponseWriter.writeHeader(&out, name: name, value: value)
        }

        func emit(_ name: StaticString, _ value: ByteSpan) -> Bool {
            emit(ByteSpan(name.utf8Start, name.utf8CodeUnitCount), value)
        }

        var seen: ResponseHeaderKind = []
        var declaredLength = -1
        var eligibility = CompressionEligibility()
        let headerCount = PySeq.count(headerList)

        var i = 0
        while i < headerCount {
            // PEP 3333 says a list of tuples, but a list of two-element lists
            // is what several frameworks build, and rejecting it buys nothing.
            guard let item = PySeq.item(headerList, i),
                  let (nameObj, valueObj) = PySeq.pair(item) else {
                plan.failure = "response headers must be (name, value) pairs"
                return plan
            }
            i += 1
            guard let nameView = PyBytesView.of(nameObj) else {
                pg_err_clear()
                plan.failure = "could not decode a response header name"
                return plan
            }
            guard let valueView = PyBytesView.of(valueObj) else {
                nameView.release()
                pg_err_clear()
                plan.failure = "could not decode a response header value"
                return plan
            }
            let name = nameView.span
            let value = valueView.span

            let kind = HTTPResponseWriter.classify(name)
            seen.formUnion(kind)
            if snapshot.compress { eligibility.observe(name, value) }
            if let capture, capture.pointee.active { capture.pointee.observe(name, value) }

            var rejection: StaticString? = nil
            if kind.contains(.contentLength) {
                declaredLength = parseDecimal(value.base, value.count)
                if declaredLength < 0 {
                    rejection = "application supplied a malformed Content-Length"
                }
                // Recorded, not echoed: the framing decision below emits
                // exactly one Content-Length.
            } else if kind.contains(.transferEncoding) {
                // The server owns transfer framing; never echo it back.
            } else if kind.contains(.connection) {
                // Connection management is the server's, not the application's.
                if containsTokenLowercased(value.base, value.count, "close") {
                    plan.keepAlive = false
                }
            } else if name.count == 0 {
                rejection = "rejected an empty response header name"
            } else if !emit(name, value) {
                // A CR or LF in an application-supplied header is a response
                // splitting attempt; refuse the whole response rather than
                // emit it.
                rejection = "rejected a response header containing control characters"
            }
            valueView.release()
            nameView.release()
            if let rejection {
                plan.failure = rejection
                return plan
            }
        }

        // --- decide framing ---
        let forbidsBody = HTTPResponseWriter.statusForbidsBody(code)
        plan.suppressBody = snapshot.suppressBody || forbidsBody
        let isSequence = result.map { PySeq.isSequence($0) } ?? false

        if forbidsBody {
            declaredLength = 0
        } else if declaredLength >= 0 {
            // Application knows its own length.
        } else if let result, isSequence {
            var total = 0
            var ok = true
            let n = PySeq.count(result)
            var k = 0
            while k < n {
                guard let part = PySeq.item(result, k), pg_is_bytes(part) != 0 else {
                    ok = false
                    break
                }
                total += Int(pg_bytes_len(part))
                k += 1
            }
            if ok { declaredLength = total }
        }

        if snapshot.compress {
            plan.coding = eligibility.choose(offered: snapshot.offeredCoding, status: code,
                                             bodyAllowed: !plan.suppressBody,
                                             declaredLength: declaredLength,
                                             minimumLength: snapshot.compressMinimumLength)
            if eligibility.mayVary(status: code) && !eligibility.varyCovered {
                if snapshot.multiplexed {
                    _ = emit("vary", ByteSpan(("accept-encoding" as StaticString).utf8Start, 15))
                } else {
                    out.write("Vary: Accept-Encoding\r\n")
                }
            }
            if plan.coding != .identity {
                let token = plan.coding.token
                if snapshot.multiplexed {
                    _ = emit("content-encoding", ByteSpan(token.utf8Start, token.utf8CodeUnitCount))
                } else {
                    out.write("Content-Encoding: ")
                    out.write(token)
                    out.writeCRLF()
                }
            }
        }

        plan.declaredLength = declaredLength
        var digits = ByteBuffer()
        defer { digits.destroy() }
        if plan.coding != .identity {
            // The compressed length is unknown until the end, whatever the
            // application declared; see WSGIHeadPlan.coding.
            if snapshot.multiplexed {
                // The stream ending is the framing.
            } else if snapshot.httpMinor == 1 {
                plan.chunked = true
                HTTPResponseWriter.writeChunkedEncoding(&out)
            } else {
                plan.keepAlive = false
            }
        } else if declaredLength >= 0 {
            if snapshot.multiplexed {
                digits.writeDecimal(declaredLength)
                _ = emit("content-length",
                         ByteSpan(UnsafePointer(digits.readPointer), digits.readableBytes))
            } else {
                HTTPResponseWriter.writeContentLength(&out, declaredLength)
            }
        } else if snapshot.multiplexed {
            // Nothing to declare and nothing to chunk: on a multiplexed
            // stream the ending of the stream is the framing.
        } else if snapshot.httpMinor == 1 {
            plan.chunked = true
            HTTPResponseWriter.writeChunkedEncoding(&out)
        } else {
            // HTTP/1.0 with an unknown length: the close is the framing.
            plan.keepAlive = false
        }

        if !seen.contains(.date) {
            if snapshot.multiplexed {
                _ = emit("date", ByteSpan(snapshot.date, 29))
            } else {
                out.write("Date: ")
                out.write(snapshot.date, 29)
                out.writeCRLF()
            }
        }
        if !seen.contains(.server) {
            if snapshot.multiplexed {
                let peregrine: StaticString = "peregrine"
                _ = emit("server", ByteSpan(peregrine.utf8Start,
                                            peregrine.utf8CodeUnitCount))
            } else {
                out.write("Server: peregrine\r\n")
            }
        }
        if let altSvc = snapshot.altSvc, !seen.contains(.altSvc) {
            if snapshot.multiplexed {
                _ = emit("alt-svc", ByteSpan(altSvc, snapshot.altSvcLength))
            } else {
                out.write("Alt-Svc: ")
                out.write(altSvc, snapshot.altSvcLength)
                out.writeCRLF()
            }
        }
        if let hsts = snapshot.hsts, !seen.contains(.hsts) {
            if snapshot.multiplexed {
                _ = emit("strict-transport-security", ByteSpan(hsts, snapshot.hstsLength))
            } else {
                out.write("Strict-Transport-Security: ")
                out.write(hsts, snapshot.hstsLength)
                out.writeCRLF()
            }
        }
        if let requestID = snapshot.requestID, snapshot.requestIDLength > 0,
           !seen.contains(.requestID) {
            if snapshot.multiplexed {
                _ = emit("x-request-id", ByteSpan(requestID, snapshot.requestIDLength))
            } else {
                out.write("X-Request-ID: ")
                out.write(requestID, snapshot.requestIDLength)
                out.writeCRLF()
            }
        }
        if snapshot.multiplexed {
            // Connection management is not the application's on HTTP/1 and
            // does not exist at all here: the stream is the message.
            WSGIHeadBlock.finish(&out, at: blockAt, status: code, count: emitted)
        } else {
            HTTPResponseWriter.writeConnection(&out, keepAlive: plan.keepAlive)
            HTTPResponseWriter.endHead(&out)
        }
        // --cache-size: every header has been seen, so whether this response
        // is kept is settled; the body decides only whether it arrives whole.
        if let capture, capture.pointee.active { capture.pointee.settle(status: code) }
        WSGIStartResponse.markHeadersSent(startResponse)
        plan.ok = true
        return plan
    }

    /// Appends one body part with the chosen framing. Returns false with a
    /// Python exception pending if the part is not bytes-like.
    ///
    /// `limit` is what stops a declared Content-Length being overrun: anything
    /// past it is dropped here rather than written, and the caller sees
    /// `limit.overflowed` afterwards.
    public static func writeBodyPart(_ out: inout ByteBuffer,
                                     _ part: PyObj,
                                     chunked: Bool,
                                     limit: inout WSGIBodyLimit,
                                     encoder: inout ResponseEncoder,
                                     flush: Bool = false,
                                     capture: UnsafeMutablePointer<ResponseCapture>? = nil) -> Bool {
        var data: UnsafePointer<CChar>?
        var len: pg_ssize_t = 0
        var owner: PyObj?
        if pg_as_bytes(part, &data, &len, &owner) != 0 { return false }
        defer { pg_release_bytes(owner) }
        if len > 0, let data {
            let take = limit.take(Int(len))
            if take > 0 {
                let p = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
                // What the application produced, before any compression: a
                // cached copy is encoded afresh for each client.
                if let capture, capture.pointee.active { capture.pointee.append(p, take) }
                if encoder.active {
                    if !encoder.encode(p, take, flush: flush, into: &out, chunked: chunked) {
                        pg_err_set_str(pg_exc_runtime(), "compressing the response failed")
                        return false
                    }
                } else if chunked {
                    HTTPResponseWriter.writeChunk(&out, p, take)
                } else {
                    out.write(p, take)
                }
            }
        }
        return true
    }

    /// Ends the body: the compressed stream if there is one, then the chunked
    /// terminator if there is one. False when the compressor failed, which
    /// leaves the message with no honest ending.
    public static func finishBody(_ out: inout ByteBuffer, plan: WSGIHeadPlan,
                                  encoder: inout ResponseEncoder) -> Bool {
        if plan.suppressBody {
            encoder.destroy()
            return true
        }
        if encoder.active && !encoder.finish(into: &out, chunked: plan.chunked) {
            return false
        }
        if plan.chunked { HTTPResponseWriter.writeLastChunk(&out) }
        return true
    }
}
