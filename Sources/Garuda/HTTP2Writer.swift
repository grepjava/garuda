//===----------------------------------------------------------------------===//
// HTTP/2's writing: answers onto the wire.
//
// Whoever writes holds the connection's WRITE ROLE, taken under its lock:
// that keeps one header block's frames together and one task's bytes from
// landing in the middle of another's. The encoder indexes nothing, so blocks
// need no particular order between them; the role is all the ordering there
// is. The role holder frames into the connection's own buffers.
//
// A stream whose handler has finished takes the role itself when nobody
// holds it and its whole body fits the windows: it frames its answer and
// writes it from its own task, with whatever control frames are waiting in
// front. That is the usual case, and it costs no hand-off.
//
// Everything else goes to the WRITER, a task per connection that sleeps on
// the connection's `Notify` and wakes for whatever the reader posts --
// control frames, a window the peer opened -- and for answers posted to it.
// A pass takes everything waiting under the lock, frames it outside the lock,
// and writes it in one go:
//
//   - control frames first, in the order the reader made them;
//   - a newly answered stream's head: the `onSend` hooks, then `:status`
//     and the response headers, as `HTTP1Connection.writeResponse` writes
//     them -- date, server and content-length added, the headers that frame
//     an HTTP/1 message or manage its connection dropped -- as HEADERS and
//     as many CONTINUATIONs as the peer's frame size needs;
//   - DATA for every stream with body to send, as far as its window, the
//     connection's window and one pass's share allow.
//
// A stream whose window is shut stays in the writer's list and the writer
// sleeps; the reader's WINDOW_UPDATE wakes it. The access log and
// `app.onResponse` see a stream once its head is framed, as they see an
// HTTP/1 response once its head is written.
//
// At the end the writer takes the role for good, so nothing writes after the
// write side is closed.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega
import VegaIO

/// DATA one writer pass frames, across every stream, before it writes.
let h2WritePass = 64 * 1024

/// The write half, for whichever task holds the write role.
protocol H2Sink: AnyObject, Sendable {
    func send(_ bytes: UnsafeRawBufferPointer) async throws(IOError)
}

/// Holds a connection's write half where every task that may take the write
/// role can reach it.
final class H2WriteHalf<W: AsyncWriter & ~Copyable & Sendable>: H2Sink, @unchecked Sendable {
    let half: UnsafeMutablePointer<W>
    private var open = true

    init(_ writer: consuming W) {
        half = .allocate(capacity: 1)
        half.initialize(to: writer)
    }

    func send(_ bytes: UnsafeRawBufferPointer) async throws(IOError) {
        try await half.pointee.write(bytes)
    }

    /// Ends the write side and lets the half go. Only once nothing can take
    /// the write role again.
    func close(_ closeWriter: @Sendable (borrowing W) async -> Void) async {
        await closeWriter(half.pointee)
        half.deinitialize(count: 1)
        open = false
    }

    deinit {
        if open { half.deinitialize(count: 1) }
        half.deallocate()
    }
}

/// Response fields as the encoder last encoded them, kept by the write role
/// for the next answer on the connection: answers repeat their fields --
/// `server`, `date` for a second, a handler's `content-type` -- and a field
/// found here is one copy rather than a name lookup and a Huffman pass.
/// The bytes are the encoder's own, so a block is what it would have been.
/// A few slots, replaced in turn; a field too long for one is not kept.
struct H2FieldCache: ~Copyable {
    static let slots = 8
    /// Name and value, then their encoding, in each slot.
    static let slotSize = 384
    static let maxKey = 128

    struct Entry {
        var nameLength = 0
        var valueLength = -1
        var encodedLength = 0
    }

    let storage: UnsafeMutablePointer<UInt8>
    let entries: UnsafeMutablePointer<Entry>
    var next = 0

