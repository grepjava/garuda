//===----------------------------------------------------------------------===//
// Serving files from disk: --static-dir and --spa-fallback.
//
// A GET or HEAD under a `--static-dir` prefix is answered from the directory
// before the application's routes see it; a path there that names no file
// falls through to them. The file is opened beneath the directory by the
// kernel where it can (VegaFS's `File.open(beneath:)`), so `..` and symbolic
// links cannot reach outside it.
//
// How the bytes go:
//
//   * A file of up to 16 KiB is read into the answer and goes with its head
//     in one write. Handing a kilobyte of CSS to sendfile costs a second
//     system call to save a copy the size of a page.
//   * A larger one over plain HTTP/1 goes by sendfile(2): from the page cache
//     to the socket without entering this process.
//   * Over TLS, and over HTTP/2, the bytes have to be encrypted or framed
//     here, so they are read a block at a time and written as a streamed
//     body of known length (StreamingResponse.swift) -- which waits for a
//     slow client, and on HTTP/2 for the window, as any streamed body does.
//
// A `Range` is served as 206 with `Content-Range`, on every one of those
// paths. One range: `multipart/byteranges` would mean interleaving boundary
// text with a file being handed to the kernel, for something almost nothing
// asks for, and a request for several is answered whole, which RFC 9110
// section 14.2 allows. `If-Range` holds the range to the client's copy still
// being current.
//
// The validator is a strong ETag made from the size and the modification
// time to the nanosecond. Not served: Last-Modified. Emitting only one means
// a client can only ask the question that can be answered exactly.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega
import VegaFS
import VegaIO
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// The directories a server answers from, worked out once from the config.
final class StaticSite: Sendable {
    struct Route: Sendable {
        let prefix: [UInt8]
        let directory: String
    }

    struct Fallback: Sendable {
        let prefix: [UInt8]
        let directory: String
        let file: String
    }

    /// Longest prefix first, so a more specific one wins.
    let routes: [Route]
    let fallbacks: [Fallback]
    let index: Bool
    let listing: Bool
    let listingLimit: Int
    /// --compress-static.
    let compress: Bool

    init?(_ config: ServerConfig) {
        guard !config.staticDirectories.isEmpty || !config.spaFallbacks.isEmpty else { return nil }
        routes = config.staticDirectories
            .map { Route(prefix: Array($0.prefix.utf8), directory: $0.directory) }
            .sorted { $0.prefix.count > $1.prefix.count }
        fallbacks = config.spaFallbacks
            .map { Fallback(prefix: Array($0.prefix.utf8), directory: $0.directory, file: $0.file) }
            .sorted { $0.prefix.count > $1.prefix.count }
        index = config.staticIndex || config.staticListing
        listing = config.staticListing
        listingLimit = config.staticListingLimit
        compress = config.compressStatic
    }

    /// Whether a `--static-dir` route may answer `path`, as the request has
    /// it: such a request is never answered on HTTP/2's reader, whose
    /// stream would then wait on the window it is the one to read.
    func mayServe(_ path: ByteSpan) -> Bool {
        for route in routes where covers(route.prefix, path) { return true }
        return false
    }
}

/// Whether a `--static-dir` route may answer `x`'s request.
@inline(never)
func staticMayServe(_ x: UnsafeMutablePointer<Exchange>) -> Bool {
    guard let site = x.pointee.site else { return false }
    return site.mayServe(x.pointee.slice(x.pointee.head.path))
}

/// Whether `prefix` covers `path` in whole segments. "/" covers every path.
private func covers(_ prefix: [UInt8], _ path: ByteSpan) -> Bool {
    guard path.count >= prefix.count else { return false }
    for i in 0..<prefix.count where path.base[i] != prefix[i] { return false }
    return prefix.count == 1 || path.count == prefix.count || path.base[prefix.count] == UInt8(ascii: "/")
}

/// Files of up to this size are read into the answer rather than sent after
/// the head.
let inlineFileBytes = 16 * 1024

/// A block of a file read for a body that cannot go by sendfile.
let fileBlockBytes = 64 * 1024

// MARK: - Finding the file

