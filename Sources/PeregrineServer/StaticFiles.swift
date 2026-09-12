//===----------------------------------------------------------------------===//
// Serving files from disk, for --static-dir.
//
// A request matching a route prefix is answered here, with the bytes going
// from the page cache to the socket without entering this process: `flush`
// hands the descriptor to sendfile(2) and the kernel does the copy. That is
// the whole reason for the feature. Reaching Python to serve a CSS file means
// an interpreter, a dictionary of CGI variables and a list of byte strings per
// asset, and none of it changes what arrives at the client.
//
// Two transports cannot take that path and fall back to reading the file into
// the write buffer:
//
//   * TLS, because the bytes have to be encrypted, and the kernel has no idea
//     how. (Linux kTLS could, and is not worth the configuration surface.)
//   * HTTP/2 and HTTP/3, because the bytes have to be framed and multiplexed
//     with everything else on the connection.
//
// The fallback is not a slow path in any sense that matters -- it is what a
// framework would have done anyway, minus the interpreter -- so a route is not
// refused on a connection that cannot sendfile.
//
// Not served: byte ranges, directory indexes, and Last-Modified. Ranges and
// indexes are absent because they are a real amount of behaviour and this is
// an asset route, not a file server. Last-Modified is absent because ETag is
// the stronger validator and emitting only one means a client can only ask the
// question that can be answered exactly: a date has one-second resolution and
// says nothing about a file that changed twice in a second.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP

/// What one turn of the static-file pump achieved.
public enum FilePump {
    /// The file is spent; the response is over.
    case done
    /// A block was put in the write buffer and still has to be sent.
    case buffered
    /// The socket would block; write interest is armed.
    case again
    /// The connection is gone.
    case closed
}

extension Worker {

    /// Moves the next piece of a static file towards the client.
    mutating func pumpFile(_ slot: Int) -> FilePump {
        let c = table[slot]

        // Over TLS the bytes have to be encrypted, which the kernel cannot do
        // for us, so they come through the buffer a block at a time.
        if c.pointee.tls != nil {
            let want = min(c.pointee.fileRemaining, config.readBufferSize)
            c.pointee.write.reserve(want)
            let got = pg_read(c.pointee.fileFD, c.pointee.write.writePointer, want)
            if got <= 0 {
                // The file was truncated or the read failed after a
                // Content-Length had already been promised. There is no honest
                // way to finish the message, so the connection ends -- which is
                // what tells the client the body is short.
                finishFile(slot)
                closeConnection(slot)
                return .closed
            }
            c.pointee.write.advanceWriter(got)
            c.pointee.fileRemaining -= got
            // The descriptor is done with even though the bytes are not sent
            // yet; holding it until the buffer drains keeps it open for no
            // reason. `.buffered` still sends what was just read.
            if c.pointee.fileRemaining == 0 { finishFile(slot) }
            return .buffered
        }

        while c.pointee.fileRemaining > 0 {
            var offset = off_t(c.pointee.fileOffset)
            let n = pg_sendfile(c.pointee.fd, c.pointee.fileFD, &offset,
                                c.pointee.fileRemaining)
            if n > 0 {
                c.pointee.fileOffset = Int(offset)
                c.pointee.fileRemaining -= Int(n)
                continue
            }
            let e = pg_errno()
            if pg_err_is_intr(e) != 0 { continue }
            if pg_err_is_again(e) != 0 {
                setInterest(slot, readInterestAllowed(slot) ? [.read, .write] : [.write])
                return .again
            }
            finishFile(slot)
            closeConnection(slot)
            return .closed
        }
        finishFile(slot)
        return .done
    }

    /// Releases the descriptor a response was reading from.
    mutating func finishFile(_ slot: Int) {
        let c = table[slot]
        if c.pointee.fileFD >= 0 { _ = pg_close(c.pointee.fileFD) }
        c.pointee.fileFD = -1
        c.pointee.fileRemaining = 0
        c.pointee.fileOffset = 0
    }

