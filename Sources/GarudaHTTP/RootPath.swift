//===----------------------------------------------------------------------===//
// --root-path: the prefix a proxy mounts the application under.
//
// It is reported to the application as SCRIPT_NAME and as the ASGI root_path,
// and it comes off the front of a request's path so that PATH_INFO and the
// ASGI path are the path within the application.
//
// Only a whole leading segment comes off. A request that does not start with
// the prefix keeps its path as it came -- which is every request behind a proxy
// that already removed the prefix, the usual way uvicorn's --root-path is
// deployed, and a health check that bypasses the mount. One that shares only
// the first letters of a segment, `/apis` under `/api`, is not under the mount.
//===----------------------------------------------------------------------===//

import GarudaCore

public struct RootPath {
    /// The prefix's bytes, from a C string that lives as long as the process.
    public let base: UnsafePointer<UInt8>
    /// Its length without any trailing `/`, so `/api/` mounts as `/api` does.
    public let count: Int

    public init(_ cString: UnsafePointer<CChar>) {
        let p = UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self)
        var n = 0
        while p[n] != 0 { n += 1 }
        while n > 0 && p[n - 1] == 0x2F { n -= 1 }
        base = p
        count = n
    }

    /// The part of `path` within the application: after the prefix when the
    /// path is the prefix or continues it with `/`, otherwise all of it.
    @inlinable
    public func strip(_ path: UnsafePointer<UInt8>, _ length: Int) -> (UnsafePointer<UInt8>, Int) {
        guard count > 0, length >= count else { return (path, length) }
        if length > count && path[count] != 0x2F { return (path, length) }
        var i = 0
        while i < count {
            if path[i] != base[i] { return (path, length) }
            i += 1
        }
        return (path + count, length - count)
    }
}
