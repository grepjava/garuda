//===----------------------------------------------------------------------===//
// HTTP/2 response encoding.
//
// The HTTP/1 path writes a status line and header text straight into the
// connection buffer. Here the same information becomes a `:status`
// pseudo-header and an HPACK block, and the framing headers disappear
// altogether: length is what END_STREAM says it is, and connection-level
// headers have no meaning on a multiplexed connection.
//
// Body bytes are not written here at all. They go into the stream's own write
// buffer and become DATA frames in `flushStream`, which is what lets flow
// control and the existing `await send()` backpressure apply to them.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

extension Worker {

    /// The HTTP/2 form of `http.response.start`.
    mutating func h2ResponseStart(_ slot: Int, message: PyObj) -> Bool {
        let c = table[slot]
        guard let statusObj = pg_dict_get(message, Interned[.status]) else {
            pg_err_set_str(pg_exc_value(), "http.response.start needs a status")
            return false
        }
        let status = Int(pg_int_as_long(statusObj))
        if status < 100 || status > 599 {
            pg_err_set_str(pg_exc_value(), "status out of range")
            return false
        }
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h2 = table[parent].pointee.h2 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }

        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        var lower = ByteBuffer()
        defer { lower.destroy() }
        h2.encoder.encodeStatus(status, into: &block)

        var seen: ResponseHeaderKind = []
        var declaredLength = -1
        var failure: StaticString? = nil

        if let headerList = pg_dict_get(message, Interned[.headers]),
           pg_is(headerList, Interned.none) == 0 {
            guard let materialized = PySeq.iterable(headerList) else {
                pg_err_clear()
                pg_err_set_str(pg_exc_value(),
                               "http.response.start headers must be an iterable of pairs")
                return false
            }
            let headerList = materialized.seq
            defer { if materialized.owned { pg_decref(headerList) } }
            let count = PySeq.count(headerList)
            var i = 0
            while i < count && failure == nil {
                guard let item = PySeq.item(headerList, i),
                      let (nameObj, valueObj) = PySeq.pair(item) else {
                    pg_err_set_str(pg_exc_value(),
                                   "each response header must be a (name, value) pair")
                    return false
                }
                i += 1
                guard let nameView = PyBytesView.of(nameObj) else {
                    pg_err_set_str(pg_exc_value(), "a response header name is not bytes")
                    return false
                }
                guard let valueView = PyBytesView.of(valueObj) else {
                    nameView.release()
                    pg_err_set_str(pg_exc_value(), "a response header value is not bytes")
                    return false
                }
                let name = nameView.span
                let value = valueView.span
                let kind = HTTPResponseWriter.classify(name)
                seen.formUnion(kind)

                if kind.contains(.contentLength) {
                    declaredLength = parseDecimal(value.base, value.count)
                    if declaredLength < 0 { failure = "malformed content-length" }
                } else if name.count == 0 {
                    failure = "empty response header name"
                } else if HTTP2.isConnectionSpecific(name.base, name.count) || name.base[0] == 0x3A {
                    // Connection headers mean nothing on a multiplexed
                    // connection, and a pseudo-header from the application
                    // would be indistinguishable from framing.
                    failure = "header is not valid in HTTP/2"
                } else if !HTTP2.validFieldValue(value.base, value.count) {
                    failure = "header contains a control character"
                } else {
                    // Field names travel lowercase whatever case the
                    // application chose.
                    lower.clear()
                    lower.reserve(name.count)
                    var j = 0
                    while j < name.count {
                        lower.writeByte(asciiLower(name.base[j]))
                        j += 1
                    }
                    let lowered = UnsafePointer(lower.readPointer)
                    if !HTTP2.validFieldName(lowered, name.count) {
                        failure = "header name is not a token"
                    } else {
                        h2.encoder.encode(name: lowered, nameLength: name.count,
                                          value: value.count > 0 ? value.base : emptyH2Byte,
                                          valueLength: value.count, into: &block)
                    }
                }
                valueView.release()
                nameView.release()
            }
        }
        if let failure {
            pg_err_set_str(pg_exc_value(), staticCString(failure))
            return false
        }

