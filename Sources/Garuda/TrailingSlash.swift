//===----------------------------------------------------------------------===//
// A path with a trailing slash no route has: `/users/` where the route is
// `/users`.
//
//     app.trailingSlash(.redirect)
//
// Routes match exactly, so by default `/users/` is a 404 when only `/users`
// is routed. `.redirect` answers such a request 308 with the path's trailing
// slashes taken off, keeping the query and, as 308 does, the method and body.
// `.ignore` serves it from the route as if the slashes were not there.
//
// Either only looks when no route matched the path as it came -- the
// connection's dispatch asks `pathWithoutTrailingSlash` on a miss, before its
// 404 or 405 -- so a route that is registered with the slash keeps its own
// requests and a request that matched pays nothing. A path the trimmed form
// would make start with `//` or `/\` is never redirected: a browser reads
// `Location: //host` as another site, and reads a backslash there as the
// second slash of one.
//===----------------------------------------------------------------------===//

import GarudaWire

/// What a request whose path ends in a slash no route has is answered with.
public enum TrailingSlash: Sendable {
    /// Routes match exactly: a 404 or a 405, as for any path.
    case strict
    /// 308 to the path without its trailing slashes, when a route has it.
    case redirect
    /// Served by the route for the path without its trailing slashes.
    case ignore
}

extension Application {
    /// Sets what a request whose path has a trailing slash no route has is
    /// answered with, for the whole application. `.strict` by default.
    public func trailingSlash(_ policy: TrailingSlash) {
        precondition(compiledApplication == nil, "trailingSlash set after the application was compiled")
        trailingSlashPolicy = policy
    }
}

/// For a path no route matched: its length without trailing slashes, when
/// it has some and a route, for any method, has the path without them.
func pathWithoutTrailingSlash(_ app: CompiledApplication, _ base: UnsafePointer<UInt8>, _ count: Int,
                              _ parameters: inout RouteParameters) -> Int? {
    guard count > 1, base[count &- 1] == 0x2F else { return nil }
    var trimmed = count
    while trimmed > 1 && base[trimmed &- 1] == 0x2F { trimmed &-= 1 }
    let routed = !app.table.allowedMethods(base, trimmed, into: &parameters).isEmpty
    parameters = RouteParameters()
    return routed ? trimmed : nil
}

/// Answers 308 to the request's path without its trailing slashes, with its
/// query. False, answering nothing, when that path would begin `//` or `/\`,
/// either of which names another host to a browser.
func redirectWithoutTrailingSlash(_ x: UnsafeMutablePointer<Exchange>) -> Bool {
    let path = x.pointee.slice(x.pointee.head.path)
    var trimmed = path.count
    while trimmed > 1 && path.base[trimmed &- 1] == 0x2F { trimmed &-= 1 }
    if trimmed >= 2 && (path.base[1] == 0x2F || path.base[1] == 0x5C) { return false }
    var location = Array(UnsafeBufferPointer(start: path.base, count: trimmed))
    let query = x.pointee.slice(x.pointee.head.query)
    if query.count > 0 {
        location.append(0x3F)
        location.append(contentsOf: UnsafeBufferPointer(start: query.base, count: query.count))
    }
    location.withUnsafeBufferPointer { _ = Response(x).addHeader("location", $0.span) }
    x.pointee.answer(308, nil, 0)
    return true
}
