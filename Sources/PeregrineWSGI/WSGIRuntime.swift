//===----------------------------------------------------------------------===//
// WSGI environ construction and application invocation.
//
// Three things make this fast:
//
//  1. A prototype environ dict holding every constant entry is built once at
//     start-up and shallow-copied per request. PyDict_Copy on a small dict is a
//     table memcpy; the alternative is ~10 hashed insertions per request.
//  2. Environ keys are interned, so insertion compares a cached hash instead of
//     hashing the key bytes again.
//  3. HTTP_* keys are memoised by raw header-name bytes, so "User-Agent" is
//     turned into "HTTP_USER_AGENT" once per process rather than once per
//     request.
//
// Everything else is byte copying straight from the read buffer into freshly
// created Python strings -- no intermediate Swift String is ever built.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

/// Deliberately a plain (copyable) struct with an explicit `destroy()` rather
/// than a `~Copyable` type with a `deinit`: Swift does not permit a failable
/// initialiser on a noncopyable type that has a deinit, and the runtime is a
/// per-worker singleton whose teardown point is unambiguous.
public struct WSGIRuntime {
    /// The application callable. Borrowed for the life of the process.
    public let app: PyObj

    @usableFromInline var prototype: PyObj
    @usableFromInline var headerKeys: PyStringCache
    @usableFromInline var protocol11: PyObj
    @usableFromInline var protocol10: PyObj
    @usableFromInline var protocol2: PyObj
    @usableFromInline var protocol3: PyObj
    @usableFromInline var scratch: UnsafeMutablePointer<UInt8>
    @usableFromInline let scratchCapacity: Int
    /// Interned SCRIPT_NAME prefix length, so PATH_INFO can be trimmed.
    @usableFromInline let rootPathLength: Int

    public init?(app: PyObj,
                 serverName: UnsafePointer<CChar>,
                 serverPort: UnsafePointer<CChar>,
                 scheme: UnsafePointer<CChar>,
                 rootPath: UnsafePointer<CChar>,
                 multiprocess: Bool,
                 multithread: Bool,
                 scratchCapacity: Int = 1 << 16) {
        self.app = app
        self.scratchCapacity = scratchCapacity
        self.scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchCapacity)
        self.headerKeys = PyStringCache(capacityLog2: 9)

        guard let proto = pg_dict_new() else { return nil }
        self.prototype = proto

        guard let p11 = pg_str_intern("HTTP/1.1"),
              let p10 = pg_str_intern("HTTP/1.0"),
              let p2 = pg_str_intern("HTTP/2"),
              let p3 = pg_str_intern("HTTP/3") else { return nil }
        self.protocol11 = p11
        self.protocol10 = p10
        self.protocol2 = p2
        self.protocol3 = p3

        var rootLen = 0
        while rootPath[rootLen] != 0 { rootLen += 1 }
        self.rootPathLength = rootLen

        // --- constant environ entries ---
        func setStr(_ key: PyKey, _ cstr: UnsafePointer<CChar>) -> Bool {
            guard let v = pg_str_intern(cstr) else { return false }
            defer { pg_decref(v) }
            return pg_dict_set(proto, Interned[key], v) == 0
        }
        func setObj(_ key: PyKey, _ value: PyObj) -> Bool {
            pg_dict_set(proto, Interned[key], value) == 0
        }

        guard setStr(.scriptName, rootPath),
              setStr(.serverName, serverName),
              setStr(.serverPort, serverPort),
              setStr(.wsgiURLScheme, scheme),
              setObj(.wsgiVersion, Interned.wsgiVersionTuple),
              setObj(.wsgiErrors, Interpreter.sysStderr),
              setObj(.wsgiMultithread, multithread ? Interned.pyTrue : Interned.pyFalse),
              setObj(.wsgiMultiprocess, multiprocess ? Interned.pyTrue : Interned.pyFalse),
              setObj(.wsgiRunOnce, Interned.pyFalse)
        else {
            PyError.logPending("building the WSGI environ prototype")
            return nil
        }