/// Serves this request from a `--static-dir` route, or returns false to let
/// it reach the application.
///
/// Falling through rather than answering 404 is deliberate: a route that
/// swallowed every path under its prefix would take those paths away from
/// an application already serving them.
func serveStatic(_ x: UnsafeMutablePointer<Exchange>) async -> Bool {
    let method = x.pointee.head.method
    guard method == .get || method == .head, let site = x.pointee.site, !site.routes.isEmpty else { return false }
    let raw = x.pointee.slice(x.pointee.head.path)
    guard raw.count > 0, raw.count < 4096 else { return false }
    // Decoded before matching: `%2e%2e` is `..`, and the prefix test and the
    // open should agree about what the request said.
    var decoded = [UInt8](repeating: 0, count: raw.count)
    let n = decoded.withUnsafeMutableBufferPointer { percentDecode(raw.base, raw.count, into: $0.baseAddress!) }
    decoded.removeLast(raw.count - n)
    // A NUL in a decoded path is an attempt to end a C string early.
    if decoded.contains(0) { return false }

    for route in site.routes {
        let prefix = route.prefix
        guard n >= prefix.count, decoded.starts(with: prefix) else { continue }
        // The prefix ends on a segment boundary: /staticky is not under
        // /static. "/" is the whole tree.
        if prefix.count > 1 && n > prefix.count && decoded[prefix.count] != UInt8(ascii: "/") { continue }
        let start = prefix == [UInt8(ascii: "/")] ? 0 : prefix.count
        let relative = String(decoding: decoded[start...], as: UTF8.self)
        do {
            let file = try File.open(beneath: route.directory, relative)
            if site.compress {
                // --compress-static: a copy compressed at build time, beside
                // the file, in the order the client prefers. The original
                // has to exist too -- a lone `app.js.br` is not a route to
                // `app.js` -- because a client that accepts nothing still
                // has to be served.
                let type = contentType(decoded)
                let compressible = CompressionEligibility.isCompressible(type.utf8Start, type.utf8CodeUnitCount)
                for coding in x.pointee.acceptEncoding().ranked({ _ in true }) {
                    let suffix = coding.fileSuffix
                    let name = relative + String(decoding: UnsafeBufferPointer(start: suffix.utf8Start,
                                                                               count: suffix.utf8CodeUnitCount),
                                                 as: UTF8.self)
                    if let copy = try? File.open(beneath: route.directory, name) {
                        await sendStaticFile(x, copy, name: decoded, coding: coding, vary: true)
                        return true
                    }
                }
                await sendStaticFile(x, file, name: decoded, vary: compressible)
                return true
            }
            await sendStaticFile(x, file, name: decoded)
            return true
        } catch {
            // No file there. It may still be a directory somebody asked to
            // have answered (StaticDirectories.swift).
            if error.code == EISDIR, site.index,
               await serveDirectory(x, site, route, decoded: decoded, relativeStart: start) {
                return true
            }
        }
    }
    return false
}

/// Serves a `--spa-fallback` page for a GET or HEAD that no file, route or
/// scope fallback answered, when it is under the fallback's prefix and
/// accepts `text/html`: a browser navigating to a client-side route. A
/// request for a missing script or image, or an API call, does not ask for
/// HTML, and keeps its 404.
func serveSPAFallback(_ x: UnsafeMutablePointer<Exchange>) async -> Bool {
    let method = x.pointee.head.method
    guard method == .get || method == .head, let site = x.pointee.site, !site.fallbacks.isEmpty,
          let accept = x.pointee.header(StaticString("accept").utf8Start, 6), acceptsHTML(accept) else {
        return false
    }
    let path = x.pointee.slice(x.pointee.head.path)
    for fallback in site.fallbacks where covers(fallback.prefix, path) {
        do {
            let file = try File.open(beneath: fallback.directory, fallback.file)
            await sendStaticFile(x, file, name: Array(fallback.file.utf8))
            return true
        } catch {
            continue
        }
    }
    return false
}

// MARK: - Answering with it

