//===----------------------------------------------------------------------===//
// Applying a trusted proxy's forwarded headers to the request.
//
// The rule is the same for both interfaces: read the headers only if the
// immediate peer is on the trust list, and otherwise behave as though they were
// not there at all. Anything looser lets any client that can reach the server
// claim any address and any scheme -- which is how a `--scheme https` flag
// alone leaves an application unable to tell who its callers are.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

extension Worker {

    /// Whether the peer at the other end of this connection may be believed.
    /// Evaluated once and cached on the connection.
    mutating func peerIsTrusted(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.flags.contains(.trustEvaluated) {
            return c.pointee.flags.contains(.trustedPeer)
        }
        let n = c.pointee.remoteAddr.readableBytes
        let trusted = n > 0 && config.trust.trusts(
            UnsafePointer(c.pointee.remoteAddr.readPointer), n)
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

}
