//===----------------------------------------------------------------------===//
// Writing an HTTP/3 response.
//
// The shape is HTTP/2's with the framing layer taken away. There is no window
// to check, no maximum frame size to split against and no END_STREAM flag: the
// response is a HEADERS frame, then DATA frames, then the QUIC stream is
// finished. What backpressure remains is the transport's, and it appears here
// as a stream that will not take any more bytes right now.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineQUIC

nonisolated(unsafe) let emptyH3Byte = UnsafePointer<UInt8>(
    UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

extension Worker {
    mutating func h3ResponseStart(_ slot: Int, message: PyObj) -> Bool {
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
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }

        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        var lower = ByteBuffer()
        defer { lower.destroy() }
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(status, into: &block)

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
                } else if HTTP2.isConnectionSpecific(name.base, name.count)
                            || name.base[0] == 0x3A {
                    failure = "header is not valid in HTTP/3"
                } else if !HTTP2.validFieldValue(value.base, value.count) {
                    failure = "header contains a control character"
                } else {
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
                        h3.encoder.encode(name: lowered, nameLength: name.count,
                                          value: value.count > 0 ? value.base : emptyH3Byte,
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
            encodeStaticH3(h3, "content-length", UnsafePointer(digits.readPointer),
                           digits.readableBytes, into: &block)
        }
        if !seen.contains(.date) {
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !seen.contains(.server) {
            encodeStaticH3(h3, "server", "peregrine", into: &block)
        }

        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)

        let empty = c.pointee.flags.contains(.suppressBody) && declaredLength == 0
        if empty {
            c.pointee.flags.insert(.responseComplete)
            c.pointee.state = .writing
        }
        logAccess(slot, status: status)
        _ = flushH3Stream(slot)
        flushQUIC(parent)
        return true
    }

    func encodeStaticH3(_ h3: H3Connection, _ name: StaticString,
                        _ value: UnsafePointer<UInt8>, _ valueLength: Int,
                        into block: inout ByteBuffer) {
        h3.encoder.encode(name: name.utf8Start, nameLength: name.utf8CodeUnitCount,
                          value: valueLength > 0 ? value : emptyH3Byte,
                          valueLength: valueLength, into: &block)
    }

    func encodeStaticH3(_ h3: H3Connection, _ name: StaticString, _ value: StaticString,
                        into block: inout ByteBuffer) {
        encodeStaticH3(h3, name, value.utf8Start, value.utf8CodeUnitCount, into: &block)
    }

    /// Queues a HEADERS frame on the stream. QPACK blocks are never split:
    /// there is no maximum frame size in HTTP/3, and the stream reassembles.
    mutating func writeH3HeaderBlock(_ slot: Int, _ h3: H3Connection,
                                     block: inout ByteBuffer) {
        let c = table[slot]
        var frame = ByteBuffer(capacity: block.readableBytes + 16)
        defer { frame.destroy() }
        frame.writeVarint(HTTP3FrameType.headers)
        frame.writeVarint(UInt64(block.readableBytes))
        frame.write(UnsafePointer(block.readPointer), block.readableBytes)
        h3.quic.send(c.pointee.qstreamID, UnsafePointer(frame.readPointer),
                     frame.readableBytes, fin: false)
    }

    /// Moves queued response bytes onto the QUIC stream as DATA frames.
    @discardableResult
    mutating func flushH3Stream(_ streamSlot: Int) -> Bool {
        let s = table[streamSlot]
        let parent = Int(s.pointee.parentSlot)
        if parent < 0 { return false }
        let p = table[parent]
        guard p.pointee.state == .http3, p.pointee.h3 != nil else {
            closeConnection(streamSlot)
            return false
        }
        // A WSGI response arrives here as a staged head followed by body
        // bytes, because the thread that produced it could not touch the
        // connection's compressor. Nothing may go out before the head does.
        if appProtocol == .wsgi && !s.pointee.flags.contains(.responseStarted) {
            if !startMultiplexedWSGI(streamSlot) { return false }
            if !s.pointee.flags.contains(.responseStarted) { return true }
        }
        guard let h3 = table[parent].pointee.h3 else { return false }
        let streamID = s.pointee.qstreamID

        let pending = s.pointee.write.readableBytes
        if pending > 0 {
            var frame = ByteBuffer(capacity: pending + 16)
            defer { frame.destroy() }
            frame.writeVarint(HTTP3FrameType.data)
            frame.writeVarint(UInt64(pending))
            frame.write(UnsafePointer(s.pointee.write.readPointer), pending)
            h3.quic.send(streamID, UnsafePointer(frame.readPointer),
                         frame.readableBytes, fin: false)
            // A stream slot is refreshed by the bytes that move on it, not by
            // a poller event: it has no descriptor to have one. See the same
            // note in HTTP2.flushStream.
            s.pointee.lastActivity = pg_monotonic_ms()
            s.pointee.write.consume(pending)
        }

        // A response shorter than what it declared must not be finished
        // cleanly: the client would take the truncation for the whole message.
        // A HEAD response is not short: the length it declares describes the
        // body a GET would have had, and withholding that body is the point.
        let short = s.pointee.flags.contains(.responseComplete)
            && !s.pointee.flags.contains(.suppressBody)
            && s.pointee.responseRemaining > 0
        if s.pointee.flags.contains(.responseComplete)
            && !s.pointee.flags.contains(.endStreamSent) {
            s.pointee.flags.insert(.endStreamSent)
            if short {
                h3.quic.resetStream(streamID, code: HTTP3Error.internalError)
            } else {
                h3.quic.send(streamID, emptyH3Byte, 0, fin: true)
            }
        }
        flushQUIC(parent)
        resumeWriterIfDrained(streamSlot)

        // Once the ending is on the wire and nothing is left to write, the
        // slot exists only for a task that has not returned yet.
        if s.pointee.flags.contains(.endStreamSent) && s.pointee.write.isEmpty {
            if s.pointee.state == .writing {
                if appProtocol == .asgi && s.pointee.task != nil { return true }
                closeH3Stream(streamSlot)
                return false
            }
        }
        return true
    }

    /// How much this stream has queued on the transport but not yet had
    /// acknowledged, which is what write backpressure is measured against.
    @usableFromInline
    func h3Outstanding(_ streamSlot: Int) -> Int {
        let s = table[streamSlot]
        let parent = Int(s.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3,
              let stream = h3.quic.stream(s.pointee.qstreamID) else { return 0 }
        return stream.send.data.readableBytes
    }

    /// The HTTP/3 form of a server-generated error: a status and nothing else.
    mutating func h3FailRequest(_ slot: Int, status: Int) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        if !c.pointee.flags.contains(.responseStarted) {
            dates.refresh()
            var block = ByteBuffer()
            defer { block.destroy() }
            h3.encoder.begin(into: &block)
            h3.encoder.encodeStatus(status, into: &block)
            encodeStaticH3(h3, "content-length", "0", into: &block)
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
            encodeStaticH3(h3, "server", "peregrine", into: &block)
            writeH3HeaderBlock(slot, h3, block: &block)
            c.pointee.flags.insert(.responseStarted)
            c.pointee.flags.insert(.responseComplete)
            c.pointee.flags.insert(.endStreamSent)
            h3.quic.send(c.pointee.qstreamID, emptyH3Byte, 0, fin: true)
            logAccess(slot, status: status)
            flushQUIC(parent)
            closeH3Stream(slot)
            return
        }
        h3.quic.resetStream(c.pointee.qstreamID, code: HTTP3Error.internalError)
        flushQUIC(parent)
        closeH3Stream(slot)
    }
}

extension Worker {
    /// Called once the whole response has been handed to the transport.
    mutating func finishH3Response(_ slot: Int) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        // A short response has already been turned into a reset by the flush;
        // there is nothing left to say.
        if c.pointee.flags.contains(.responseComplete)
            && !c.pointee.flags.contains(.suppressBody)
            && c.pointee.responseRemaining > 0 {
            closeH3Stream(slot)
            return
        }
        if c.pointee.bodyRemaining == 0 {
            closeH3Stream(slot)
            return
        }
        // Answering before the upload has finished is ordinary. If what is
        // left is small the stream stays open until it arrives -- the bytes go
        // nowhere, but they are still counted and still checked against what
        // the client promised. A large upload is not worth waiting for.
        let declared = c.pointee.head.flags.contains(.hasContentLength)
            ? c.pointee.head.contentLength - c.pointee.bodyReceived
            : 0
        if declared <= config.bodyHighWaterMark {
            c.pointee.state = .closing
            c.pointee.body.clear()
            releaseDrainWaiter(slot)
            releasePendingReceive(slot)
            return
        }
        h3.quic.stopSending(c.pointee.qstreamID, code: HTTP3Error.noError)
        flushQUIC(parent)
        closeH3Stream(slot)
    }
}