/// Answers with `file`, whose request path was `name`: the head from what
/// the filesystem says of it, the request's preconditions and range, then
/// the bytes.
func sendStaticFile(_ x: UnsafeMutablePointer<Exchange>, _ file: borrowing File, name: [UInt8],
                    coding: ContentCoding = .identity, vary: Bool = false) async {
    // Its bytes are as the directory has them: a compressed copy is chosen
    // before this, not made by --compress.
    x.pointee.noCompress = true
    let size: Int
    let mtime: Int64
    do {
        let metadata = try file.metadataNow()
        size = metadata.size
        mtime = metadata.modified.seconds &* 1_000_000_000 &+ Int64(metadata.modified.nanoseconds)
    } catch {
        x.pointee.answer(500, nil, 0)
        return
    }
    let response = Response(x)
    // A strong validator from what the filesystem already knows: two files
    // of the same size modified at the same nanosecond are the same file
    // here. Whole seconds were not enough: a build that rewrote an asset at
    // the same size within a second left the old tag matching.
    var etag: [UInt8] = [UInt8(ascii: "\"")]
    appendHex(UInt64(bitPattern: mtime), to: &etag)
    etag.append(UInt8(ascii: "-"))
    appendHex(UInt64(size), to: &etag)
    if coding != .identity {
        // A compressed copy is a different representation, and a strong
        // validator says so even if its size and time matched the original's.
        etag.append(UInt8(ascii: "-"))
        let token = coding.token
        etag.append(contentsOf: UnsafeBufferPointer(start: token.utf8Start, count: token.utf8CodeUnitCount))
    }
    etag.append(UInt8(ascii: "\""))
    // With pre-compressed copies being served, which bytes a URL gets
    // depends on Accept-Encoding, and a cache has to be told so -- on the
    // plain response as much as on a compressed one.
    if vary { response.addHeader("vary", "Accept-Encoding") }

    // Preconditions in the order RFC 9110 section 13.2.2 gives them.
    if failsIfMatch(x, etag) {
        x.pointee.answer(412, nil, 0)
        return
    }
    if matchesIfNoneMatch(x, etag) {
        etag.withUnsafeBufferPointer { response.addHeader("etag", $0.span) }
        x.pointee.answer(304, nil, 0)
        return
    }

    // What of it to send. A range outside the file is 416 carrying the size,
    // which is how a client learns what it should have asked for.
    var start = 0
    var length = size
    var status = 200
    switch requestedRange(x, etag, size: size) {
    case .whole:
        break
    case .bytes(let from, let count):
        start = from
        length = count
        status = 206
    case .unsatisfiable:
        let range = "bytes */\(size)"
        response.addHeader("content-range", range)
        response.addHeader("accept-ranges", "bytes")
        x.pointee.answer(416, nil, 0)
        return
    }

    _ = x.pointee.addContentType(contentType(name))
    if coding != .identity {
        let token = coding.token
        response.addHeader("content-encoding", UnsafeBufferPointer(start: token.utf8Start,
                                                                   count: token.utf8CodeUnitCount).span)
    }
    response.addHeader("accept-ranges", "bytes")
    etag.withUnsafeBufferPointer { response.addHeader("etag", $0.span) }
    if status == 206 {
        response.addHeader("content-range", "bytes \(start)-\(start + length - 1)/\(size)")
    }

    if x.pointee.head.method == .head {
        // The GET's headers, its length among them, and none of its body.
        response.addHeader("content-length", String(length))
        x.pointee.status = status
        _ = startStream(x)
        return
    }
    if length <= inlineFileBytes {
        // With its head, in one write.
        x.pointee.responseBody.reserve(length)
        let into = x.pointee.responseBody.writePointer
        var got = 0
        while got < length {
            let n = (try? file.readNow(into: UnsafeMutableRawBufferPointer(start: into + got, count: length - got),
                                       at: start + got)) ?? 0
            if n <= 0 { break }
            got += n
        }
        guard got == length else {
            // Shorter than it was a moment ago: nothing has been promised
            // yet, so the honest answer is a failure.
            x.pointee.answer(500, nil, 0)
            return
        }
        x.pointee.responseBody.advanceWriter(length)
        x.pointee.answered = true
        x.pointee.status = status
        return
    }
    response.addHeader("content-length", String(length))
    x.pointee.status = status
    let channel = startStream(x)
    do {
        try await channel.sendFile(file, from: start, count: length)
    } catch {
        // The client went, or the file shrank under a promised length:
        // either way the body cannot be finished.
        channel.handlerFailed = true
    }
}

// MARK: - Preconditions and ranges

/// The values of every request header named `name`, which is lowercase.
private func forEachHeader(_ x: UnsafeMutablePointer<Exchange>, _ name: StaticString, _ body: (ByteSpan) -> Void) {
    var i = 0
    while i < x.pointee.head.headerCount {
        let h = x.pointee.headers[i]
        i &+= 1
        let n = x.pointee.slice(h.name)
        if n.count == name.utf8CodeUnitCount && equalsLowercased(n.base, n.count, name) {
            body(x.pointee.slice(h.value))
        }
    }
}

