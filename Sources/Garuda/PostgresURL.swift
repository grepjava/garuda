//===----------------------------------------------------------------------===//
// A PostgreSQL configuration from a connection URL, which is how a deployment
// usually hands one over:
//
//     DATABASE_URL=postgres://app:secret@db.internal:5432/shop?sslmode=require
//
//     let configuration = try PostgresConfiguration(url: databaseURL)
//     app.state { _ in PostgresPool(configuration) }
//
// The form libpq accepts: `postgres://` or `postgresql://`, an optional
// `user:password@`, a host with an optional `:port`, an optional `/database`,
// and parameters after `?`. User, password and database are percent-decoded,
// so a password with an `@` or a `/` in it survives.
//
// Understood parameters: `sslmode`, `sslrootcert` (a trust store) and
// `connect_timeout` (seconds). Others -- `application_name`, a pooler's own --
// are ignored rather than refused, because a platform's URL often carries them.
//
// `sslmode=prefer` and `sslmode=allow` are refused rather than taken as
// either: they try TLS and fall back to plaintext when the server declines,
// which lets anyone on the path decline for it. Say `require` or `disable` and
// mean it.
//===----------------------------------------------------------------------===//

/// Why a connection URL could not be read.
public enum PostgresURLError: Error, Equatable, Sendable {
    /// Not `postgres://` or `postgresql://`.
    case scheme(String)
    case noHost
    case port(String)
    /// `prefer` and `allow` are refused; the rest are libpq's.
    case sslMode(String)
}

extension PostgresConfiguration {
    /// Reads a `postgres://` URL. The user defaults to `postgres`, the port to
    /// 5432, and TLS to `.require` as it does elsewhere.
    public init(url: String) throws(PostgresURLError) {
        var rest = Substring(url)
        guard let colon = rest.firstIndex(of: ":"), rest[colon...].hasPrefix("://") else { throw .scheme(url) }
        let scheme = rest[rest.startIndex..<colon].lowercased()
        guard scheme == "postgres" || scheme == "postgresql" else { throw .scheme(scheme) }
        rest = rest[rest.index(colon, offsetBy: 3)...]

        // Parameters first, so a `/` or `@` inside one is not read as part of
        // the host or the database.
        var parameters: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: mark)...].split(separator: "&") where !pair.isEmpty {
                let halves = pair.split(separator: "=", maxSplits: 1)
                parameters[percentDecoded(String(halves[0])).lowercased()] =
                    halves.count > 1 ? percentDecoded(String(halves[1])) : ""
            }
            rest = rest[rest.startIndex..<mark]
        }

        // The credentials end at the last `@`: a password may hold one.
        var credentials = Substring("")
        if let at = rest.lastIndex(of: "@") {
            credentials = rest[rest.startIndex..<at]
            rest = rest[rest.index(after: at)...]
        }

        var database: String? = nil
        if let slash = rest.firstIndex(of: "/") {
            let name = percentDecoded(String(rest[rest.index(after: slash)...]))
            database = name.isEmpty ? nil : name
            rest = rest[rest.startIndex..<slash]
        }

        // A host and a port, with IPv6 in brackets as a URL writes it.
        var host = String(rest)
        var port: UInt16 = 5432
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw .noHost }
            let address = String(host[host.index(after: host.startIndex)..<close])
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") {
                guard let read = UInt16(after.dropFirst()) else { throw .port(String(after.dropFirst())) }
                port = read
            }
            host = address
        } else if let colon = host.lastIndex(of: ":") {
            let text = String(host[host.index(after: colon)...])
            guard let read = UInt16(text) else { throw .port(text) }
            port = read
            host = String(host[host.startIndex..<colon])
        }
        host = percentDecoded(host)
        guard !host.isEmpty else { throw .noHost }

        var user = "postgres"
        var password = ""
        if !credentials.isEmpty {
            let halves = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = percentDecoded(String(halves[0]))
            if !name.isEmpty { user = name }
            if halves.count > 1 { password = percentDecoded(String(halves[1])) }
        }

        self.init(host: host, port: port, user: user, password: password, database: database)

        switch parameters["sslmode"] {
        case nil, "require", "verify-ca", "verify-full":
            tls = .require
        case "disable":
            tls = .disable
        case let mode?:
            throw .sslMode(mode)
        }
        if let store = parameters["sslrootcert"], !store.isEmpty { caFile = store }
        if let seconds = parameters["connect_timeout"], let value = UInt64(seconds), value > 0 {
            timeoutMilliseconds = value * 1000
        }
    }
}
