//===----------------------------------------------------------------------===//
// Answering a request for a directory under --static-dir.
//
// Off unless asked for. A directory nobody serves falls through to the
// application, and taking that path away from it is a decision, not a default
// (StaticFiles.swift says the same about files). `--static-index` answers a
// directory with its `index.html`; `--static-listing` also answers one that
// has no index with a list of what is in it.
//
// Two different things, and they get their safety from different places:
//
//   * The index is an ordinary file, so it goes through `av_static_open` and
//     `sendFile` like any other: the same containment, the same symlink
//     rules, the same ETag, ranges and conditional requests.
//   * A listing has to open a directory, which `av_static_open` will not do --
//     it opens regular files and nothing else. So the walk is here, one
//     segment at a time from the route's root with `openat`, `O_DIRECTORY`
//     and `O_NOFOLLOW`, refusing `.` and `..`. There is no window between
//     deciding and opening for a name to be swapped, because each open *is*
//     the decision. A symlinked directory is not listed even when it points
//     inside the tree: knowing that needs the resolve `av_static_open` does,
//     and refusing is the half that cannot be wrong.
//
// A directory asked for without its trailing slash is a 301 to the slash, so
// that every link in the listing can be relative to it -- and so that a client
// resolves them against the directory rather than its parent.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CAvian
import AvianCore
import AvianHTTP

