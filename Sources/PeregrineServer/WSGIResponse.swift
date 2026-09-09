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

    public init(httpMinor: UInt8, keepAlive: Bool, suppressBody: Bool,
                date: UnsafePointer<UInt8>,
                altSvc: UnsafePointer<UInt8>? = nil, altSvcLength: Int = 0) {
        self.httpMinor = httpMinor
        self.keepAlive = keepAlive
        self.suppressBody = suppressBody
        self.date = date
        self.altSvc = altSvc
        self.altSvcLength = altSvcLength
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
    /// A message for the log when `ok` is false.
    public var failure: StaticString = ""
}

public enum WSGIResponseBuilder {

    /// Serialises the status line and headers, and settles the framing.
    ///
    /// `result` is inspected but not consumed: a list or tuple return value can
    /// have its total length summed here, which is what lets an ordinary
    /// application get a Content-Length without declaring one.
    public static func writeHead(_ out: inout ByteBuffer,
                                 statusObj: PyObj,
                                 headerList: PyObj,
                                 startResponse: PyObj,
                                 result: PyObj,
                                 snapshot: WSGIRequestSnapshot) -> WSGIHeadPlan {
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
        HTTPResponseWriter.writeStatusLine(&out, raw: ByteSpan(statusPtr, Int(statusLen)))

        var seen: ResponseHeaderKind = []
        var declaredLength = -1
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
            } else if !HTTPResponseWriter.writeHeader(&out, name: name, value: value) {
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
        let isSequence = PySeq.isSequence(result)

        // Anything passed to the legacy write() callable is part of the body
        // too, and has to be counted before a Content-Length is synthesised.
        var writtenTotal = 0
        if let written = WSGIStartResponse.writtenChunks(startResponse) {
            let wn = Int(pg_list_size(written))
            var k = 0
            while k < wn {
                if let part = pg_list_get(written, pg_ssize_t(k)), pg_is_bytes(part) != 0 {
                    writtenTotal += Int(pg_bytes_len(part))
                }
                k += 1
            }
        }

        if forbidsBody {
            declaredLength = 0
        } else if declaredLength >= 0 {
            // Application knows its own length.
        } else if isSequence {
            var total = writtenTotal
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

        if declaredLength >= 0 {
            HTTPResponseWriter.writeContentLength(&out, declaredLength)
        } else if snapshot.httpMinor == 1 {
            plan.chunked = true
            HTTPResponseWriter.writeChunkedEncoding(&out)
        } else {
            // HTTP/1.0 with an unknown length: the close is the framing.
            plan.keepAlive = false
        }

        if !seen.contains(.date) {
            out.write("Date: ")
            out.write(snapshot.date, 29)
            out.writeCRLF()
        }
        if !seen.contains(.server) {
            out.write("Server: peregrine\r\n")
        }
        if let altSvc = snapshot.altSvc, !seen.contains(.altSvc) {
            out.write("Alt-Svc: ")
            out.write(altSvc, snapshot.altSvcLength)
            out.writeCRLF()
        }
        HTTPResponseWriter.writeConnection(&out, keepAlive: plan.keepAlive)
        HTTPResponseWriter.endHead(&out)
        WSGIStartResponse.markHeadersSent(startResponse)
        plan.ok = true
        return plan
    }

    /// Appends one body part with the chosen framing. Returns false with a
    /// Python exception pending if the part is not bytes-like.
    public static func writeBodyPart(_ out: inout ByteBuffer,
                                     _ part: PyObj,
                                     chunked: Bool) -> Bool {
        var data: UnsafePointer<CChar>?
        var len: pg_ssize_t = 0
        var owner: PyObj?
        if pg_as_bytes(part, &data, &len, &owner) != 0 { return false }
        defer { pg_release_bytes(owner) }
        if len > 0, let data {
            let p = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
            if chunked {
                HTTPResponseWriter.writeChunk(&out, p, Int(len))
            } else {
                out.write(p, Int(len))
            }
        }
        return true
    }
}