/// Calls `body` with each member of a comma-separated list, trimmed.
private func forEachMember(_ value: ByteSpan, _ body: (ByteSpan) -> Bool) {
    var j = 0
    while j < value.count {
        while j < value.count, value.base[j] == 0x20 || value.base[j] == 0x09 || value.base[j] == 0x2C { j &+= 1 }
        if j >= value.count { return }
        var k = j
        while k < value.count, value.base[k] != 0x2C { k &+= 1 }
        var end = k
        while end > j, value.base[end - 1] == 0x20 || value.base[end - 1] == 0x09 { end &-= 1 }
        if !body(ByteSpan(value.base + j, end - j)) { return }
        j = k
    }
}

private func same(_ a: ByteSpan, _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    for i in 0..<b.count where a.base[i] != b[i] { return false }
    return true
}

/// Whether `If-Match` rules this response out (RFC 9110 section 13.1.1): it
/// is there, and is neither `*` nor a list naming this entity. The
/// comparison is strong, so a weak tag never matches.
func failsIfMatch(_ x: UnsafeMutablePointer<Exchange>, _ etag: [UInt8]) -> Bool {
    var present = false
    var matched = false
    forEachHeader(x, "if-match") { value in
        present = true
        forEachMember(value) { member in
            if (member.count == 1 && member.base[0] == UInt8(ascii: "*")) || same(member, etag) {
                matched = true
                return false
            }
            return true
        }
    }
    return present && !matched
}

/// Whether `If-None-Match` names this entity: `*`, or a tag in the list,
/// compared weakly, as a GET's is.
func matchesIfNoneMatch(_ x: UnsafeMutablePointer<Exchange>, _ etag: [UInt8]) -> Bool {
    var matched = false
    forEachHeader(x, "if-none-match") { value in
        forEachMember(value) { member in
            var m = member
            if m.count == 1 && m.base[0] == UInt8(ascii: "*") {
                matched = true
                return false
            }
            if m.count >= 2 && m.base[0] == UInt8(ascii: "W") && m.base[1] == UInt8(ascii: "/") {
                m = ByteSpan(m.base + 2, m.count - 2)
            }
            if same(m, etag) {
                matched = true
                return false
            }
            return true
        }
    }
    return matched
}

/// What the request's `Range` asks for, once `If-Range` has had its say:
/// the range only while the client's copy is this one. A date never matches,
/// since no Last-Modified was served to be given back.
func requestedRange(_ x: UnsafeMutablePointer<Exchange>, _ etag: [UInt8], size: Int) -> StaticRange {
    var range = StaticRange.whole
    forEachHeader(x, "range") { range = parseByteRange($0.base, $0.count, size: size) }
    guard case .bytes = range else { return range }
    var current = true
    forEachHeader(x, "if-range") { value in
        var s = 0
        var e = value.count
        while s < e, value.base[s] == 0x20 { s &+= 1 }
        while e > s, value.base[e - 1] == 0x20 { e &-= 1 }
        // Strong, and nothing else will do: a weak tag says two
        // representations are equivalent, not that their bytes line up.
        if !same(ByteSpan(value.base + s, e - s), etag) { current = false }
    }
    return current ? range : .whole
}

/// What a `Range` header asks of a representation of a known size.
enum StaticRange: Equatable {
    /// No range to serve: the header is absent, asks for something this does
    /// not do, or is not a range at all. RFC 9110 section 14.2 says an
    /// unsatisfiable syntax is ignored, and the whole thing is sent.
    case whole
    /// The bytes from `start`, `length` of them.
    case bytes(start: Int, length: Int)
    /// Inside the syntax and outside the file: 416.
    case unsatisfiable
}

/// Reads `bytes=…` against a representation of `size` bytes. One range only:
/// a request for several is answered whole.
func parseByteRange(_ value: UnsafePointer<UInt8>, _ count: Int, size: Int) -> StaticRange {
    var i = 0
    while i < count, value[i] == 0x20 || value[i] == 0x09 { i += 1 }
    // Only `bytes`. Another unit is one this does not serve.
    guard count - i >= 6, equalsLowercased(value + i, 5, "bytes"), value[i + 5] == UInt8(ascii: "=") else {
        return .whole
    }
    i += 6
    while i < count, value[i] == 0x20 { i += 1 }

    func digits() -> (value: Int, count: Int) {
        var out = 0
        var seen = 0
        while i < count, value[i] >= UInt8(ascii: "0"), value[i] <= UInt8(ascii: "9") {
            // Enough for any file, and short of anything that could overflow.
            if seen < 18 { out = out * 10 + Int(value[i] - UInt8(ascii: "0")) }
            seen += 1
            i += 1
        }
        return (seen > 18 ? Int.max : out, seen)
    }

    let first = digits()
    guard i < count, value[i] == UInt8(ascii: "-") else { return .whole }
    i += 1
    let last = digits()
    while i < count, value[i] == 0x20 || value[i] == 0x09 { i += 1 }
    // Anything left is a second range, or rubbish. Either way, whole.
    guard i == count else { return .whole }

    if first.count == 0 {
        // `-N`: the last N bytes. `bytes=-` names neither end.
        guard last.count > 0 else { return .whole }
        guard last.value > 0, size > 0 else { return .unsatisfiable }
        let length = min(last.value, size)
        return .bytes(start: size - length, length: length)
    }
    guard first.value < size else { return .unsatisfiable }
    let end = last.count == 0 ? size - 1 : min(last.value, size - 1)
    // `500-499` is not a range: ignored.
    guard end >= first.value else { return .whole }
    return .bytes(start: first.value, length: end - first.value + 1)
}