        if HTTPResponseWriter.statusForbidsBody(status) {
            declaredLength = 0
            c.pointee.flags.insert(.suppressBody)
        }
        c.pointee.responseRemaining = declaredLength
        if declaredLength >= 0 {
            var digits = ByteBuffer()
            defer { digits.destroy() }
            digits.writeDecimal(declaredLength)
            encodeStatic(h2, "content-length", UnsafePointer(digits.readPointer),
                         digits.readableBytes, into: &block)
        }
        if !seen.contains(.date) {
            encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !seen.contains(.server) {
            encodeStatic(h2, "server", "peregrine", into: &block)
        }
        // HTTP/2 is where this matters most: a browser here is already on TLS
        // and already multiplexing, so the only thing it does not know is that
        // there is a UDP port worth trying.
        if let altSvc = config.altSvc, !seen.contains(.altSvc) {
            encodeStatic(h2, "alt-svc", altSvc, config.altSvcLength, into: &block)
        }

        // A response that can have no body at all ends here, with no DATA
        // frame to carry the flag.
        let empty = c.pointee.flags.contains(.suppressBody) && declaredLength == 0
        writeHeaderBlock(slot, h2, block: &block, endStream: empty)
        c.pointee.flags.insert(.responseStarted)
        if empty {
            c.pointee.flags.insert(.responseComplete)
            c.pointee.state = .writing
        }
        logAccess(slot, status: status)
        _ = flush(parent)
        return true
    }

    func encodeStatic(_ h2: H2Connection, _ name: StaticString,
                      _ value: UnsafePointer<UInt8>, _ valueLength: Int,
                      into block: inout ByteBuffer) {
        h2.encoder.encode(name: name.utf8Start, nameLength: name.utf8CodeUnitCount,
                          value: valueLength > 0 ? value : emptyH2Byte,
                          valueLength: valueLength, into: &block)
    }

    func encodeStatic(_ h2: H2Connection, _ name: StaticString, _ value: StaticString,
                      into block: inout ByteBuffer) {
        encodeStatic(h2, name, value.utf8Start, value.utf8CodeUnitCount, into: &block)
    }

    /// Emits a header block as HEADERS plus as many CONTINUATIONs as it takes.
    mutating func writeHeaderBlock(_ slot: Int, _ h2: H2Connection,
                                   block: inout ByteBuffer, endStream: Bool) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        let streamID = c.pointee.streamID
        let total = block.readableBytes
        let limit = max(1, h2.peerMaxFrameSize)
        let origin = block.readerOffset
        var offset = 0
        var first = true

        repeat {
            let n = min(limit, total - offset)
            let last = offset + n >= total
            var flags: H2Flags = last ? .endHeaders : []
            if first && endStream { flags.insert(.endStream) }
            writeFrame(parent, length: n,
                       type: first ? .headers : .continuation,
                       flags: flags, streamID: streamID) { out in
                if n > 0 { out.write(UnsafePointer(block.pointer(at: origin + offset)), n) }
            }
            offset += n
            first = false
        } while offset < total

        if endStream { c.pointee.flags.insert(.endStreamSent) }
    }
}

extension Worker {
    /// The HTTP/2 form of a server-generated error: a status and nothing else.
    ///
    /// The HTTP/1 path writes a small text response, which on a stream would
    /// arrive as DATA and be neither an error nor a body anyone asked for.
    mutating func h2FailRequest(_ slot: Int, status: Int) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h2 = table[parent].pointee.h2 else {
            closeConnection(slot)
            return
        }
        if !c.pointee.flags.contains(.responseStarted) {
            dates.refresh()
            var block = ByteBuffer()
            defer { block.destroy() }
            h2.encoder.encodeStatus(status, into: &block)
            encodeStatic(h2, "content-length", "0", into: &block)
            encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
            encodeStatic(h2, "server", "peregrine", into: &block)
            writeHeaderBlock(slot, h2, block: &block, endStream: true)
            c.pointee.flags.insert(.responseStarted)
            c.pointee.flags.insert(.responseComplete)
            logAccess(slot, status: status)
            _ = flush(parent)
            closeStream(slot, resetWith: nil)
            return
        }
        // Already committed to a response we cannot finish.
        closeStream(slot, resetWith: .internalError)
    }
}
