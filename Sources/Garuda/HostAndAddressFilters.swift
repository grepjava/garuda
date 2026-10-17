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
// not the domain itself. The port is not compared. The Host is read where it
// arrived, byte by byte against the list, without copying it.
//
// `addressFilter` answers 403 to a client whose address is denied, or, when
// there is an allow list, not on it; deny is read first. The address is the
// one `request.remoteAddress` gives. Entries are addresses and CIDR blocks,
// `unix` for a unix-socket connection, and `*` for any. An IPv4 client that
// reached an IPv6 socket, `::ffff:a.b.c.d`, is matched as the IPv4 address it
// is.
//===----------------------------------------------------------------------===//

import GarudaWire

extension RouteBuilder {
    /// Answers 400 to a request in the current scope whose Host is none of
    /// `hosts`.
    public func allowedHosts(_ hosts: [String]) {
        precondition(!hosts.isEmpty, "allowedHosts needs at least one host")
        var exact: [[UInt8]] = []
        var suffixes: [[UInt8]] = []
        for host in hosts {
            let lowered = host.lowercased()
            precondition(!lowered.isEmpty && (!lowered.contains(":") || lowered.hasPrefix("[")),
                         "an allowed host has no port or scheme: \(host)")
            if lowered.hasPrefix("*.") {
                precondition(lowered.count > 2, "an allowed host pattern names a domain: \(host)")
                // ".example.com": a name under the domain ends with it.
                suffixes.append(Array(lowered.utf8.dropFirst(1)))
            } else if !exact.contains(Array(lowered.utf8)) {
                exact.append(Array(lowered.utf8))
            }
        }
        use(AllowedHostsMiddleware(exact: exact, suffixes: suffixes))
    }

    /// Answers 403 to a client in the current scope whose address is in
    /// `deny`, or is not in `allow` when that is not empty.
    public func addressFilter(allow: [String] = [], deny: [String] = []) {
        precondition(!allow.isEmpty || !deny.isEmpty, "addressFilter needs an allow or deny list")
        use(AddressFilterMiddleware(allowed: allow.isEmpty ? nil : AddressList(allow),
                                    denied: deny.isEmpty ? nil : AddressList(deny)))
    }
}

/// The middleware `allowedHosts` adds.
struct AllowedHostsMiddleware: Middleware {
    /// Lowercased.
    let exact: [[UInt8]]
    let suffixes: [[UInt8]]

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard let authority = request.headerBytes("host"), allows(authority) else {
            throw HTTPError(.badRequest, "a Host this server does not answer for")
        }
        try await next()
    }

    func allows(_ authority: ByteSpan) -> Bool {
        guard let count = hostLength(authority.base, authority.count) else { return false }
        let host = authority.base
        for entry in exact where entry.count == count {
            if entry.withUnsafeBufferPointer({ equalsLowered(host, $0.baseAddress!, count) }) { return true }
        }
        for suffix in suffixes where suffix.count < count {
            if suffix.withUnsafeBufferPointer({
                equalsLowered(host + (count - suffix.count), $0.baseAddress!, suffix.count)
            }) { return true }
        }
        return false
    }
}

/// Whether `n` bytes at `a`, lowercased, are the lowercase bytes at `b`.
private func equalsLowered(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    var i = 0
    while i < n {
        if asciiLower(a[i]) != b[i] { return false }
        i &+= 1
    }
    return true
}

/// How many bytes of `authority` are its host, before any port; nil when it
/// is not a host -- empty, or an IPv6 literal without its `]`.
func hostLength(_ authority: UnsafePointer<UInt8>, _ count: Int) -> Int? {
    if count > 0 && authority[0] == 0x5B {                         // [
        var close = 1
        while close < count && authority[close] != 0x5D { close &+= 1 }   // ]
        guard close < count else { return nil }
        guard close + 1 == count || authority[close + 1] == 0x3A else { return nil }
        return close + 1
    }
    var end = 0
    while end < count && authority[end] != 0x3A { end &+= 1 }
    return end == 0 ? nil : end
}

/// `authority` without its port, or nil when it is not a host.
func hostWithoutPort(_ authority: String) -> String? {
    var authority = authority
    return authority.withUTF8 { bytes in
        guard let base = bytes.baseAddress, let n = hostLength(base, bytes.count) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: base, count: n), as: UTF8.self)
    }
}

/// Addresses and CIDR blocks, as the forwarded-header trust list reads them.
struct AddressList: @unchecked Sendable {
    // Bools and an array of plain values, never changed once made: safe to
    // share, though GarudaWire does not say so.
    let list: ForwardedTrust

    init(_ entries: [String]) {
        var list = ForwardedTrust()
        for entry in entries {
            precondition(entry.withCString { list.parse($0) }, "not an address, CIDR block, unix or *: \(entry)")
        }
        self.list = list
    }

    func matches(_ address: String) -> Bool {
        var address = address
        return address.withUTF8 { list.trusts($0.baseAddress!, $0.count) }
    }
}

/// The middleware `addressFilter` adds.
struct AddressFilterMiddleware: Middleware {
    let allowed: AddressList?
    let denied: AddressList?

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        let address = clientAddressForMatching(request.remoteAddress)
        if let denied, denied.matches(address) {
            throw HTTPError(.forbidden, "this address may not use this resource")
        }
        if let allowed, !allowed.matches(address) {
            throw HTTPError(.forbidden, "this address may not use this resource")
        }
        try await next()
    }
}

/// The address as it should be matched: an IPv4-mapped IPv6 address as IPv4,
/// and a connection with no address as `unix`.
func clientAddressForMatching(_ address: String) -> String {
    if address.isEmpty { return "unix" }
    let lowered = address.lowercased()
    if lowered.hasPrefix("::ffff:") && lowered.contains(".") { return String(lowered.dropFirst(7)) }
    return address
}