    init() {
        storage = .allocate(capacity: H2FieldCache.slots * H2FieldCache.slotSize)
        entries = .allocate(capacity: H2FieldCache.slots)
        entries.initialize(repeating: Entry(), count: H2FieldCache.slots)
    }

    deinit {
        storage.deallocate()
        entries.deallocate()
    }

    /// Appends the encoding of `name: value` to `block`, from the cache or
    /// from `encoder`, keeping the latter when it fits.
    mutating func encode(_ encoder: HPACKEncoder, _ name: UnsafePointer<UInt8>, _ nameLength: Int,
                         _ value: UnsafePointer<UInt8>, _ valueLength: Int, into block: inout ByteBuffer) {
        var i = 0
        while i < H2FieldCache.slots {
            let e = entries[i]
            if e.nameLength == nameLength && e.valueLength == valueLength {
                let slot = storage + (i &* H2FieldCache.slotSize)
                if memcmp(slot, name, nameLength) == 0
                    && (valueLength == 0 || memcmp(slot + nameLength, value, valueLength) == 0) {
                    block.write(slot + (nameLength &+ valueLength), e.encodedLength)
                    return
                }
            }
            i &+= 1
        }
        let at = block.readerOffset &+ block.readableBytes
        encoder.encode(name: name, nameLength: nameLength, value: valueLength > 0 ? value : emptyBlock,
                       valueLength: valueLength, into: &block)
        let encoded = block.readerOffset &+ block.readableBytes &- at
        let key = nameLength &+ valueLength
        guard key <= H2FieldCache.maxKey, key &+ encoded <= H2FieldCache.slotSize else { return }
        let n = next
        next = (n &+ 1) & (H2FieldCache.slots &- 1)
        let slot = storage + (n &* H2FieldCache.slotSize)
        memcpy(slot, name, nameLength)
        if valueLength > 0 { memcpy(slot + nameLength, value, valueLength) }
        memcpy(slot + key, block.pointer(at: at), encoded)
        entries[n] = Entry(nameLength: nameLength, valueLength: valueLength, encodedLength: encoded)
    }
}

/// `content-length: n` as a literal without indexing under its static name
/// (28), its digits Huffman-coded when that is shorter, as the encoder
/// would: without a pass over the code table for a number.
func encodeContentLength(_ n: Int, into block: inout ByteBuffer) {
    block.reserve(32)
    block.writeByte(0x0F)                    // 4-bit prefix full: 15 ...
    block.writeByte(0x0D)                    // ... + 13 = 28
    var digits: (UInt64, UInt64, UInt64) = (0, 0, 0)
    withUnsafeMutableBytes(of: &digits) { raw in
        let d = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let count = writeDecimal(n, d)
        // '0'...'2' are 00000...00010; '3'...'9' are 011001...011111.
        var bits = 0
        for i in 0..<count { bits &+= d[i] < 0x33 ? 5 : 6 }
        let coded = (bits &+ 7) >> 3
        if coded >= count {
            block.writeByte(UInt8(count))
            block.write(UnsafePointer(d), count)
            return
        }
        block.writeByte(0x80 | UInt8(coded))
        var accumulator: UInt64 = 0
        var held = 0
        for i in 0..<count {
            let digit = UInt64(d[i] &- 0x30)
            let (code, length): (UInt64, Int) = digit < 3 ? (digit, 5) : (0x16 &+ digit, 6)
            accumulator = (accumulator << UInt64(length)) | code
            held &+= length
            while held >= 8 {
                held &-= 8
                block.writeByte(UInt8(truncatingIfNeeded: accumulator >> UInt64(held)))
            }
        }
        if held > 0 {
            let pad = 8 &- held
            block.writeByte(UInt8(truncatingIfNeeded: (accumulator << UInt64(pad)) | ((1 << UInt64(pad)) &- 1)))
        }
    }
}

