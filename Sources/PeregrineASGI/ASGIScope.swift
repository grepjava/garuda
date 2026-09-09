//===----------------------------------------------------------------------===//
// ASGI scope and message construction.
//
// Same strategy as the WSGI environ: a prototype dict holding every constant
// key is built once and shallow-copied per request, all keys are interned, and
// lowercased header-name `bytes` objects are memoised so that "user-agent" is
// created once per process instead of once per request.
//
// The header list is the one place ASGI is more expensive than WSGI -- it is a
// list of (bytes, bytes) pairs, so a request with fifteen headers costs a list,
// fifteen tuples and thirty bytes objects. Half of those (the names) come from
// the cache, which is why the cache is worth having.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

public struct ASGIScopeBuilder {
    @usableFromInline var prototype: PyObj
    @usableFromInline var headerNames: PyStringCache
    @usableFromInline var scratch: UnsafeMutablePointer<UInt8>
    @usableFromInline let scratchCapacity: Int
    @usableFromInline let rootPathLength: Int
    /// Shared lifespan state, shallow-copied into each request scope.
    @usableFromInline var lifespanState: PyObj?
    /// `{"webtransport": {}}` as a mappingproxy, interned for the worker.
    @usableFromInline var webtransportExtensions: PyObj?

    public init?(scheme: UnsafePointer<CChar>,
                 rootPath: UnsafePointer<CChar>,
                 serverHost: UnsafePointer<CChar>,
                 serverPort: Int,
                 lifespanState: PyObj?,
                 scratchCapacity: Int = 1 << 16) {
        self.scratchCapacity = scratchCapacity
        self.scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchCapacity)
        self.headerNames = PyStringCache(capacityLog2: 9)
        self.lifespanState = lifespanState
        self.webtransportExtensions = nil

        var rootLen = 0
        while rootPath[rootLen] != 0 { rootLen += 1 }
        self.rootPathLength = rootLen

        guard let proto = pg_dict_new() else { return nil }
        self.prototype = proto

        // scope["asgi"] = {"version": "3.0", "spec_version": "2.3"}
        // A mappingproxy so a write cannot leak into every later request:
        // the prototype is shallow-copied, and this value is shared.
        guard let asgiDict = pg_dict_new() else { return nil }
        defer { pg_decref(asgiDict) }
        guard pg_dict_set(asgiDict, Interned[.version], Interned[.v30]) == 0,
              pg_dict_set(asgiDict, Interned[.specVersion], Interned[.v23]) == 0,
              let asgiProxy = pg_mapping_proxy(asgiDict) else { return nil }
        defer { pg_decref(asgiProxy) }
        guard pg_dict_set(proto, Interned[.type], Interned[.vHTTP]) == 0,
              pg_dict_set(proto, Interned[.asgi], asgiProxy) == 0
        else { return nil }

        guard let schemeObj = pg_str_intern(scheme),
              let rootObj = pg_str_intern(rootPath) else { return nil }
        defer {
            pg_decref(schemeObj)
            pg_decref(rootObj)
        }
        guard pg_dict_set(proto, Interned[.scheme], schemeObj) == 0,
              pg_dict_set(proto, Interned[.rootPath], rootObj) == 0
        else { return nil }

        // scope["server"] = (host, port)
        if let hostObj = pg_str_intern(serverHost), let portObj = pg_int(serverPort) {
            if let tuple = pg_tuple2(hostObj, portObj) {
                _ = pg_dict_set(proto, Interned[.server], tuple)
                pg_decref(tuple)
            }
            pg_decref(hostObj)
            pg_decref(portObj)
        } else {
            pg_err_clear()
        }