        // wsgi.file_wrapper, if the glue module exposes one.
        if let fw = pg_getattr(Interpreter.glue, "FileWrapper") {
            _ = pg_dict_set(proto, Interned[.wsgiFileWrapper], fw)
            pg_decref(fw)
        } else {
            pg_err_clear()
        }
    }

    public func destroy() {
        scratch.deallocate()
        pg_decref(prototype)
        pg_decref(protocol11)
        pg_decref(protocol10)
        pg_decref(protocol2)
        pg_decref(protocol3)
        headerKeys.destroy()
    }

    // MARK: - environ

    /// Builds the environ dict for one request. Returns an owned reference.
    ///
    /// `remoteAddr` and `remotePort` are borrowed, pre-built strings owned by
    /// the connection, so a keep-alive connection pays for them once.
    public mutating func buildEnviron(
        base: UnsafePointer<UInt8>,
        head: borrowing HTTPRequestHead,
        headers: UnsafePointer<HTTPHeaderRef>,
        body: PyObj,
        remoteAddr: PyObj?,
        remotePort: PyObj?
    ) -> PyObj? {
        guard let env = pg_dict_copy(prototype) else { return nil }

        @inline(__always)
        func put(_ key: PyObj, _ value: PyObj?) -> Bool {
            guard let value else { return false }
            defer { pg_decref(value) }
            return pg_dict_set(env, key, value) == 0
        }

        // REQUEST_METHOD -- interned for the nine standard verbs.
        let methodCode = HTTPMethodCode(rawMethodIndex: head.method.rawValue)
        if let interned = Interned.methodName(methodCode) {
            if pg_dict_set(env, Interned[.requestMethod], interned) != 0 {
                pg_decref(env); return nil
            }
        } else {
            let m = head.methodSlice
            guard put(Interned[.requestMethod],
                      latin1(base + Int(m.offset), Int(m.length))) else {
                pg_decref(env); return nil
            }
        }

        // PATH_INFO -- percent-decoded, then latin-1 as PEP 3333 requires.
        var pathPtr = base + Int(head.path.offset)
        var pathLen = Int(head.path.length)
        if rootPathLength > 0 && pathLen >= rootPathLength {
            pathPtr += rootPathLength
            pathLen -= rootPathLength
        }
        if head.flags.contains(.escapedPath) && pathLen <= scratchCapacity {
            let decoded = percentDecode(pathPtr, pathLen, into: scratch)
            guard put(Interned[.pathInfo], latin1(scratch, decoded)) else {
                pg_decref(env); return nil
            }
        } else {
            guard put(Interned[.pathInfo], latin1(pathPtr, pathLen)) else {
                pg_decref(env); return nil
            }
        }

        // QUERY_STRING
        if head.query.length == 0 {
            if pg_dict_set(env, Interned[.queryString], Interned.emptyString) != 0 {
                pg_decref(env); return nil
            }
        } else {
            guard put(Interned[.queryString],
                      latin1(base + Int(head.query.offset), Int(head.query.length))) else {
                pg_decref(env); return nil
            }
        }

        // SERVER_PROTOCOL. An application can see which version carried it,
        // the same way an ASGI one reads scope["http_version"].
        let proto: PyObj
        switch head.httpMajor {
        case 2: proto = protocol2
        case 3: proto = protocol3
        default: proto = head.httpMinor == 1 ? protocol11 : protocol10
        }
        if pg_dict_set(env, Interned[.serverProtocol], proto) != 0 {
            pg_decref(env); return nil
        }

        if let remoteAddr, pg_dict_set(env, Interned[.remoteAddr], remoteAddr) != 0 {
            pg_decref(env); return nil
        }
        if let remotePort, pg_dict_set(env, Interned[.remotePort], remotePort) != 0 {
            pg_decref(env); return nil
        }

        // wsgi.input
        guard let stream = WSGIInputStream.make(body: body) else {
            pg_decref(env); return nil
        }
        if pg_dict_set(env, Interned[.wsgiInput], stream) != 0 {
            pg_decref(stream); pg_decref(env); return nil
        }
        pg_decref(stream)
        // Tells frameworks the body is fully framed and safe to read to EOF.
        if pg_dict_set(env, Interned[.wsgiInputTerminated], Interned.pyTrue) != 0 {
            pg_decref(env); return nil
        }

        // ---- request headers ----
        // Hoisted so the memoisation closure captures plain locals rather than
        // `self`, which a mutating method on a noncopyable type cannot do.
        let scratchPtr = scratch
        let scratchCap = scratchCapacity
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i += 1
            let np = base + Int(h.name.offset)
            let nLen = Int(h.name.length)
            let vp = base + Int(h.value.offset)
            let vLen = Int(h.value.length)

            var key: PyObj?
            var keyOwned = false

            if nLen == 12 && equalsLowercased(np, 12, "content-type") {
                key = Interned[.contentType]
            } else if nLen == 14 && equalsLowercased(np, 14, "content-length") {
                key = Interned[.contentLength]
            } else {
                // Underscores in a header name would collide with the dash-to-
                // underscore mapping and let a client forge, say, X_REAL_IP as
                // X-Real-IP. Drop them, as production servers do.
                if findByte(np, nLen, cUnderscore) >= 0 { continue }
                // httpoxy: a `Proxy:` request header must never become the
                // HTTP_PROXY that libraries read as an outbound proxy setting.
                if nLen == 5 && equalsLowercased(np, 5, "proxy") { continue }

                let hash = PyStringCache.hash(np, nLen)
                let result = headerKeys.lookup(np, nLen, hash: hash) { p, n in
                    makeEnvironKey(p, n, scratchPtr, scratchCap)
                }
                key = result.object
                keyOwned = result.owned
            }
            guard let key else { continue }

            let value = latin1(vp, vLen)
            guard let value else {
                if keyOwned { pg_decref(key) }
                pg_decref(env)
                return nil
            }

            // A repeated header folds into one comma-separated value.
            if let existing = pg_dict_get(env, key) {
                if let joined = pg_str_join_comma(existing, value) {
                    _ = pg_dict_set(env, key, joined)
                    pg_decref(joined)
                } else {
                    pg_err_clear()
                }
            } else {
                _ = pg_dict_set(env, key, value)
            }
            pg_decref(value)
            if keyOwned { pg_decref(key) }
        }

        return env
    }

    @inline(__always)
    private func latin1(_ p: UnsafePointer<UInt8>, _ n: Int) -> PyObj? {
        p.withMemoryRebound(to: CChar.self, capacity: n) { cp in
            pg_str_latin1(cp, pg_ssize_t(n))
        }
    }

    // MARK: - invocation

    /// Calls the application. Returns an owned reference to whatever it
    /// returned, or nil with a Python exception pending.
    @inlinable
    public func call(environ: PyObj, startResponse: PyObj) -> PyObj? {
        pg_call2(app, environ, startResponse)
    }
}

/// Turns `User-Agent` into an interned `HTTP_USER_AGENT`.
private func makeEnvironKey(_ p: UnsafePointer<UInt8>, _ n: Int,
                            _ scratch: UnsafeMutablePointer<UInt8>,
                            _ capacity: Int) -> PyObj? {
    if n + 6 > capacity { return nil }
    scratch[0] = 72   // H
    scratch[1] = 84   // T
    scratch[2] = 84   // T
    scratch[3] = 80   // P
    scratch[4] = 95   // _
    var i = 0
    while i < n {
        let c = p[i]
        scratch[5 + i] = (c == cDash) ? cUnderscore : asciiUpper(c)
        i += 1
    }
    scratch[5 + n] = 0
    return scratch.withMemoryRebound(to: CChar.self, capacity: n + 6) { cp in
        pg_str_intern(cp)
    }
}

/// Parses the numeric part of a WSGI status line such as `"404 Not Found"`.
/// Returns 0 if the string is not a plausible status.
public func wsgiStatusCode(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
    guard n >= 3 else { return 0 }
    let v = parseDecimal(p, 3)
    guard v >= 100 && v <= 599 else { return 0 }
    if n > 3 && p[3] != cSP { return 0 }
    return v
}
