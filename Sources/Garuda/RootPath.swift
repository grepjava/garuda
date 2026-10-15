//===----------------------------------------------------------------------===//
// --root-path: an application mounted under a prefix by a proxy that leaves
// the prefix on the path.
//
//     garuda --root-path /app        # /app/users reaches the /users route
//
// The prefix is taken off the request's path as soon as its head is read,
// before anything looks at it -- the body limit's route, the health check,
// static files, the routes, and the handler -- so everything sees the path
// within the mount, as it would with the proxy taking the prefix off itself.
// A path outside the mount is left as it came: that is what such a proxy
// sends.
//===----------------------------------------------------------------------===//

import GarudaWire

/// Takes `root` -- "/app", without a trailing slash -- off the front of the
/// request's path when the path is in the mount: "/app" itself, which is the
/// mount's "/", or anything under "/app/". "/apple" is not under "/app".
@inline(__always)
func stripRootPath(_ x: UnsafeMutablePointer<Exchange>, _ root: [UInt8]) {
    let path = x.pointee.head.path
    let n = root.count
    guard path.count >= n else { return }
    let base = x.pointee.base + Int(path.offset)
    let inMount = root.withUnsafeBufferPointer { r in
        var i = 0
        while i < n {
            if base[i] != r[i] { return false }
            i &+= 1
        }
        return true
    }
    guard inMount else { return }
    if path.count == n {
        // The mount itself: "/", which is the slash it starts with.
        x.pointee.head.path.length = 1
        return
    }
    guard base[n] == UInt8(ascii: "/") else { return }
    x.pointee.head.path.offset &+= UInt32(truncatingIfNeeded: n)
    x.pointee.head.path.length &-= UInt32(truncatingIfNeeded: n)
}
