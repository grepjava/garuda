//===----------------------------------------------------------------------===//
// Answering a request for a directory under --static-dir.
//
// Off unless asked for. A directory nobody serves falls through to the
// application, and taking that path away from it is a decision, not a
// default. `--static-index` answers a directory with its `index.html`;
// `--static-listing` also answers one that has no index with a list of what
// is in it.
//
// The index is an ordinary file, opened beneath the route's directory like
// any other, with the same ETag, ranges and conditional requests. A listing
// opens a directory, so its containment is checked here: the path has no
// `.` or `..` segment, and resolving it changes nothing -- no symbolic link
// anywhere along it, even one that stays inside the tree. Knowing that one
// stays inside needs the resolution the file open does, and refusing is the
// half that cannot be wrong.
//
// A directory asked for without its trailing slash is a 301 to the slash, so
// that every link in the listing can be relative to it.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega
import VegaFS
import VegaIO

/// Answers a request for a directory, or returns false to leave the request
/// to whatever comes after `--static-dir`. `decoded` is the percent-decoded
/// request path, and the part after the route's prefix starts at
/// `relativeStart`.
func serveDirectory(_ x: UnsafeMutablePointer<Exchange>, _ site: StaticSite, _ route: StaticSite.Route,
                    decoded: [UInt8], relativeStart: Int) async -> Bool {
    let relative = String(decoding: decoded[relativeStart...], as: UTF8.self)
    let endsInSlash = decoded.last == UInt8(ascii: "/")

    // An index file first, whichever flag is on: a page somebody wrote beats
    // a list of file names.
    let indexPath = relative.hasSuffix("/") ? relative + "index.html" : relative + "/index.html"
    if let served = try? File.open(beneath: route.directory, indexPath) {
        // Without the slash the links inside the page would resolve against
        // the parent, so the client is sent to the slash first.
        if !endsInSlash {
            redirectToSlash(x)
            return true
        }
        await sendStaticFile(x, served, name: Array(indexPath.utf8))
        return true
    }

    guard site.listing else { return false }
    var segments: [Substring] = []
    for segment in relative.split(separator: "/", omittingEmptySubsequences: true) {
        // `.` goes nowhere and `..` goes out: neither is walked.
        if segment == "." || segment == ".." { return false }
        segments.append(segment)
    }
    guard let root = try? await FileSystem.canonicalPath(route.directory) else { return false }
    let directory = segments.isEmpty ? root : root + "/" + segments.joined(separator: "/")
    guard let resolved = try? await FileSystem.canonicalPath(directory), resolved == directory,
          let metadata = try? await FileSystem.metadata(directory, followingSymbolicLinks: false),
          metadata.isDirectory else {
        return false
    }
    if !endsInSlash {
        redirectToSlash(x)
        return true
    }
    guard let page = await directoryPage(directory, path: decoded, limit: site.listingLimit) else { return false }
    let response = Response(x)
    _ = x.pointee.addContentType("text/html; charset=utf-8")
    // A listing is what the directory holds right now, and it has no
    // validator to check that against.
    response.addHeader("cache-control", "no-store")
    response.send(status: .ok, page)
    return true
}

/// 301 to the same path with a `/` on the end, keeping the query.
private func redirectToSlash(_ x: UnsafeMutablePointer<Exchange>) {
    let path = x.pointee.slice(x.pointee.head.path)
    let query = x.pointee.slice(x.pointee.head.query)
    var target: [UInt8] = []
    target.reserveCapacity(path.count + query.count + 2)
    // Exactly one leading slash, whatever the request had. Under a route at
    // the root, "//example.com" walks to a local directory named example.com
    // -- the empty segment is skipped -- and copied into Location as it
    // arrived it stops being a path: "//example.com/" is a protocol-relative
    // URL, and the browser goes to that host. Backslashes go with them,
    // because a browser reads one as a separator.
    var i = 0
    while i < path.count, path.base[i] == UInt8(ascii: "/") || path.base[i] == UInt8(ascii: "\\") { i += 1 }
    target.append(UInt8(ascii: "/"))
    while i < path.count {
        target.append(path.base[i])
        i += 1
    }
    target.append(UInt8(ascii: "/"))
    if query.count > 0 {
        target.append(UInt8(ascii: "?"))
        for k in 0..<query.count { target.append(query.base[k]) }
    }
    target.withUnsafeBufferPointer { Response(x).addHeader("location", $0.span) }
    x.pointee.answer(301, nil, 0)
}