extension H2Connection {
    /// Writes until the connection is done: the reader has finished and
    /// every stream task has, or the connection failed.
    func runWriter() async {
        var incoming: [H2Stream] = []
        var sending: [H2Stream] = []
        var finished: [H2Stream] = []
        incoming.reserveCapacity(16)
        sending.reserveCapacity(16)
        finished.reserveCapacity(16)
        let encoder = HPACKEncoder()
        while true {
            var stop = false
            var role = false
            var frameSize = H2FrameHeader.defaultMaxFrameSize
            lock.withLock { _ in
                stop = stopping
                if writing {
                    // A stream is writing its own answer; it wakes us.
                    writerWanted = true
                    return
                }
                writing = true
                role = true
                writerWanted = false
                if control.readableBytes > 0 {
                    wOut.write(control.readPointer, control.readableBytes)
                    control.clear()
                }
                if !ready.isEmpty {
                    swap(&incoming, &ready)
                    // Reset while it waited: nobody wants it.
                    incoming.removeAll { s in
                        guard s.reset else { return false }
                        s.closed = true
                        release(s)
                        return true
                    }
                }
                frameSize = peerMaxFrameSize
            }
            if !role {
                await wake.notifiedIgnoringCancellation()
                continue
            }
            if stop {
                // A GOAWAY, usually: one try at telling the peer why. The
                // role is kept: nothing writes after this.
                if wOut.readableBytes > 0 {
                    _ = try? await sink.send(UnsafeRawBufferPointer(start: wOut.readPointer, count: wOut.readableBytes))
                }
                wOut.clear()
                break
            }
            for s in incoming {
                if encodeHead(s, into: &wOut, block: &wBlock, encoder: encoder,
                              frameSize: frameSize) {
                    sending.append(s)
                } else {
                    finished.append(s)
                }
            }
            incoming.removeAll(keepingCapacity: true)
            if !sending.isEmpty { sendData(&sending, &finished, into: &wOut, frameSize: frameSize) }
            let wrote = wOut.readableBytes > 0
            var failed = false
            if wrote {
                do {
                    try await sink.send(UnsafeRawBufferPointer(start: wOut.readPointer, count: wOut.readableBytes))
                } catch {
                    writeFailed.store(true, ordering: .relaxed)
                    failed = true
                }
                wOut.clear()
            }
            // Nothing (more) to send. Done once the reader is, and every task
            // -- a stream still waiting for window then never gets it -- or,
            // after GOAWAY either way, once every stream has been answered:
            // ending the write side then tells the peer the connection is
            // over while the reader still waits on it.
            let blocked = !sending.isEmpty
            let done = lock.withLock { _ -> Bool in
                for s in finished {
                    // An answered stream buys back one cancellation.
                    if !s.reset { earned &+= 1 }
                    s.closed = true
                    release(s)
                }
                if failed {
                    stopping = true
                    return true
                }
                if wrote {
                    writing = false
                    return false
                }
                guard tasks == 0 && ready.isEmpty && control.readableBytes == 0 else {
                    writing = false
                    return false
                }
                if readerDone || ((goawaySent || peerGoneAway) && unstarted == 0 && !blocked) { return true }
                writing = false
                return false
            }
            finished.removeAll(keepingCapacity: true)
            if done { break }
            if wrote { continue }
            await wake.notifiedIgnoringCancellation()
        }
    }

    /// The DATA bytes `s`'s answer sends, once its `onSend` hooks have had
    /// their say: none for a HEAD or a status that forbids a body.
    func prepareAnswer(_ s: H2Stream) -> Int {
        let x = s.x
        if !x.pointee.sendHooks.isEmpty { runSendHooks(x) }
        x.pointee.committed = true
        if HTTPResponseWriter.statusForbidsBody(x.pointee.status) || x.pointee.head.method == .head { return 0 }
        return x.pointee.responseBody.readableBytes
    }

