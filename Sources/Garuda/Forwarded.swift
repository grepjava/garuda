//===----------------------------------------------------------------------===//
// The client and the scheme, as a trusted proxy reports them.
//
// Behind a proxy the socket's peer is the proxy, and the client's address and
// whether it used HTTPS arrive in X-Forwarded-For / X-Forwarded-Proto or RFC
// 7239 Forwarded. Those headers are read only when the peer is on the trust
// list (--forwarded-allow-ips), and otherwise treated as though they were not
// there at all: anything looser lets any client that can reach the server
// claim any address and any scheme.
//
// Nothing is read until a handler asks -- `remoteAddress`, `remotePort`, or
// whether the request arrived over HTTPS -- and then once per request. A
// server with no trust list never looks.
//===----------------------------------------------------------------------===//

import GarudaWire

/// What the forwarded headers said for the request in progress.
@usableFromInline
enum ForwardedState {
    /// Not looked at yet.
    case unknown
    /// No trusted proxy said anything.
    case none
    case said(client: String?, port: Int, https: Bool?)
}

extension Exchange {
    /// The forwarded client and scheme, read the first time they are asked
    /// for.
    @usableFromInline
    mutating func forwarded() -> ForwardedState {
        if case .unknown = forwardedState {
            forwardedState = readForwarded()
        }
        return forwardedState
    }

    private mutating func readForwarded() -> ForwardedState {
        guard let trust else { return .none }
        let peer = remote.address
        let trusted = peer.isEmpty ? false : {
            var peer = peer
            return peer.withUTF8 { trust.trusts($0.baseAddress!, $0.count) }
        }()
        guard trusted else { return .none }
        let info = Forwarded.read(base: base, head: head, headers: headers, trust: trust)
        if info.isEmpty { return .none }
        return .said(client: info.client.map(\.string), port: info.clientPort, https: info.https)
    }
}

extension Request {
    /// The client's address: the socket's peer, or the client a trusted
    /// proxy names.
    public var remoteAddress: String {
        if case .said(let client?, _, _) = exchange.pointee.forwarded() { return client }
        return exchange.pointee.remote.address
    }

    /// The client's port: the socket's peer's, or what a trusted proxy names
    /// with the client (0 when it names none).
    public var remotePort: Int {
        if case .said(_?, let port, _) = exchange.pointee.forwarded() { return port }
        return exchange.pointee.remote.port
    }

    /// Whether the request came over HTTPS: on this connection's own TLS, or
    /// through a trusted proxy that says so. What Strict-Transport-Security
    /// and a cookie's default `Secure` follow.
    public var arrivedOverHTTPS: Bool {
        if exchange.pointee.secure { return true }
        if case .said(_, _, let https?) = exchange.pointee.forwarded() { return https }
        return false
    }
}