    /// Serves this request from a `--static-dir` route, or returns false to
    /// let it reach the application.
    ///
    /// Falling through rather than answering 404 is deliberate: a route that
    /// swallowed every path under its prefix would take those paths away from
    /// an application already serving them, and the flag is meant to sit in
    /// front of one, not replace part of it.
    mutating func serveStatic(_ slot: Int) -> Bool {
        if config.staticRoutes.isEmpty { return false }
        let c = table[slot]
        let method = c.pointee.head.method
        guard method == .get || method == .head else { return false }

        let path = c.pointee.head.path
        guard path.length > 0 else { return false }

        // Decode before matching. `%2e%2e` is `..`, and a prefix test against
        // the encoded form would let it past -- containment is checked again
        // when the path is resolved, but the two should agree about what the
        // request even said.
        let decodedLength = path.count
        guard decodedLength < 4096 else { return false }
        var decoded = [UInt8](repeating: 0, count: decodedLength + 1)
        let base = c.pointee.headBase() + Int(path.offset)
        let n: Int = decoded.withUnsafeMutableBufferPointer { buffer in
            percentDecode(base, path.count, into: buffer.baseAddress!)
        }
        // A NUL in a decoded path is an attempt to end a C string early.
        if decoded.withUnsafeBufferPointer({ $0.baseAddress!.withMemoryRebound(
            to: UInt8.self, capacity: n) { p in
                var i = 0
                while i < n { if p[i] == 0 { return true }; i += 1 }
                return false
            } }) {
            return false
        }
        decoded[n] = 0

        for route in config.staticRoutes {
            let prefixLength = Int(strlen(route.prefix))
            guard n >= prefixLength else { continue }
            var matches = true
            var i = 0
            while i < prefixLength {
                if decoded[i] != UInt8(bitPattern: route.prefix[i]) { matches = false; break }
                i += 1
            }
            guard matches else { continue }
            // The prefix has to end on a segment boundary, so /staticky is not
            // a request for the /static route.
            if n > prefixLength && decoded[prefixLength] != UInt8(ascii: "/") { continue }

            var size: Int64 = 0
            var mtime: Int64 = 0
            let fd: Int32 = decoded.withUnsafeBufferPointer { buffer in
                let relative = buffer.baseAddress! + prefixLength
                return relative.withMemoryRebound(to: CChar.self, capacity: n - prefixLength + 1) {
                    pg_static_open(route.directory, $0, &size, &mtime)
                }
            }
            if fd < 0 { continue }

            sendFile(slot, fd: fd, size: Int(size), mtime: Int(mtime),
                     nameLength: n, name: &decoded)
            return true
        }
        return false
    }

    /// Writes the response head for an open file, then arms the body.
    private mutating func sendFile(_ slot: Int, fd: Int32, size: Int, mtime: Int,
                                   nameLength: Int, name: inout [UInt8]) {
        let c = table[slot]

        // A strong validator built from what the filesystem already knows.
        // Two files with the same size and the same modification time to the
        // second are the same file for this purpose; a deployment that rewrites
        // an asset moves the mtime.
        var etag = [UInt8](repeating: 0, count: 40)
        var etagLength = 0
        etag[etagLength] = UInt8(ascii: "\""); etagLength += 1
        etagLength += writeHex(UInt64(bitPattern: Int64(mtime)), into: &etag, at: etagLength)
        etag[etagLength] = UInt8(ascii: "-"); etagLength += 1
        etagLength += writeHex(UInt64(size), into: &etag, at: etagLength)
        etag[etagLength] = UInt8(ascii: "\""); etagLength += 1

        if requestHasMatchingETag(slot, etag: &etag, length: etagLength) {
            _ = pg_close(fd)
            logAccess(slot, status: 304)
            dates.refresh()
            if c.pointee.isStream || c.pointee.isH3Stream {
                sendNotModifiedOnStream(slot, etag: &etag, etagLength: etagLength)
                return
            }
            HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: 304)
            HTTPResponseWriter.writeDate(&c.pointee.write, dates)
            c.pointee.write.write("Server: peregrine\r\nETag: ")
            etag.withUnsafeBufferPointer { c.pointee.write.write($0.baseAddress!, etagLength) }
            c.pointee.write.write("\r\n")
            HTTPResponseWriter.writeConnection(&c.pointee.write,
                                               keepAlive: c.pointee.flags.contains(.keepAlive))
            HTTPResponseWriter.endHead(&c.pointee.write)
            c.pointee.state = .writing
            _ = flush(slot)
            return
        }

        let head = c.pointee.head.method == .head
        logAccess(slot, status: 200)
        dates.refresh()