    /// Under the lock: takes the write role for `s`'s answer of `data`
    /// bytes, when nobody holds it and the windows take the whole body,
    /// spending them. Any control frames waiting go first.
    func takeRole(for s: H2Stream, data: Int) -> Bool {
        if writing || stopping { return false }
        if data > 0 {
            if data > s.sendWindow || data > sendWindow || data > h2WritePass { return false }
            s.sendWindow &-= data
            sendWindow &-= data
        }
        writing = true
        if control.readableBytes > 0 {
            wOut.write(control.readPointer, control.readableBytes)
            control.clear()
        }
        frameSizeForRole = peerMaxFrameSize
        return true
    }

    /// With the write role, its windows spent: frames `s`'s whole answer
    /// into `wOut`.
    func frameWhole(_ s: H2Stream) {
        let frameSize = frameSizeForRole
        if encodeHead(s, into: &wOut, block: &wBlock, encoder: HPACKEncoder(),
                      frameSize: frameSize) {
            let body = UnsafePointer(s.x.pointee.responseBody.readPointer)
            var sent = 0
            while sent < s.length {
                let n = min(s.length &- sent, frameSize)
                frame(&wOut, n, .data, sent &+ n == s.length ? .endStream : [], s.id)
                wOut.write(body + sent, n)
                sent &+= n
            }
            s.sent = sent
            ended(s, into: &wOut)
        }
    }

    /// With the write role: sends what is framed. False when the write
    /// failed, and the connection with it.
    @inline(__always)
    func sendFramed() async -> Bool {
        defer { wOut.clear() }
        guard wOut.readableBytes > 0 else { return true }
        do {
            try await sink.send(UnsafeRawBufferPointer(start: wOut.readPointer, count: wOut.readableBytes))
            return true
        } catch {
            writeFailed.store(true, ordering: .relaxed)
            return false
        }
    }

    /// Under the lock: lets the write role go, waking the writer when it is
    /// waiting for the role or has anything to do.
    func releaseRole(failed: Bool) {
        writing = false
        if failed { stopping = true }
        if failed || writerWanted || !ready.isEmpty || control.readableBytes > 0 || readerDone
            || goawaySent || peerGoneAway {
            wake.notifyOne()
        }
    }

    /// Frames `s`'s head. True when it has body to send.
    func encodeHead(_ s: H2Stream, into out: inout ByteBuffer, block: inout ByteBuffer, encoder: HPACKEncoder,
                    frameSize: Int) -> Bool {
        let x = s.x
        // `Response.onSend` hooks see the answer once it is final, while it
        // can still change (ResponseHooks.swift).
        if !x.pointee.sendHooks.isEmpty { runSendHooks(x) }
        x.pointee.committed = true
        parts.pointee.dates.refresh()
        let status = x.pointee.status
        let forbids = HTTPResponseWriter.statusForbidsBody(status)
        let count = forbids ? 0 : x.pointee.responseBody.readableBytes
        block.clear()
        encoder.encodeStatus(status, into: &block)
        let kinds = x.pointee.headerKinds
        if !kinds.contains(.date) {
            let name: StaticString = "date"
            fieldCache.encode(encoder, name.utf8Start, name.utf8CodeUnitCount, UnsafePointer(parts.pointee.dates.bytes),
                              parts.pointee.dates.count, into: &block)
        }
        if !kinds.contains(.server) {
            let name: StaticString = "server"
            let server: StaticString = "garuda"
            fieldCache.encode(encoder, name.utf8Start, name.utf8CodeUnitCount, server.utf8Start,
                              server.utf8CodeUnitCount, into: &block)
        }
        // --request-id's, unless the handler set its own (RequestID.swift).
        // Never the same twice, so never kept.
        if x.pointee.requestID.readableBytes > 0 && !kinds.contains(.requestID) {
            encode(encoder, "x-request-id", x.pointee.requestID.readPointer, x.pointee.requestID.readableBytes,
                   into: &block)
        }
        x.pointee.forEachResponseHeader { name, value in
            let kind = HTTPResponseWriter.classify(name)
            // Length is what END_STREAM says it is, and a connection's
            // management has no meaning on a stream.
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            if HTTP2.isConnectionSpecific(name.base, name.count) { return }
            fieldCache.encode(encoder, name.base, name.count, value.count > 0 ? value.base : emptyBlock, value.count,
                              into: &block)
        }
        if !forbids { encodeContentLength(count, into: &block) }
        // A HEAD answer carries the GET's headers and none of its body.
        let hasData = count > 0 && x.pointee.head.method != .head
        writeHeaderBlock(&block, stream: s.id, endStream: !hasData, frameSize: frameSize, into: &out)
        if observing { reportAnswer(x, limits: limits, status: status) }
        if hasData {
            s.sent = 0
            s.length = count
            return true
        }
        ended(s, into: &out)
        return false
    }

