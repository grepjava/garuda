//===----------------------------------------------------------------------===//
// Applying a trusted proxy's forwarded headers to the request.
//
// The rule is the same for both interfaces: read the headers only if the
// immediate peer is on the trust list, and otherwise behave as though they were
// not there at all. Anything looser lets any client that can reach the server
// claim any address and any scheme -- which is how a `--scheme https` flag
// alone leaves an application unable to tell who its callers are.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

extension Worker {

    /// Whether the peer at the other end of this connection may be believed.
    /// Evaluated once and cached on the connection.
    mutating func peerIsTrusted(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.flags.contains(.trustEvaluated) {
            return c.pointee.flags.contains(.trustedPeer)
        }
        var trusted = false
        if let addr = c.pointee.remoteAddrObj {
            var n: pg_ssize_t = 0
            // The address was built from request bytes, so it is a compact
            // latin-1 string and this is a view rather than a copy.
            if let raw = pg_str_latin1_data(addr, &n) {
                trusted = config.trust.trusts(
                    UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), Int(n))
            } else {
                pg_err_clear()
            }
        }
        c.pointee.flags.insert(.trustEvaluated)
        if trusted { c.pointee.flags.insert(.trustedPeer) }
        return trusted
    }

    /// What the proxy said, or nothing at all when there is no proxy to trust.
    mutating func forwardedInfo(_ slot: Int, base: UnsafePointer<UInt8>) -> ForwardedInfo {
        if config.trust.isEmpty { return ForwardedInfo() }
        if !peerIsTrusted(slot) { return ForwardedInfo() }
        return Forwarded.read(base: base,
                              head: table[slot].pointee.head,
                              headers: headers,
                              trust: config.trust)
    }

    /// Overwrites REMOTE_ADDR and wsgi.url_scheme in a freshly built environ.
    func applyForwarded(_ info: ForwardedInfo, toEnviron env: PyObj) -> Bool {
        if info.isEmpty { return true }
        if let client = info.client {
            guard let obj = client.base.withMemoryRebound(
                    to: CChar.self, capacity: client.count,
                    { pg_str_latin1($0, pg_ssize_t(client.count)) }) else { return false }
            defer { pg_decref(obj) }
            if pg_dict_set(env, Interned[.remoteAddr], obj) != 0 { return false }
            // The proxy's ephemeral port says nothing about the client, and
            // leaving it in place is worse than reporting nothing.
            if pg_dict_set(env, Interned[.remotePort], Interned.emptyString) != 0 {
                return false
            }
        }
        if let https = info.https {
            let scheme = https ? Interned[.vHTTPS] : Interned[.vHTTP]
            if pg_dict_set(env, Interned[.wsgiURLScheme], scheme) != 0 { return false }
        }
        return true
    }

    /// The ASGI `client` tuple for a forwarded request. Owned reference, or nil
    /// when the proxy said nothing (in which case the connection's own cached
    /// tuple is correct).
    func forwardedClientTuple(_ info: ForwardedInfo) -> PyObj? {
        guard let client = info.client else { return nil }
        guard let host = client.base.withMemoryRebound(
                to: CChar.self, capacity: client.count,
                { pg_str_utf8($0, pg_ssize_t(client.count)) }) else { return nil }
        defer { pg_decref(host) }
        // The original client port is not forwarded by any common proxy, and
        // ASGI requires a two-item tuple, so it is reported as zero.
        guard let port = pg_int(0) else { return nil }
        defer { pg_decref(port) }
        return pg_tuple2(host, port)
    }
}