        if c.pointee.isStream || c.pointee.isH3Stream {
            startMultiplexedFile(slot, fd: fd, size: size, head: head,
                                 etag: &etag, etagLength: etagLength,
                                 nameLength: nameLength, name: &name)
            return
        }

        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: 200)
        HTTPResponseWriter.writeDate(&c.pointee.write, dates)
        c.pointee.write.write("Server: peregrine\r\nContent-Type: ")
        c.pointee.write.write(contentType(nameLength: nameLength, name: &name))
        c.pointee.write.write("\r\nETag: ")
        etag.withUnsafeBufferPointer { c.pointee.write.write($0.baseAddress!, etagLength) }
        c.pointee.write.write("\r\n")
        HTTPResponseWriter.writeContentLength(&c.pointee.write, size)
        HTTPResponseWriter.writeConnection(&c.pointee.write,
                                           keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&c.pointee.write)

        if head || size == 0 {
            _ = pg_close(fd)
        } else {
            c.pointee.fileFD = fd
            c.pointee.fileOffset = 0
            c.pointee.fileRemaining = size
        }
        c.pointee.state = .writing
        _ = flush(slot)
    }

    /// `304 Not Modified` on a multiplexed stream.
    ///
    /// No body and no content-length: a 304 carries neither, and the validator
    /// is the whole message.
    private mutating func sendNotModifiedOnStream(_ slot: Int, etag: inout [UInt8],
                                                  etagLength: Int) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        var block = ByteBuffer()
        defer { block.destroy() }

        if c.pointee.isH3Stream {
            guard parent >= 0, let h3 = table[parent].pointee.h3 else {
                closeConnection(slot)
                return
            }
            h3.encoder.begin(into: &block)
            h3.encoder.encodeStatus(304, into: &block)
            etag.withUnsafeBufferPointer {
                encodeStaticH3(h3, "etag", $0.baseAddress!, etagLength, into: &block)
            }
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
            encodeStaticH3(h3, "server", "peregrine", into: &block)
            writeH3HeaderBlock(slot, h3, block: &block)
            endEmptyH3Response(slot, h3, parent: parent)
            return
        }

        guard parent >= 0, let h2 = table[parent].pointee.h2 else {
            closeConnection(slot)
            return
        }
        h2.encoder.encodeStatus(304, into: &block)
        etag.withUnsafeBufferPointer {
            encodeStatic(h2, "etag", $0.baseAddress!, etagLength, into: &block)
        }
        encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        encodeStatic(h2, "server", "peregrine", into: &block)
        writeHeaderBlock(slot, h2, block: &block, endStream: true)
        c.pointee.flags.insert(.responseStarted)
        c.pointee.flags.insert(.responseComplete)
        c.pointee.flags.insert(.endStreamSent)
        c.pointee.state = .writing
        _ = flush(parent)
        closeStream(slot, resetWith: nil)
    }

    /// Ends an HTTP/3 response whose header block is already queued and which
    /// has no body: a HEAD, a zero-length file, or a 304.
    ///
    /// The same sequence `h3FailRequest` uses, and deliberately not the one the
    /// application path uses. A response produced inside `dispatch` has never
    /// been in the `.writing` state the stream flusher is built around -- it is
    /// finished before the poller sees the stream at all -- and putting it
    /// there so the flusher would end it left the connection unable to serve
    /// the next request. The FIN and the retirement go out here instead, which
    /// is what the health-check path has always done.
    private mutating func endEmptyH3Response(_ slot: Int, _ h3: H3Connection,
                                             parent: Int) {
        let c = table[slot]
        c.pointee.flags.insert(.responseComplete)
        c.pointee.flags.insert(.endStreamSent)
        h3.quic.send(c.pointee.qstreamID, emptyH3Byte, 0, fin: true)
        flushQUIC(parent)
        closeH3Stream(slot)
    }

    /// The same response on an HTTP/2 or HTTP/3 stream.
    ///
    /// sendfile cannot be used here whatever the transport underneath: the
    /// bytes have to be framed and interleaved with every other stream on the
    /// connection. They are read into the stream's write buffer instead, a
    /// block at a time as the flow-control window opens, by the hook the two
    /// stream flushers call.
    private mutating func startMultiplexedFile(_ slot: Int, fd: Int32, size: Int,
                                               head: Bool,
                                               etag: inout [UInt8], etagLength: Int,
                                               nameLength: Int, name: inout [UInt8]) {
        let c = table[slot]
        let type = contentType(nameLength: nameLength, name: &name)
        var length = [UInt8](repeating: 0, count: 24)
        var lengthCount = 0
        lengthCount = writeDecimal(size, into: &length)

        let empty = head || size == 0
        var block = ByteBuffer()
        defer { block.destroy() }

        if c.pointee.isH3Stream {
            let parent = Int(c.pointee.parentSlot)
            guard parent >= 0, let h3 = table[parent].pointee.h3 else {
                _ = pg_close(fd)
                closeConnection(slot)
                return
            }
            h3.encoder.begin(into: &block)
            h3.encoder.encodeStatus(200, into: &block)
            encodeStaticH3(h3, "content-type", type.utf8Start, type.utf8CodeUnitCount,
                           into: &block)
            etag.withUnsafeBufferPointer {
                encodeStaticH3(h3, "etag", $0.baseAddress!, etagLength, into: &block)
            }
            length.withUnsafeBufferPointer {
                encodeStaticH3(h3, "content-length", $0.baseAddress!, lengthCount, into: &block)
            }
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
            encodeStaticH3(h3, "server", "peregrine", into: &block)
            writeH3HeaderBlock(slot, h3, block: &block)
        } else {
            let parent = Int(c.pointee.parentSlot)
            guard parent >= 0, let h2 = table[parent].pointee.h2 else {
                _ = pg_close(fd)
                closeConnection(slot)
                return
            }
            h2.encoder.encodeStatus(200, into: &block)
            encodeStatic(h2, "content-type", type.utf8Start, type.utf8CodeUnitCount,
                         into: &block)
            etag.withUnsafeBufferPointer {
                encodeStatic(h2, "etag", $0.baseAddress!, etagLength, into: &block)
            }
            length.withUnsafeBufferPointer {
                encodeStatic(h2, "content-length", $0.baseAddress!, lengthCount, into: &block)
            }
            encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
            encodeStatic(h2, "server", "peregrine", into: &block)
            writeHeaderBlock(slot, h2, block: &block, endStream: empty)
        }

        c.pointee.flags.insert(.responseStarted)

        if empty {
            _ = pg_close(fd)
            // Read before finishing: that retires the stream, and a retired
            // slot no longer knows which connection it belonged to.
            let owner = Int(c.pointee.parentSlot)
            if c.pointee.isH3Stream, let h3 = table[owner].pointee.h3 {
                endEmptyH3Response(slot, h3, parent: owner)
                return
            }
            c.pointee.flags.insert(.responseComplete)
            c.pointee.flags.insert(.endStreamSent)
            c.pointee.state = .writing
            _ = flush(owner)
            closeStream(slot, resetWith: nil)
            return
        }

        // The declared length, which is what tells the stream flusher whether
        // the body it sent matched the promise.
        c.pointee.state = .writing
        c.pointee.responseRemaining = size
        c.pointee.fileFD = fd
        c.pointee.fileOffset = 0
        c.pointee.fileRemaining = size
        _ = flush(slot)
    }

    /// Refills a stream's write buffer from the file behind it.
    ///
    /// Called from the two stream flushers whenever their buffer has emptied
    /// and a file is still owed. One comparison on a response with no file,
    /// which is every response the application produces.
    mutating func refillStreamFromFile(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.fileRemaining > 0, c.pointee.write.readableBytes == 0 else { return }
        let want = min(c.pointee.fileRemaining, config.readBufferSize)
        c.pointee.write.reserve(want)
        let got = pg_read(c.pointee.fileFD, c.pointee.write.writePointer, want)
        if got <= 0 {
            // Truncated under us after a length was promised. Marking the
            // response complete with bytes still owed is what makes the
            // flusher reset the stream rather than claim it finished.
            finishFile(slot)
            c.pointee.flags.insert(.responseComplete)
            return
        }
        c.pointee.write.advanceWriter(got)
        c.pointee.fileRemaining -= got
        c.pointee.responseRemaining -= got
        if c.pointee.fileRemaining == 0 {
            finishFile(slot)
            c.pointee.flags.insert(.responseComplete)
        }
    }

    /// Whether `If-None-Match` names the entity we were about to send.
    ///
    /// `*` matches anything that exists, per RFC 9110. A list of tags is
    /// compared member by member; a weak prefix is skipped, because a weak
    /// comparison is the right one for a plain GET.
    private func requestHasMatchingETag(_ slot: Int, etag: inout [UInt8],
                                        length: Int) -> Bool {
        let c = table[slot]
        let base = c.pointee.headBase()
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 13 else { continue }
            guard equalsLowercased(base + Int(h.name.offset), 13, "if-none-match") else { continue }

            let value = base + Int(h.value.offset)
            let valueLength = Int(h.value.length)
            var j = 0
            while j < valueLength {
                while j < valueLength, value[j] == UInt8(ascii: " ")
                        || value[j] == UInt8(ascii: ",") { j += 1 }
                if j >= valueLength { break }
                if value[j] == UInt8(ascii: "*") { return true }
                // Skip a weak marker: W/"..."
                if j + 1 < valueLength, value[j] == UInt8(ascii: "W"),
                   value[j + 1] == UInt8(ascii: "/") {
                    j += 2
                }
                var k = j
                while k < valueLength, value[k] != UInt8(ascii: ",") { k += 1 }
                var end = k
                while end > j, value[end - 1] == UInt8(ascii: " ") { end -= 1 }
                if end - j == length {
                    var same = true
                    var m = 0
                    while m < length {
                        if value[j + m] != etag[m] { same = false; break }
                        m += 1
                    }
                    if same { return true }
                }
                j = k
            }
            return false
        }
        return false
    }
}

