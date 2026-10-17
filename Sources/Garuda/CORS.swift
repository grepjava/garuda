//===----------------------------------------------------------------------===//
// Cross-origin resource sharing.
//
//     app.group("/api") {
//         app.cors(CORSPolicy(origins: ["https://app.example.com"],
//                             allowCredentials: true))
//         app.use(RequireToken())
//         app.get("/me") { … }
//     }
//
// A policy belongs to a scope: every route registered in the application,
// the group or the router it is set in, the innermost policy winning. It is
// middleware, but not in the order of `use`: when the application compiles,
// a route's policy is taken out of its chain and put in front of all of it
// (`placingCORSFirst`), because a browser's preflight carries no credentials
// and must not meet the middleware that asks for them, and a refusal from
// that middleware needs the CORS headers for the page to read it.
//
// A preflight -- OPTIONS with Origin and Access-Control-Request-Method -- is
// answered 204 by the policy, whether or not the path has an OPTIONS route.
// A path routed only for other methods would otherwise be 405: the
// connection's dispatch asks `answerPreflight` before it answers 405 to an
// OPTIONS, and only when some route has a policy, so an application without
// one, and every request that matched a route, pays nothing for it. Any other
// request from an allowed origin is served as usual, and whatever answers it
// carries Access-Control-Allow-Origin. A request from an origin the policy
// does not allow is served too, without the headers, and the browser keeps
// the answer from the page. What no route answers -- a 404, a 405 -- carries
// none, and neither does a 500 for an error that is not a `ResponseError`,
// which is answered with every header the response had taken away.
//===----------------------------------------------------------------------===//

import GarudaWire

/// Which origins, methods and headers other sites' pages may use.
public struct CORSPolicy: Sendable {
    /// The origins a page may be served from to read responses.
    public enum Origins: Sendable {
        /// Any origin, answered with `*`. Not allowed with credentials.
        case any
        /// Exactly these origins, such as `https://app.example.com`.
        case list([String])
        /// Origins `allows` says yes to, answered with the origin itself.
        case matching(@Sendable (String) -> Bool)
    }

    public var origins: Origins
    /// The methods a preflight allows, or nil for the methods the path is
    /// routed for.
    public var methods: [HTTPMethod]?
    /// The request headers a preflight allows, or nil for whatever headers
    /// the preflight asks for.
    public var headers: [String]?
    /// Response headers beyond the safelisted ones a page may read.
    public var exposedHeaders: [String]
    /// Whether the page's request may carry cookies and HTTP authentication,
    /// and see the answer to one that did.
    public var allowCredentials: Bool
    /// How many seconds a browser may keep a preflight's answer, or nil to
    /// leave it to the browser.
    public var maxAge: Int?

    public init(origins: Origins, methods: [HTTPMethod]? = nil, headers: [String]? = nil,
                exposedHeaders: [String] = [], allowCredentials: Bool = false,
                maxAge: Int? = 600) {
        if allowCredentials, case .any = origins {
            preconditionFailure("a CORS policy with credentials cannot allow any origin: " +
                                "name the origins, or decide with .matching")
        }
        self.origins = origins
        self.methods = methods
        self.headers = headers
        self.exposedHeaders = exposedHeaders
        self.allowCredentials = allowCredentials
        self.maxAge = maxAge
    }

    /// A policy for these origins.
    public init(origins: [String], methods: [HTTPMethod]? = nil, headers: [String]? = nil,
                exposedHeaders: [String] = [], allowCredentials: Bool = false,
                maxAge: Int? = 600) {
        self.init(origins: .list(origins), methods: methods, headers: headers,
                  exposedHeaders: exposedHeaders, allowCredentials: allowCredentials,
                  maxAge: maxAge)
    }

    /// What Access-Control-Allow-Origin says to `origin`, or nil when it is
    /// not allowed.
    func allowOrigin(_ origin: String) -> String? {
        switch origins {
        case .any: return "*"
        case .list(let allowed): return allowed.contains(origin) ? origin : nil
        case .matching(let allows): return allows(origin) ? origin : nil
        }
    }

    /// Whether the answer depends on the request's Origin, which a cache
    /// must be told.
    var variesByOrigin: Bool {
        if case .any = origins { return false }
        return true
    }
}

extension RouteBuilder {
    /// Sets the CORS policy of the current scope: the routes of the
    /// application, group or router it is called in, and the groups inside
    /// it that set none of their own. It answers preflights and runs in front
    /// of all of a route's middleware, wherever it is called. A scope has at
    /// most one.
    public func cors(_ policy: CORSPolicy) {
        use(CORSMiddleware(policy: policy))
    }
}

