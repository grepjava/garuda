//===----------------------------------------------------------------------===//
// Cross-site request forgery protection, from what the browser says about
// where a request came from.
//
//     app.group("/account") {
//         app.csrfProtection(trustedOrigins: ["https://admin.example.com"])
//         app.sessions { request in RedisSessionStore(try request.state(RedisPool.self)) }
//         app.post("/email") { … }
//     }
//
// A forged request is one another site's page makes the browser send, with
// the user's cookies. Browsers say which site started a request: every one
// since 2023 sends Sec-Fetch-Site, and older ones send Origin on a POST. So
// a request that changes something -- any method but GET, HEAD and OPTIONS --
// is refused 403 when:
//
// - Sec-Fetch-Site is `cross-site` or `same-site`; `same-origin` and `none`,
//   an address typed or a bookmark, pass.
// - Without Sec-Fetch-Site, Origin names a host other than the request's
//   Host (HTTP/2's and HTTP/3's :authority), or is `null`.
//
// A request with neither header did not come from a browser page, and passes:
// a script with the user's cookies is not what this defends against. An origin
// in `trustedOrigins` passes whatever the headers say, for a front end served
// from another origin; an origin CORS allows to send credentials belongs there
// too. It needs no token in forms, no cookie and no state, and it follows
// the check Go's net/http gained in 1.25.
//
// What it does not do: protect a GET that changes something, which should be
// a POST, or tell a subdomain an attacker controls from the site itself when
// the browser sent only Origin -- Sec-Fetch-Site does tell them apart.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

extension RouteBuilder {
    /// Refuses, with 403, a request in the current scope that would change
    /// something and that the browser says another site's page started.
    /// `trustedOrigins` are origins such as `https://app.example.com` whose
    /// pages may send them anyway.
    ///
    /// A middleware in the order of `use`: call it before middleware that
    /// does work for the request, such as `sessions`.
    public func csrfProtection(trustedOrigins: [String] = []) {
        let trusted = Set(trustedOrigins.map { origin -> String in
            let lowered = origin.lowercased()
            precondition(originHost(lowered) != nil,
                         "a trusted origin is scheme://host[:port], with no path: \(origin)")
            return lowered
        })
        use { request, _ in
            if isCrossOriginRefused(method: request.method, fetchSite: request.header("sec-fetch-site"),
                                    origin: request.header("origin"), host: request.authority,
                                    trusted: trusted) {
                throw HTTPError(.forbidden, "cross-origin request refused")
            }
            return nil
        }
    }
}

/// Whether a request with these headers is refused.
func isCrossOriginRefused(method: HTTPMethod, fetchSite: String?, origin: String?, host: String?,
                          trusted: Set<String>) -> Bool {
    switch method {
    case .get, .head, .options: return false
    default: break
    }
    if let origin, trusted.contains(origin.lowercased()) { return false }
    if let fetchSite {
        switch fetchSite.lowercased() {
        case "same-origin", "none": return false
        case "cross-site", "same-site": return true
        // A value no browser sends yet: fall back to Origin.
        default: break
        }
    }
    guard let origin else { return false }
    guard let from = originHost(origin.lowercased()), let host else { return true }
    return withoutDefaultPort(from) != withoutDefaultPort(host.lowercased())
}

/// The host and port of an origin, `scheme://host[:port]`, or nil when it is
/// not one (`null` included).
func originHost(_ origin: String) -> String? {
    let scheme: String
    if origin.hasPrefix("https://") {
        scheme = "https://"
    } else if origin.hasPrefix("http://") {
        scheme = "http://"
    } else {
        return nil
    }
    let host = origin.dropFirst(scheme.count)
    guard !host.isEmpty, !host.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == "@" || $0 == " " })
    else { return nil }
    return String(host)
}

/// `host` without `:80` or `:443`, which a browser leaves out of Origin and
/// a client may put in Host.
private func withoutDefaultPort(_ host: String) -> Substring {
    if host.hasSuffix(":443") { return host.dropLast(4) }
    if host.hasSuffix(":80") { return host.dropLast(3) }
    return host[...]
}