/// Base-ten, into the front of `out`. Returns how many bytes were written.
private func writeDecimal(_ value: Int, into out: inout [UInt8]) -> Int {
    if value == 0 {
        out[0] = UInt8(ascii: "0")
        return 1
    }
    var digits = [UInt8](repeating: 0, count: 24)
    var n = 0
    var v = value
    while v > 0 {
        digits[n] = UInt8(ascii: "0") + UInt8(v % 10)
        n += 1
        v /= 10
    }
    var i = 0
    while i < n {
        out[i] = digits[n - 1 - i]
        i += 1
    }
    return n
}

/// Lowercase hex, no padding. Returns how many bytes were written.
private func writeHex(_ value: UInt64, into out: inout [UInt8], at offset: Int) -> Int {
    if value == 0 {
        out[offset] = UInt8(ascii: "0")
        return 1
    }
    var digits = [UInt8](repeating: 0, count: 16)
    var n = 0
    var v = value
    while v > 0 {
        let nibble = UInt8(v & 0xF)
        digits[n] = nibble < 10 ? UInt8(ascii: "0") + nibble
                                : UInt8(ascii: "a") + (nibble - 10)
        n += 1
        v >>= 4
    }
    var i = 0
    while i < n {
        out[offset + i] = digits[n - 1 - i]
        i += 1
    }
    return n
}

