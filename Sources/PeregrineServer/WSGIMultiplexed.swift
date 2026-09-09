//===----------------------------------------------------------------------===//
// WSGI on a multiplexed stream.
//
// WSGI is a blocking contract written for one request per connection, and
// nothing in PEP 3333 knows what a stream is. That does not have to mean a
// WSGI application gets a lesser server: HTTP/2 and HTTP/3 differ from
// HTTP/1.1 in how a message is framed, not in what a message is, and framing
// is the server's job in every one of the three.
//
// The request side already needs nothing: an HTTP/2 or HTTP/3 request head is
// rebuilt as HTTP/1.1 text and re-parsed, so the environ builder sees exactly
// what it saw before. Only two things are told the truth about the transport,
// because a WSGI application can observe them: SERVER_PROTOCOL and
// wsgi.url_scheme.
//
// The response side is where the work is. A head has to become a compressed
// header block, and the compressor is a table both ends keep in step, so only
// the thread that owns the connection may touch it -- while the application
// may be running on a pool thread. So the response head is staged in a neutral
// form (WSGIHeadBlock) by whichever thread produced it, and encoded here, on
// the loop thread, at the moment the first bytes are about to go out. The body
// needs nothing: it is already bytes, and the stream flush turns bytes into
// DATA frames whatever produced them.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineQUIC

extension Worker {

    /// Encodes the staged head at the front of the write buffer and sends it
    /// as HEADERS. Returns false when the connection is gone; a head that has
    /// not fully arrived yet is not a failure -- it simply has not arrived.
    mutating func startMultiplexedWSGI(_ slot: Int) -> Bool {
        let c = table[slot]
        let available = c.pointee.write.readableBytes
        if available < WSGIHeadBlock.prefixLength { return true }
        let base = UnsafePointer(c.pointee.write.readPointer)
        let length = Int(base[0]) << 24 | Int(base[1]) << 16
            | Int(base[2]) << 8 | Int(base[3])
        if available < WSGIHeadBlock.prefixLength + length { return true }

        var r = WSGIHeadReader(base + WSGIHeadBlock.prefixLength, length)
        guard let status = r.uint16(), let count = r.uint16() else {
            Log.error("the staged response head is malformed")
            failRequest(slot, status: 500)
            return false
        }

        let parent = Int(c.pointee.parentSlot)
        if parent < 0 {
            closeConnection(slot)
            return false
        }

        var block = ByteBuffer()
        defer { block.destroy() }
        var lower = ByteBuffer()
        defer { lower.destroy() }
        var ok = true

        if c.pointee.isH3Stream {
            guard let h3 = table[parent].pointee.h3 else {
                closeConnection(slot)
                return false
            }
            h3.encoder.begin(into: &block)
            h3.encoder.encodeStatus(Int(status), into: &block)
            ok = encodeStagedHeaders(&r, count: Int(count), lower: &lower) {
                name, nameLength, value, valueLength in
                h3.encoder.encode(name: name, nameLength: nameLength,
                                  value: value, valueLength: valueLength, into: &block)
            }
            if ok { writeH3HeaderBlock(slot, h3, block: &block) }
        } else {
            guard let h2 = table[parent].pointee.h2 else {
                closeConnection(slot)
                return false
            }
            h2.encoder.encodeStatus(Int(status), into: &block)
            ok = encodeStagedHeaders(&r, count: Int(count), lower: &lower) {
                name, nameLength, value, valueLength in
                h2.encoder.encode(name: name, nameLength: nameLength,
                                  value: value, valueLength: valueLength, into: &block)
            }
            if ok {
                // The stream ends here only if there is nothing else to send;
                // the body flush does it otherwise.
                let empty = c.pointee.flags.contains(.suppressBody)
                    && c.pointee.write.readableBytes
                        == WSGIHeadBlock.prefixLength + length
                writeHeaderBlock(slot, h2, block: &block, endStream: empty)
                if empty {
                    c.pointee.flags.insert(.responseComplete)
                    c.pointee.flags.insert(.endStreamSent)
                }
            }
        }

        if !ok {
            // The head was accepted by the text writer's rules and refused by
            // the stricter ones a multiplexed connection applies. Nothing has
            // gone out yet, so this is still answerable.
            c.pointee.write.consume(WSGIHeadBlock.prefixLength + length)
            failRequest(slot, status: 500)
            return false
        }

        c.pointee.write.consume(WSGIHeadBlock.prefixLength + length)
        c.pointee.flags.insert(.responseStarted)
        return true
    }

    /// Walks the staged headers, applying the rules a multiplexed connection
    /// adds on top of HTTP/1's, and hands each survivor to the encoder.
    private func encodeStagedHeaders(_ r: inout WSGIHeadReader, count: Int,
                                     lower: inout ByteBuffer,
                                     _ encode: (UnsafePointer<UInt8>, Int,
                                                UnsafePointer<UInt8>, Int) -> Void) -> Bool {
        var i = 0
        while i < count {
            i += 1
            guard let (name, nameLength, value, valueLength) = r.header() else { return false }
            if nameLength == 0 || name[0] == 0x3A { return false }
            if HTTP2.isConnectionSpecific(name, nameLength) {
                // PEP 3333 already forbids these; the text writer swallows the
                // ones it knows, and anything left is a header that has no
                // meaning on a connection that multiplexes.
                continue
            }
            if !HTTP2.validFieldValue(value, valueLength) { return false }
            lower.clear()
            lower.reserve(nameLength)
            var j = 0
            while j < nameLength {
                lower.writeByte(asciiLower(name[j]))
                j += 1
            }
            let lowered = UnsafePointer(lower.readPointer)
            if !HTTP2.validFieldName(lowered, nameLength) { return false }
            encode(lowered, nameLength, valueLength > 0 ? value : emptyH3Byte, valueLength)
        }
        return true
    }
}

/// Reads back what `WSGIHeadBlock` staged.
struct WSGIHeadReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var offset = 0

    init(_ base: UnsafePointer<UInt8>, _ count: Int) {
        self.base = base
        self.count = count
    }

    mutating func uint16() -> UInt16? {
        if offset + 2 > count { return nil }
        let v = UInt16(base[offset]) << 8 | UInt16(base[offset + 1])
        offset += 2
        return v
    }

    mutating func header() -> (UnsafePointer<UInt8>, Int,
                               UnsafePointer<UInt8>, Int)? {
        guard let nameLength = uint16(), let valueLength = uint16() else { return nil }
        let n = Int(nameLength), v = Int(valueLength)
        if offset + n + v > count { return nil }
        let name = base + offset
        let value = base + offset + n
        offset += n + v
        return (name, n, value, v)
    }
}
