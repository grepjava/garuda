//===----------------------------------------------------------------------===//
// Which hosts a request may name, and which addresses may send one.
//
//     app.allowedHosts(["example.com", "*.example.com"])
//
//     app.group("/admin") {
//         app.addressFilter(allow: ["10.0.0.0/8", "::1"])
//         app.get("/stats") { … }
//     }
//
// Both are middleware in the scope they are called in.
//
// `allowedHosts` answers 400 to a request whose Host -- HTTP/2's and HTTP/3's
// :authority -- is not on the list, or that has none. A page served under a
// name an attacker points at the server can otherwise build absolute links,
// password-reset mails and cache keys from that name. An entry is a host, an
// IP literal (`[::1]` for IPv6), or `*.` and a domain for the names under it,
// not the domain itself. The port is not compared.
//
// `addressFilter` answers 403 to a client whose address is denied, or, when
// there is an allow list, not on it; deny is read first. The address is the
// one `request.remoteAddress` gives: a trusted proxy's X-Forwarded-For or
// Forwarded when --forwarded-allow-ips names the peer, the peer's own otherwise.
// Entries are addresses and CIDR blocks, `unix` for a unix-socket connection,
// and `*` for any. An IPv4 client that reached an IPv6 socket, `::ffff:a.b.c.d`,
// is matched as the IPv4 address it is.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

extension RouteBuilder {
    /// Answers 400 to a request in the current scope whose Host is none of
    /// `hosts`.
    public func allowedHosts(_ hosts: [String]) {
        precondition(!hosts.isEmpty, "allowedHosts needs at least one host")
        var exact: Set<String> = []
        var suffixes: [String] = []
        for host in hosts {
            let lowered = host.lowercased()
            precondition(!lowered.isEmpty && (!lowered.contains(":") || lowered.hasPrefix("[")),
                         "an allowed host has no port or scheme: \(host)")
            if lowered.hasPrefix("*.") {
                precondition(lowered.count > 2, "an allowed host pattern names a domain: \(host)")
                suffixes.append(String(lowered.dropFirst(1)))
            } else {
                exact.insert(lowered)
            }
        }
        use { request, _ in
            guard let authority = request.authority, let host = hostWithoutPort(authority.lowercased()),
                  exact.contains(host) || suffixes.contains(where: { host.hasSuffix($0) }) else {
                throw HTTPError(.badRequest, "a Host this server does not answer for")
            }
            return nil
        }
    }

    /// Answers 403 to a client in the current scope whose address is in
    /// `deny`, or is not in `allow` when that is not empty.
    public func addressFilter(allow: [String] = [], deny: [String] = []) {
        precondition(!allow.isEmpty || !deny.isEmpty, "addressFilter needs an allow or deny list")
        let allowed = addressList(allow)
        let denied = addressList(deny)
        use { request, _ in
            let address = clientAddressForMatching(request.remoteAddress)
            if !deny.isEmpty && matchesAddress(denied, address)
                || !allow.isEmpty && !matchesAddress(allowed, address) {
                throw HTTPError(.forbidden, "this address may not use this resource")
            }
            return nil
        }
    }
}

/// `authority` without its port, or nil when it is not a host.
func hostWithoutPort(_ authority: String) -> String? {
    if authority.hasPrefix("[") {
        guard let close = authority.firstIndex(of: "]") else { return nil }
        let rest = authority[authority.index(after: close)...]
        guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
        return String(authority[...close])
    }
    let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
    return host.isEmpty ? nil : String(host)
}

private func addressList(_ entries: [String]) -> ForwardedTrust {
    var list = ForwardedTrust()
    for entry in entries {
        precondition(entry.withCString { list.parse($0) }, "not an address, CIDR block, unix or *: \(entry)")
    }
    return list
}

/// The address as it should be matched: an IPv4-mapped IPv6 address as IPv4,
/// and a connection with no address as `unix`.
func clientAddressForMatching(_ address: String) -> String {
    if address.isEmpty { return "unix" }
    let lowered = address.lowercased()
    if lowered.hasPrefix("::ffff:") && lowered.contains(".") { return String(lowered.dropFirst(7)) }
    return address
}

private func matchesAddress(_ list: ForwardedTrust, _ address: String) -> Bool {
    var address = address
    return address.withUTF8 { list.trusts($0.baseAddress!, $0.count) }
}
