//===----------------------------------------------------------------------===//
// Writing an HTTP/3 response.
//
// The shape is HTTP/2's with the framing layer taken away. There is no window
// to check, no maximum frame size to split against and no END_STREAM flag: the
// response is a HEADERS frame, then DATA frames, then the QUIC stream is
// finished. What backpressure remains is the transport's, and it appears here
// as a stream that will not take any more bytes right now.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP
import GarudaQUIC

nonisolated(unsafe) let emptyH3Byte = UnsafePointer<UInt8>(
    UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

extension Worker {
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
        guard let h3 = table[parent].pointee.h3 else { return false }
        let streamID = s.pointee.qstreamID

        // A --static-dir response is fed from a descriptor rather than by the
        // application, so it refills here. Bounded per call: whatever is left
        // goes out when this stream is writable again, which is the same
        // signal that resumes an application parked in send().
        var sentHere = 0
        refillStreamFromFile(streamSlot)
        var pending = s.pointee.write.readableBytes
        while pending > 0 {
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
            sentHere += pending
            if s.pointee.fileRemaining == 0 || sentHere >= config.writeHighWaterMark { break }
            refillStreamFromFile(streamSlot)
            pending = s.pointee.write.readableBytes
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
            // An answered stream earns back one cancellation.
            if h3.resetBudget < h3.resetBudgetCap { h3.resetBudget &+= 1 }
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

    /// HSTS and the request ID: what `writeServerHeaders` adds to an HTTP/1.1
    /// head, less Alt-Svc, which here would advertise the protocol already in
    /// use.
    func encodeServerHeadersH3(_ slot: Int, _ h3: H3Connection, into block: inout ByteBuffer) {
        if let hsts = config.hsts {
            encodeStaticH3(h3, "strict-transport-security", hsts, config.hstsLength, into: &block)
        }
        let c = table[slot]
        if config.requestID && c.pointee.requestID.readableBytes > 0 {
            encodeStaticH3(h3, "x-request-id", UnsafePointer(c.pointee.requestID.readPointer),
                           c.pointee.requestID.readableBytes, into: &block)
        }
    }

    /// The HTTP/3 form of a server-generated error: a status and nothing else.
    mutating func h3FailRequest(_ slot: Int, status: Int, retryAfter: Int = 0) {
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
            encodeStaticH3(h3, "server", "garuda", into: &block)
            encodeServerHeadersH3(slot, h3, into: &block)
            if retryAfter > 0 {
                var digits = ByteBuffer()
                defer { digits.destroy() }
                digits.writeDecimal(retryAfter)
                encodeStaticH3(h3, "retry-after", UnsafePointer(digits.readPointer),
                               digits.readableBytes, into: &block)
            }
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

    /// A router response on a stream: status, length and body. The body is
    /// queued on the stream and leaves as DATA through `flushH3Stream`, which
    /// finishes the stream and retires the slot once it has drained. With no
    /// body this is the status-only response above.
    mutating func h3Respond(_ slot: Int, status: Int,
                            body: UnsafePointer<UInt8>?, bodyCount: Int) {
        guard let body, bodyCount > 0 else {
            h3FailRequest(slot, status: status)
            return
        }
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        if c.pointee.flags.contains(.responseStarted) {
            h3.quic.resetStream(c.pointee.qstreamID, code: HTTP3Error.internalError)
            flushQUIC(parent)
            closeH3Stream(slot)
            return
        }
        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        var digits = ByteBuffer()
        defer { digits.destroy() }
        digits.writeDecimal(bodyCount)
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(status, into: &block)
        encodeStaticH3(h3, "content-length", UnsafePointer(digits.readPointer),
                       digits.readableBytes, into: &block)
        encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        encodeStaticH3(h3, "server", "garuda", into: &block)
        encodeServerHeadersH3(slot, h3, into: &block)
        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: status)
        // A HEAD response declares the length a GET would have had, and ends
        // with its headers.
        if c.pointee.flags.contains(.suppressBody) {
            c.pointee.flags.insert(.responseComplete)
            c.pointee.flags.insert(.endStreamSent)
            h3.quic.send(c.pointee.qstreamID, emptyH3Byte, 0, fin: true)
            flushQUIC(parent)
            closeH3Stream(slot)
            return
        }
        c.pointee.write.write(body, bodyCount)
        c.pointee.responseRemaining = -1
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
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
