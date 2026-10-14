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
// A middleware in the scope it is called in. Its headers are added on the way
// out, after the rest of the chain, whoever answered -- the handler, a
// middleware inside it refusing, an error thrown as an answer -- and a header
// the response already has is left as it is, so a route that needs another
// framing or referrer policy sets its own.
//
// Strict-Transport-Security goes only on a response to a request that came
// over HTTPS: a browser ignores it over plain HTTP, and an HTTP deployment
// should not be told it is HTTPS-only (`Request.arrivedOverHTTPS`).
//
// An error that is not a `ResponseError` is answered 500 by the connection
// with every header the response had taken away, these included: a failure
// says nothing about itself, and nothing a handler added half-way survives.
//===----------------------------------------------------------------------===//

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
        use(SecurityHeadersMiddleware(always: always, hsts: hsts))
    }
}

/// The middleware `securityHeaders` adds.
struct SecurityHeadersMiddleware: Middleware {
    let always: [(String, String)]
    let hsts: String?

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        do {
            try await next()
        } catch {
            // Thrown as an answer, a `ResponseError` keeps the headers the
            // response has; add them before the connection answers it. Any
            // other error is a 500 that drops what the handler half built:
            // answer it here, so these headers go out on it too. The
            // connection still logs the error when it reaches it.
            if !(error is any ResponseError) { answerFailure(response.exchange) }
            add(request, response)
            throw error
        }
        add(request, response)
    }

    private func add(_ request: borrowing Request, _ response: borrowing Response) {
        let x = response.exchange
        if let hsts, request.arrivedOverHTTPS, !x.pointee.hasResponseHeader("strict-transport-security") {
            response.addHeader("strict-transport-security", hsts)
        }
        for (name, value) in always where !x.pointee.hasResponseHeader(name) {
            response.addHeader(name, value)
        }
    }
}

extension Request {
    /// Whether the request came over HTTPS, directly or through a trusted
    /// proxy that said so: what Strict-Transport-Security and a cookie's
    /// default `Secure` follow.
    ///
    /// Always false for now: Garuda 2 serves plain HTTP/1 and takes no
    /// proxy's word for the scheme yet. TLS serving and trusted proxies
    /// answer it when they come, and these two follow without changing.
    var arrivedOverHTTPS: Bool { false }
}

extension Exchange {
    /// Whether the response has a header named `name`, which is lowercase:
    /// the records keep their names lowercased.
    func hasResponseHeader(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { wanted in
            var found = false
            forEachResponseHeader { recorded, _ in
                if !found, recorded.count == wanted.count,
                   memcmpEqual(recorded.base, wanted.baseAddress!, wanted.count) {
                    found = true
                }
            }
            return found
        }
    }
}

/// Whether `n` bytes at `a` and `b` are the same.
@inline(__always)
func memcmpEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    var i = 0
    while i < n {
        if a[i] != b[i] { return false }
        i &+= 1
    }
    return true
}
