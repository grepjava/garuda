//===----------------------------------------------------------------------===//
// Security headers: what a browser should do with a response it did not ask
// for in the way the page expected.
//
//     app.securityHeaders()
//
//     var headers = SecurityHeaders()
//     headers.contentSecurityPolicy = "default-src 'self'"
//     app.securityHeaders(headers)
//
// A middleware in the scope it is called in. Its headers are added as the
// response is sent, whoever answers -- the handler, a middleware refusing, a
// thrown error -- and a header the response already has is left as it is,
// so a route that needs another framing or referrer policy sets its own.
//
// Strict-Transport-Security goes only on a response to a request that came
// over HTTPS, directly or through a trusted proxy: a browser ignores it over
// plain HTTP, and an HTTP deployment should not be told it is HTTPS-only.
//===----------------------------------------------------------------------===//

import AvianCore

/// The headers `securityHeaders` adds. A nil one is not sent.
public struct SecurityHeaders: Sendable {
    /// Keeps the browser on HTTPS for the site. A year, subdomains included.
    public var strictTransportSecurity: String? = "max-age=31536000; includeSubDomains"
    /// `nosniff`: a response is the content type it says, never guessed.
    public var contentTypeOptions: String? = "nosniff"
    /// Who may put the page in a frame. `SAMEORIGIN` by default; `DENY` for none.
    public var frameOptions: String? = "SAMEORIGIN"
    /// What a link from the page tells the next site about it.
    public var referrerPolicy: String? = "no-referrer"
    /// Keeps a window opened from another site from reaching this one.
    public var crossOriginOpenerPolicy: String? = "same-origin"
    /// Which sites may load the response as a resource: an image, a script.
    public var crossOriginResourcePolicy: String? = "same-origin"
    /// Where the page may load from, and more. None by default: a policy is
    /// written for the site it protects.
    public var contentSecurityPolicy: String? = nil
    /// Which browser features the page may use. None by default.
    public var permissionsPolicy: String? = nil

    public init() {}

    /// The headers other than Strict-Transport-Security, in the order sent.
    var alwaysSent: [(String, String)] {
        var headers: [(String, String)] = []
        if let contentTypeOptions { headers.append(("x-content-type-options", contentTypeOptions)) }
        if let frameOptions { headers.append(("x-frame-options", frameOptions)) }
        if let referrerPolicy { headers.append(("referrer-policy", referrerPolicy)) }
        if let crossOriginOpenerPolicy { headers.append(("cross-origin-opener-policy", crossOriginOpenerPolicy)) }
        if let crossOriginResourcePolicy {
            headers.append(("cross-origin-resource-policy", crossOriginResourcePolicy))
        }
        if let contentSecurityPolicy { headers.append(("content-security-policy", contentSecurityPolicy)) }
        if let permissionsPolicy { headers.append(("permissions-policy", permissionsPolicy)) }
        return headers
    }
}

extension RouteBuilder {
    /// Adds `headers` to every response of the current scope that does not
    /// already carry them.
    public func securityHeaders(_ headers: SecurityHeaders = SecurityHeaders()) {
        let always = headers.alwaysSent
        let hsts = headers.strictTransportSecurity
        for (name, value) in always + (hsts.map { [("strict-transport-security", $0)] } ?? []) {
            precondition(!value.utf8.contains { $0 == 0x0D || $0 == 0x0A || $0 == 0 },
                         "the \(name) header holds a line break: \(value)")
        }
        use { request, response in
            let https = hsts != nil && String(describing: request.scheme) == "https"
            response.onSend { outgoing in
                if https, let hsts, outgoing.header("strict-transport-security") == nil {
                    outgoing.addHeader("strict-transport-security", hsts)
                }
                for (name, value) in always where outgoing.header(name) == nil {
                    outgoing.addHeader(name, value)
                }
            }
            return nil
        }
    }
}