/// The same, for a test that has the header as text.
func parseByteRange(_ text: String, size: Int) -> StaticRange {
    var bytes = Array(text.utf8)
    if bytes.isEmpty { return .whole }
    return bytes.withUnsafeMutableBufferPointer { parseByteRange($0.baseAddress!, $0.count, size: size) }
}

// MARK: - Small things

/// Lowercase hex, no padding.
private func appendHex(_ value: UInt64, to out: inout [UInt8]) {
    if value == 0 {
        out.append(UInt8(ascii: "0"))
        return
    }
    var shift = (63 - value.leadingZeroBitCount) / 4 * 4
    while shift >= 0 {
        let nibble = UInt8((value >> UInt64(shift)) & 0xF)
        out.append(nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10)
        shift -= 4
    }
}

/// A media type for the name's extension, or `application/octet-stream`.
///
/// Deliberately short: the types an asset route actually serves. Anything
/// unrecognised is a download rather than a guess, which is the safe answer:
/// serving an unknown file as text/html is how an upload becomes a script.
func contentType(_ name: [UInt8]) -> StaticString {
    var dot = -1
    var i = name.count - 1
    while i >= 0 {
        if name[i] == UInt8(ascii: "/") { break }
        if name[i] == UInt8(ascii: ".") { dot = i; break }
        i -= 1
    }
    guard dot >= 0 else { return "application/octet-stream" }
    let start = dot + 1
    let length = name.count - start

    func ext(_ s: StaticString) -> Bool {
        guard s.utf8CodeUnitCount == length else { return false }
        for k in 0..<length where asciiLower(name[start + k]) != s.utf8Start[k] { return false }
        return true
    }

    if ext("html") || ext("htm") { return "text/html; charset=utf-8" }
    if ext("css") { return "text/css; charset=utf-8" }
    if ext("js") || ext("mjs") { return "text/javascript; charset=utf-8" }
    if ext("json") || ext("map") { return "application/json" }
    if ext("txt") { return "text/plain; charset=utf-8" }
    if ext("xml") { return "application/xml" }
    if ext("svg") { return "image/svg+xml" }
    if ext("png") { return "image/png" }
    if ext("jpg") || ext("jpeg") { return "image/jpeg" }
    if ext("gif") { return "image/gif" }
    if ext("webp") { return "image/webp" }
    if ext("avif") { return "image/avif" }
    if ext("ico") { return "image/x-icon" }
    if ext("woff2") { return "font/woff2" }
    if ext("woff") { return "font/woff" }
    if ext("ttf") { return "font/ttf" }
    if ext("otf") { return "font/otf" }
    if ext("wasm") { return "application/wasm" }
    if ext("pdf") { return "application/pdf" }
    if ext("mp4") { return "video/mp4" }
    if ext("webm") { return "video/webm" }
    if ext("mp3") { return "audio/mpeg" }
    if ext("zip") { return "application/zip" }
    return "application/octet-stream"
}

/// Whether an Accept value names `text/html` or `application/xhtml+xml`,
/// without regard to case. `*/*` alone does not count: that is what `fetch`
/// and most clients send, and they want the 404.
func acceptsHTML(_ accept: ByteSpan) -> Bool {
    let needles: [[UInt8]] = [Array("text/html".utf8), Array("application/xhtml+xml".utf8)]
    for needle in needles where accept.count >= needle.count {
        var start = 0
        while start + needle.count <= accept.count {
            var i = 0
            while i < needle.count && asciiLower(accept.base[start + i]) == needle[i] { i += 1 }
            if i == needle.count { return true }
            start += 1
        }
    }
    return false
}