/// A scope's CORS policy, as the middleware it is registered as.
struct CORSMiddleware: Middleware {
    let policy: CORSPolicy

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        let x = request.exchange
        guard request.headerBytes("origin") != nil else {
            if policy.variesByOrigin { response.addHeader("vary", "Origin") }
            return try await runRest(x, next) {
                if policy.variesByOrigin { Response(x).addHeader("vary", "Origin") }
            }
        }
        if request.method == .options, request.headerBytes("access-control-request-method") != nil {
            addPreflightHeaders(x, policy, routed: routedMethods(x))
            return response.send(status: .noContent)
        }
        addCORSHeaders(x, policy)
        try await runRest(x, next) { addCORSHeaders(x, policy) }
    }

    /// Runs the rest of the chain. An error other than a `ResponseError` is a
    /// 500 that drops every header: it is answered here and `again` adds this
    /// policy's back, so a page on another origin can read even that. The
    /// error goes on to the connection, which logs it.
    @inline(__always)
    private func runRest(_ x: UnsafeMutablePointer<Exchange>, _ next: () async throws -> Void,
                         again: () -> Void) async throws {
        do {
            try await next()
        } catch {
            if !(error is any ResponseError) {
                answerFailure(x)
                again()
            }
            throw error
        }
    }
}

/// A route's middleware, from its scopes' (outermost first), with the CORS
/// policy of the innermost scope that has one moved in front of everything
/// and every outer one dropped. The application compiles a route's chain
/// from this.
func placingCORSFirst(_ scopes: [[any Middleware]]) -> [any Middleware] {
    var policy: (any Middleware)? = nil
    var layers: [any Middleware] = []
    for scope in scopes {
        var found = false
        for layer in scope {
            guard layer is CORSMiddleware else {
                layers.append(layer)
                continue
            }
            precondition(!found, "a second CORS policy in one scope")
            found = true
            policy = layer
        }
    }
    if let policy { layers.insert(policy, at: 0) }
    return layers
}

/// The headers every answer to an allowed origin carries.
func addCORSHeaders(_ x: UnsafeMutablePointer<Exchange>, _ policy: CORSPolicy) {
    let response = Response(x)
    if policy.variesByOrigin { response.addHeader("vary", "Origin") }
    guard let origin = Request(x).header("origin"), let allowed = policy.allowOrigin(origin) else { return }
    response.addHeader("access-control-allow-origin", allowed)
    if policy.allowCredentials { response.addHeader("access-control-allow-credentials", "true") }
    if !policy.exposedHeaders.isEmpty {
        response.addHeader("access-control-expose-headers", policy.exposedHeaders.joined(separator: ", "))
    }
}

/// The headers of a preflight's answer. `routed` is what the path is routed
/// for; when it is empty, the method the preflight asks for is allowed.
func addPreflightHeaders(_ x: UnsafeMutablePointer<Exchange>, _ policy: CORSPolicy, routed: [HTTPMethod]) {
    let request = Request(x)
    let response = Response(x)
    var vary = policy.variesByOrigin ? "Origin, " : ""
    vary += policy.methods == nil ? "Access-Control-Request-Method, " : ""
    vary += policy.headers == nil ? "Access-Control-Request-Headers" : ""
    if vary.hasSuffix(", ") { vary.removeLast(2) }
    if !vary.isEmpty { response.addHeader("vary", vary) }
    guard let origin = request.header("origin"), let allowed = policy.allowOrigin(origin) else { return }
    response.addHeader("access-control-allow-origin", allowed)
    if policy.allowCredentials { response.addHeader("access-control-allow-credentials", "true") }

    let methods: String
    if let listed = policy.methods {
        methods = methodList(listed)
    } else if !routed.isEmpty {
        methods = methodList(routed)
    } else {
        methods = request.header("access-control-request-method") ?? ""
    }
    if !methods.isEmpty { response.addHeader("access-control-allow-methods", methods) }

    if let listed = policy.headers {
        if !listed.isEmpty { response.addHeader("access-control-allow-headers", listed.joined(separator: ", ")) }
    } else if let asked = request.header("access-control-request-headers"), !asked.isEmpty {
        response.addHeader("access-control-allow-headers", asked)
    }
    if let maxAge = policy.maxAge { response.addHeader("access-control-max-age", "\(maxAge)") }
}

/// Methods as an Allow-style list; a method with no name of its own is left out.
private func methodList(_ methods: [HTTPMethod]) -> String {
    methods.filter { $0 != .other }.map(\.name).joined(separator: ", ")
}

/// The methods the request's path is routed for.
func routedMethods(_ x: UnsafeMutablePointer<Exchange>) -> [HTTPMethod] {
    guard let application = x.pointee.application else { return [] }
    let path = x.pointee.head.path
    let base = x.pointee.base + Int(path.offset)
    var scratch = RouteParameters()
    return application._withUnsafeGuaranteedRef { $0.table.allowedMethods(base, path.count, into: &scratch) }
}

/// Answers a preflight to a path routed only for other methods, when one of
/// those routes has a CORS policy: the connection's dispatch asks this before
/// answering such an OPTIONS 405. `allowed` is what the path is routed for.
/// False, answering nothing, when it is not a preflight or no route there has
/// a policy.
func answerPreflight(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, allowed: [HTTPMethod],
                     _ base: UnsafePointer<UInt8>, _ count: Int) -> Bool {
    let request = Request(x)
    guard request.headerBytes("origin") != nil,
          request.headerBytes("access-control-request-method") != nil else { return false }
    var scratch = RouteParameters()
    for method in allowed {
        let route = app.table.match(method, base, count, into: &scratch)
        guard route >= 0, let policy = app.corsPolicies[Int(route)] else { continue }
        addPreflightHeaders(x, policy, routed: allowed)
        x.pointee.answer(204, nil, 0)
        return true
    }
    return false
}
