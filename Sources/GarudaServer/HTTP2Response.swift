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

import CGaruda
import GarudaCore
import GarudaHTTP

extension Worker {

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
    mutating func h2FailRequest(_ slot: Int, status: Int, retryAfter: Int = 0) {
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
            encodeStatic(h2, "server", "garuda", into: &block)
            if retryAfter > 0 {
                var digits = ByteBuffer()
                defer { digits.destroy() }
                digits.writeDecimal(retryAfter)
                encodeStatic(h2, "retry-after", UnsafePointer(digits.readPointer),
                             digits.readableBytes, into: &block)
            }
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