/// A media type for the extension, or `application/octet-stream`.
///
/// Deliberately short: the types an asset route actually serves. Anything
/// unrecognised is a download rather than a guess, which is the safe answer --
/// serving an unknown file as text/html is how a user upload becomes a
/// scripting vector.
private func contentType(nameLength: Int, name: inout [UInt8]) -> StaticString {
    var dot = -1
    var i = nameLength - 1
    while i >= 0 {
        if name[i] == UInt8(ascii: "/") { break }
        if name[i] == UInt8(ascii: ".") { dot = i; break }
        i -= 1
    }
    guard dot >= 0 else { return "application/octet-stream" }
    let start = dot + 1
    let length = nameLength - start

    func ext(_ s: StaticString) -> Bool {
        guard s.utf8CodeUnitCount == length else { return false }
        var k = 0
        while k < length {
            var a = name[start + k]
            if a >= 65 && a <= 90 { a += 32 }   // fold to lowercase
            if a != s.utf8Start[k] { return false }
            k += 1
        }
        return true
    }

    if ext("html") || ext("htm") { return "text/html; charset=utf-8" }
    if ext("css")   { return "text/css; charset=utf-8" }
    if ext("js")    { return "text/javascript; charset=utf-8" }
    if ext("mjs")   { return "text/javascript; charset=utf-8" }
    if ext("json")  { return "application/json" }
    if ext("map")   { return "application/json" }
    if ext("txt")   { return "text/plain; charset=utf-8" }
    if ext("xml")   { return "application/xml" }
    if ext("svg")   { return "image/svg+xml" }
    if ext("png")   { return "image/png" }
    if ext("jpg") || ext("jpeg") { return "image/jpeg" }
    if ext("gif")   { return "image/gif" }
    if ext("webp")  { return "image/webp" }
    if ext("avif")  { return "image/avif" }
    if ext("ico")   { return "image/x-icon" }
    if ext("woff2") { return "font/woff2" }
    if ext("woff")  { return "font/woff" }
    if ext("ttf")   { return "font/ttf" }
    if ext("otf")   { return "font/otf" }
    if ext("wasm")  { return "application/wasm" }
    if ext("pdf")   { return "application/pdf" }
    if ext("mp4")   { return "video/mp4" }
    if ext("webm")  { return "video/webm" }
    if ext("mp3")   { return "audio/mpeg" }
    if ext("zip")   { return "application/zip" }
    return "application/octet-stream"
}