extension Worker {
    /// Answers a request for a directory, or returns false to leave the
    /// request to whatever comes after `--static-dir`.
    ///
    /// `decoded` is the percent-decoded request path and `prefixLength` how
    /// much of it the route's prefix took.
    mutating func serveDirectory(_ slot: Int,
                                 route: (prefix: UnsafePointer<CChar>, directory: UnsafePointer<CChar>),
                                 decoded: inout [UInt8], n: Int, prefixLength: Int) -> Bool {
        let relative = prefixLength..<n
        let endsInSlash = n > 0 && decoded[n - 1] == UInt8(ascii: "/")

        // An index file first, whichever flag is on: a page somebody wrote
        // beats a list of file names.
        var size: Int64 = 0
        var mtime: Int64 = 0
        var index = [UInt8](repeating: 0, count: n - prefixLength + 12)
        var k = 0
        for i in relative { index[k] = decoded[i]; k += 1 }
        if k == 0 || index[k - 1] != UInt8(ascii: "/") { index[k] = UInt8(ascii: "/"); k += 1 }
        for byte in "index.html".utf8 { index[k] = byte; k += 1 }
        index[k] = 0
        let indexFD: Int32 = index.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: k + 1) {
                av_static_open(route.directory, $0, &size, &mtime)
            }
        }
        if indexFD >= 0 {
            // Without the slash the links inside the page would resolve
            // against the parent, so the client is sent to the slash first.
            if !endsInSlash {
                _ = av_close(indexFD)
                redirectToSlash(slot)
                return true
            }
            var name = index
            sendFile(slot, fd: indexFD, size: Int(size), mtime: Int(mtime),
                     coding: ContentCoding.identity, nameLength: k, name: &name)
            return true
        }

        guard config.staticListing else { return false }
        let dir: Int32 = decoded.withUnsafeBufferPointer { buffer in
            openContainedDirectory(route.directory,
                                   UnsafeBufferPointer(rebasing: buffer[relative]))
        }
        guard dir >= 0 else { return false }
        if !endsInSlash {
            _ = av_close(dir)
            redirectToSlash(slot)
            return true
        }
        let page = directoryPage(dir, path: decoded, count: n)
        // fdopendir took the descriptor and closedir closed it, in
        // `directoryPage`.
        logAccess(slot, status: 200)
        dates.refresh()
        let type: StaticString = "text/html; charset=utf-8"
        let name: StaticString = "content-type"
        _ = addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                              ByteSpan(type.utf8Start, type.utf8CodeUnitCount))
        // A listing is what the directory holds right now, and it has no
        // validator to check that against.
        let control: StaticString = "cache-control"
        let noStore: StaticString = "no-store"
        _ = addResponseHeader(slot, ByteSpan(control.utf8Start, control.utf8CodeUnitCount),
                              ByteSpan(noStore.utf8Start, noStore.utf8CodeUnitCount))
        // A HEAD gets the same headers and no body: the one response path
        // frames that, as it does for a handler's answer.
        page.withUnsafeBufferPointer { buffer in
            respond(slot, status: 200, buffer.baseAddress, buffer.count)
        }
        return true
    }

    /// 301 to the same path with a `/` on the end, keeping the query.
    private mutating func redirectToSlash(_ slot: Int) {
        let c = table[slot]
        let base = c.pointee.headBase()
        let path = c.pointee.head.path
        let query = c.pointee.head.query
        var target = [UInt8]()
        target.reserveCapacity(Int(path.length) + Int(query.length) + 2)
        for i in 0..<Int(path.length) { target.append((base + Int(path.offset))[i]) }
        target.append(UInt8(ascii: "/"))
        if query.length > 0 {
            target.append(UInt8(ascii: "?"))
            for i in 0..<Int(query.length) { target.append((base + Int(query.offset))[i]) }
        }
        let name: StaticString = "location"
        target.withUnsafeBufferPointer { buffer in
            _ = addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                  ByteSpan(buffer.baseAddress!, buffer.count))
        }
        logAccess(slot, status: 301)
        dates.refresh()
        respond(slot, status: 301, nil, 0)
    }

    /// Opens the directory `path` names under `root`, or -1.
    ///
    /// One `openat` per segment from the root, never following a symlink and
    /// never accepting `.` or `..`, so the walk cannot leave the tree and
    /// nothing can be swapped between deciding and opening.
    private func openContainedDirectory(_ root: UnsafePointer<CChar>,
                                        _ path: UnsafeBufferPointer<UInt8>) -> Int32 {
        var dir = openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return -1 }
        var i = 0
        while i < path.count {
            while i < path.count, path[i] == UInt8(ascii: "/") { i += 1 }
            var end = i
            while end < path.count, path[end] != UInt8(ascii: "/") { end += 1 }
            if end == i { break }
            // `.` goes nowhere and `..` goes out: neither is walked.
            let length = end - i
            if path[i] == UInt8(ascii: ".") && (length == 1 || (length == 2 && path[i + 1] == UInt8(ascii: "."))) {
                _ = av_close(dir)
                return -1
            }
            var name = [CChar](repeating: 0, count: length + 1)
            for k in 0..<length { name[k] = Int8(bitPattern: path[i + k]) }
            let next = name.withUnsafeBufferPointer {
                openat(dir, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            _ = av_close(dir)
            guard next >= 0 else { return -1 }
            dir = next
            i = end
        }
        return dir
    }

    /// The page for one directory. Takes the descriptor, and closes it.
    private func directoryPage(_ dir: Int32, path: [UInt8], count: Int) -> [UInt8] {
        var directories: [String] = []
        var files: [(name: String, size: Int64)] = []
        if let handle = fdopendir(dir) {
            while let entry = readdir(handle) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                // `.` and `..` are navigation rather than content, and a
                // dotfile in a served directory is not something to announce.
                if name.hasPrefix(".") { continue }
                var st = stat()
                guard fstatat(dirfd(handle), name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    directories.append(name)
                } else if st.st_mode & S_IFMT == S_IFREG {
                    files.append((name, Int64(st.st_size)))
                }
                // Anything else -- a symlink, a socket, a device -- is not
                // served by the file path either, so it is not listed.
            }
            closedir(handle)
        } else {
            _ = av_close(dir)
        }
        directories.sort()
        files.sort { $0.name < $1.name }

        let here = String(decoding: path[0..<count], as: UTF8.self)
        var out = [UInt8]()
        out.reserveCapacity(512 + 64 * (directories.count + files.count))
        func add(_ text: String) { out.append(contentsOf: text.utf8) }
        add("<!doctype html>\n<meta charset=\"utf-8\">\n")
        add("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
        add("<title>" + htmlEscaped(here) + "</title>\n")
        add("<style>body{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:48rem}"
                + "h1{font-size:1.1rem;font-weight:600}"
                + "ul{list-style:none;padding:0}li{padding:.15rem 0}"
                + "a{text-decoration:none}a:hover{text-decoration:underline}"
                + "span{color:#767676;float:right;font-variant-numeric:tabular-nums}</style>\n")
        add("<h1>" + htmlEscaped(here) + "</h1>\n<ul>\n")
        // Not at the route's own root, where `../` would leave what is served.
        if count > 1 {
            add("<li><a href=\"../\">../</a></li>\n")
        }
        for name in directories {
            add("<li><a href=\"" + pathEscaped(name) + "/\">" + htmlEscaped(name) + "/</a></li>\n")
        }
        for file in files {
            add("<li><a href=\"" + pathEscaped(file.name) + "\">" + htmlEscaped(file.name) + "</a>"
                    + "<span>" + describeSize(file.size) + "</span></li>\n")
        }
        add("</ul>\n")
        return out
    }
}

/// `&`, `<`, `>` and `"` as entities, so a file name cannot become markup.
func htmlEscaped(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(character)
        }
    }
    return out
}

/// A file name as one path segment of a URL: everything but the unreserved
/// characters percent-encoded, so a name holding `?`, `#` or a space still
/// links to the file it names.
func pathEscaped(_ name: String) -> String {
    var out = ""
    for byte in name.utf8 {
        let unreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "~")
        if unreserved {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            let hex = Array("0123456789ABCDEF")
            out.append("%")
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
    }
    return out
}

/// A size a person reads: bytes up to a kilobyte, then one decimal place.
func describeSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["kB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1024
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let tenths = Int((value * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[unit])"
}