    func encode(_ encoder: HPACKEncoder, _ name: StaticString, _ value: UnsafePointer<UInt8>, _ count: Int,
                into block: inout ByteBuffer) {
        encoder.encode(name: name.utf8Start, nameLength: name.utf8CodeUnitCount,
                       value: count > 0 ? value : emptyBlock, valueLength: count, into: &block)
    }

    /// A header block as HEADERS and as many CONTINUATIONs as it takes.
    func writeHeaderBlock(_ block: inout ByteBuffer, stream id: UInt32, endStream: Bool, frameSize: Int,
                          into out: inout ByteBuffer) {
        let total = block.readableBytes
        let origin = block.readerOffset
        var offset = 0
        var first = true
        repeat {
            let n = min(frameSize, total - offset)
            var flags: H2Flags = offset + n >= total ? .endHeaders : []
            if first && endStream { flags.insert(.endStream) }
            frame(&out, n, first ? .headers : .continuation, flags, id)
            if n > 0 { out.write(block.pointer(at: origin + offset), n) }
            offset += n
            first = false
        } while offset < total
    }

    /// DATA for the streams in `sending`, within their windows, the
    /// connection's, and a pass's share. Streams that end, or were reset,
    /// move to `finished`.
    func sendData(_ sending: inout [H2Stream], _ finished: inout [H2Stream], into out: inout ByteBuffer,
                  frameSize: Int) {
        var room = h2WritePass
        lock.withLock { _ in
            for s in sending {
                if s.reset {
                    s.grant = -1
                    continue
                }
                let grant = min(s.length - s.sent, s.sendWindow, sendWindow, room)
                if grant <= 0 {
                    s.grant = 0
                    continue
                }
                s.sendWindow -= grant
                sendWindow -= grant
                room -= grant
                s.grant = grant
            }
        }
        var i = 0
        while i < sending.count {
            let s = sending[i]
            if s.grant < 0 {
                // Reset part way: the client has said it wants no more.
                finished.append(s)
                sending.remove(at: i)
                continue
            }
            var grant = s.grant
            s.grant = 0
            if grant > 0 {
                let body = UnsafePointer(s.x.pointee.responseBody.readPointer)
                while grant > 0 {
                    let n = min(grant, frameSize)
                    frame(&out, n, .data, s.sent + n == s.length ? .endStream : [], s.id)
                    out.write(body + s.sent, n)
                    s.sent += n
                    grant -= n
                }
            }
            if s.sent == s.length {
                ended(s, into: &out)
                finished.append(s)
                sending.remove(at: i)
                continue
            }
            i += 1
        }
        // The first in line does not always go first.
        if sending.count > 1 { sending.append(sending.removeFirst()) }
    }

    /// After a stream's END_STREAM: the reset a 413 asks for.
    func ended(_ s: H2Stream, into out: inout ByteBuffer) {
        guard let code = s.resetAfter else { return }
        frame(&out, 4, .rstStream, [], s.id)
        HTTP2.writeUInt32(code.rawValue, into: &out)
    }
}