/// The page for one directory, or nil when it cannot be read.
///
/// At most `limit` entries looked at: past it the page says only that there
/// are more.
private func directoryPage(_ directory: String, path: [UInt8], limit: Int) async -> [UInt8]? {
    guard let entries = try? await FileSystem.contentsOfDirectory(directory) else { return nil }
    var directories: [String] = []
    var files: [(name: String, size: Int)] = []
    var examined = 0
    var more = false
    for entry in entries {
        // `.` and `..` are navigation rather than content, and a dotfile in a
        // served directory is not something to announce.
        if entry.name.hasPrefix(".") { continue }
        // Counted before the stat, whatever the entry turns out to be, since
        // the stat is the cost being bounded.
        if limit > 0 && examined >= limit {
            more = true
            break
        }
        examined += 1
        guard let metadata = try? await FileSystem.metadata(entry.path, followingSymbolicLinks: false) else {
            continue
        }
        if metadata.isDirectory {
            directories.append(entry.name)
        } else if metadata.isFile {
            files.append((entry.name, metadata.size))
        }
        // Anything else -- a symbolic link, a socket, a device -- is not
        // served by the file path either, so it is not listed.
    }
    directories.sort()
    files.sort { $0.name < $1.name }

    let here = String(decoding: path, as: UTF8.self)
    var out = ""
    out += "<!doctype html>\n<meta charset=\"utf-8\">\n"
    out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    out += "<title>" + htmlEscaped(here) + "</title>\n"
    out += "<style>body{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:48rem}"
        + "h1{font-size:1.1rem;font-weight:600}"
        + "ul{list-style:none;padding:0}li{padding:.15rem 0}"
        + "a{text-decoration:none}a:hover{text-decoration:underline}"
        + "span{color:#767676;float:right;font-variant-numeric:tabular-nums}</style>\n"
    out += "<h1>" + htmlEscaped(here) + "</h1>\n<ul>\n"
    // Not at the route's own root, where `../` would leave what is served.
    if path.count > 1 {
        out += "<li><a href=\"../\">../</a></li>\n"
    }
    for name in directories {
        out += "<li><a href=\"" + pathEscaped(name) + "/\">" + htmlEscaped(name) + "/</a></li>\n"
    }
    for file in files {
        out += "<li><a href=\"" + pathEscaped(file.name) + "\">" + htmlEscaped(file.name) + "</a>"
            + "<span>" + describeSize(file.size) + "</span></li>\n"
    }
    out += "</ul>\n"
    if more {
        out += "<p>More entries are not listed: the directory was read no further than \(limit) entries.</p>\n"
    }
    return Array(out.utf8)
}

/// `&`, `<`, `>` and `"` as entities, so a file name cannot become markup.
func htmlEscaped(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for c in text {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(c)
        }
    }
    return out
}

/// A name as one path segment of a URL: everything but the unreserved
/// characters percent-encoded, so `#`, `?` and `/` in a name stay in it.
func pathEscaped(_ name: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for b in name.utf8 {
        let unreserved = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
        if unreserved {
            out.append(b)
        } else {
            out.append(UInt8(ascii: "%"))
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0xF)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// A size a person reads: bytes up to a kilobyte, then one decimal place.
func describeSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["kB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1024
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let tenths = Int((value * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[unit])"
}