        // Shared across every HTTP/3 / WebTransport scope. Both dicts are
        // wrapped so `scope["extensions"]["webtransport"]["x"] = 1` cannot
        // mutate the interned object every later request would see.
        guard let extensions = pg_dict_new(), let empty = pg_dict_new() else { return nil }
        defer {
            pg_decref(empty)
            pg_decref(extensions)
        }
        guard let emptyProxy = pg_mapping_proxy(empty) else { return nil }
        defer { pg_decref(emptyProxy) }
        guard pg_dict_set(extensions, Interned[.vWebTransport], emptyProxy) == 0,
              let extProxy = pg_mapping_proxy(extensions) else { return nil }
        self.webtransportExtensions = extProxy
    }

    public func destroy() {
        scratch.deallocate()
        pg_decref(prototype)
        headerNames.destroy()
        if let s = lifespanState { pg_decref(s) }
        if let e = webtransportExtensions { pg_decref(e) }
    }

    /// Builds the scope for one request. Returns an owned reference.
    /// `schemeOverride` replaces the configured scheme for this request only,
    /// which is how a trusted proxy's X-Forwarded-Proto reaches the
    /// application without the server having to be told a fixed scheme.
    public mutating func build(base: UnsafePointer<UInt8>,
                               head: borrowing HTTPRequestHead,
                               headers: UnsafePointer<HTTPHeaderRef>,
                               client: PyObj?,
                               schemeOverride: PyObj? = nil,
                               websocket: Bool = false,
                               webtransport: Bool = false,
                               subprotocols: PyObj? = nil) -> PyObj? {
        guard let scope = pg_dict_copy(prototype) else { return nil }

        if let schemeOverride, pg_dict_set(scope, Interned[.scheme], schemeOverride) != 0 {
            pg_decref(scope); return nil
        }
        if webtransport {
            // ASGI has no standard WebTransport scope. Like a websocket it has
            // no method: the CONNECT that carried it is the transport, not the
            // request the application is answering. The extension itself is
            // advertised below, after `http_version` is known.
            if pg_dict_set(scope, Interned[.type], Interned[.vWebTransport]) != 0 {
                pg_decref(scope); return nil
            }
        }
        if websocket {
            // A websocket scope has no method, and carries the subprotocols the
            // client offered so the application can pick one.
            if pg_dict_set(scope, Interned[.type], Interned[.vWebsocket]) != 0 {
                pg_decref(scope); return nil
            }
            if let subprotocols,
               pg_dict_set(scope, Interned[.subprotocols], subprotocols) != 0 {
                pg_decref(scope); return nil
            }
        }

        @inline(__always)
        func put(_ key: PyObj, _ value: PyObj?) -> Bool {
            guard let value else { return false }
            defer { pg_decref(value) }
            return pg_dict_set(scope, key, value) == 0
        }

        // http_version
        let httpVersion: PyObj
        var http3 = false
        switch head.httpMajor {
        case 2: httpVersion = Interned[.v2]
        case 3:
            httpVersion = Interned[.v3]
            http3 = true
        default: httpVersion = head.httpMinor == 1 ? Interned[.v11] : Interned[.v10]
        }
        if pg_dict_set(scope, Interned[.httpVersion], httpVersion) != 0 {
            pg_decref(scope); return nil
        }

        // Advertise on the session itself, and on ordinary HTTP/3 requests so
        // an application can feature-detect without waiting for a CONNECT.
        // HTTP/1.1 and HTTP/2 never carry WebTransport.
        if webtransport || http3 {
            if let ext = webtransportExtensions,
               pg_dict_set(scope, Interned[.extensions], ext) != 0 {
                pg_decref(scope); return nil
            }
        }

        // method
        if !websocket && !webtransport {
            let methodCode = HTTPMethodCode(rawMethodIndex: head.method.rawValue)
            if let interned = Interned.methodName(methodCode) {
                if pg_dict_set(scope, Interned[.method], interned) != 0 {
                    pg_decref(scope); return nil
                }
            } else {
                let m = head.methodSlice
                guard put(Interned[.method], utf8(base + Int(m.offset), Int(m.length))) else {
                    pg_decref(scope); return nil
                }
            }
        }

        // raw_path is the target bytes exactly as received; path is decoded.
        var pathPtr = base + Int(head.path.offset)
        var pathLen = Int(head.path.length)
        guard put(Interned[.rawPath], bytes(pathPtr, pathLen)) else {
            pg_decref(scope); return nil
        }
        if rootPathLength > 0 && pathLen >= rootPathLength {
            pathPtr += rootPathLength
            pathLen -= rootPathLength
        }
        if head.flags.contains(.escapedPath) && pathLen <= scratchCapacity {
            let decoded = percentDecode(pathPtr, pathLen, into: scratch)
            guard put(Interned[.path], utf8(scratch, decoded)) else {
                pg_decref(scope); return nil
            }
        } else {
            guard put(Interned[.path], utf8(pathPtr, pathLen)) else {
                pg_decref(scope); return nil
            }
        }

        // query_string is bytes, without the leading '?'.
        if head.query.length == 0 {
            if pg_dict_set(scope, Interned[.queryStringBytes], Interned.emptyBytes) != 0 {
                pg_decref(scope); return nil
            }
        } else {
            guard put(Interned[.queryStringBytes],
                      bytes(base + Int(head.query.offset), Int(head.query.length))) else {
                pg_decref(scope); return nil
            }
        }

        if let client, pg_dict_set(scope, Interned[.client], client) != 0 {
            pg_decref(scope); return nil
        }

        // headers: [(lowercased-name, value), ...], in wire order, duplicates
        // preserved -- ASGI applications are required to handle repeats.
        guard let list = pg_list_new(pg_ssize_t(head.headerCount)) else {
            pg_decref(scope); return nil
        }
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            let np = base + Int(h.name.offset)
            let nLen = Int(h.name.length)
            let vp = base + Int(h.value.offset)
            let vLen = Int(h.value.length)

            let hash = PyStringCache.hash(np, nLen)
            let scratchPtr = scratch
            let scratchCap = scratchCapacity
            let cached = headerNames.lookup(np, nLen, hash: hash) { p, n in
                lowercasedBytes(p, n, scratchPtr, scratchCap)
            }
            guard let nameObj = cached.object, let valueObj = bytes(vp, vLen) else {
                if cached.owned, let o = cached.object { pg_decref(o) }
                pg_decref(list)
                pg_decref(scope)
                return nil
            }
            let pair = pg_tuple2(nameObj, valueObj)
            pg_decref(valueObj)
            if cached.owned { pg_decref(nameObj) }
            guard let pair else {
                pg_decref(list)
                pg_decref(scope)
                return nil
            }
            pg_list_set(list, pg_ssize_t(i), pair)   // steals
            i += 1
        }
        if pg_dict_set(scope, Interned[.headers], list) != 0 {
            pg_decref(list); pg_decref(scope); return nil
        }
        pg_decref(list)

        // scope["state"]: a shallow copy of the lifespan state namespace.
        if let shared = lifespanState, let copy = pg_dict_copy(shared) {
            _ = pg_dict_set(scope, Interned[.state], copy)
            pg_decref(copy)
        }

        return scope
    }

    @inline(__always)
    func bytes(_ p: UnsafePointer<UInt8>, _ n: Int) -> PyObj? {
        p.withMemoryRebound(to: CChar.self, capacity: n) { cp in
            pg_bytes(cp, pg_ssize_t(n))
        }
    }

    @inline(__always)
    func utf8(_ p: UnsafePointer<UInt8>, _ n: Int) -> PyObj? {
        p.withMemoryRebound(to: CChar.self, capacity: n) { cp in
            pg_str_utf8(cp, pg_ssize_t(n))
        }
    }
}

private func lowercasedBytes(_ p: UnsafePointer<UInt8>, _ n: Int,
                             _ scratch: UnsafeMutablePointer<UInt8>,
                             _ capacity: Int) -> PyObj? {
    if n > capacity { return nil }
    var i = 0
    while i < n {
        scratch[i] = asciiLower(p[i])
        i += 1
    }
    return scratch.withMemoryRebound(to: CChar.self, capacity: n) { cp in
        pg_bytes(cp, pg_ssize_t(n))
    }
}

// MARK: - Messages

public enum ASGIMessage {
    /// `{"type": "http.request", "body": ..., "more_body": ...}`
    public static func httpRequest(body: PyObj, moreBody: Bool) -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        if pg_dict_set(d, Interned[.type], Interned[.vHTTPRequest]) != 0
            || pg_dict_set(d, Interned[.body], body) != 0
            || pg_dict_set(d, Interned[.moreBody], moreBody ? Interned.pyTrue : Interned.pyFalse) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "http.disconnect"}`
    public static func httpDisconnect() -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        if pg_dict_set(d, Interned[.type], Interned[.vHTTPDisconnect]) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }
}
