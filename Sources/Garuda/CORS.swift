//===----------------------------------------------------------------------===//
// Cross-origin resource sharing.
//
//     app.group("/api") {
//         app.cors(CORSPolicy(origins: ["https://app.example.com"],
//                             allowCredentials: true))
//         app.use(requireToken)
//         app.get("/me") { … }
//     }
//
// A policy belongs to a scope, like a fallback: every route registered in
// the application, the group or the router it is set in, the innermost policy
// winning. It is not a middleware in the order of `use`. It runs in front of
// all of a route's middleware, because a browser's preflight carries no
// credentials and must not meet the middleware that asks for them, and a
// refusal from that middleware needs the CORS headers for the page to read it.
//
// A preflight -- OPTIONS with Origin and Access-Control-Request-Method -- is
// answered 204 by the policy, whether or not the path has an OPTIONS route:
// a path routed only for other methods would otherwise be 405. Any other
// request from an allowed origin is served as usual, and whatever answers it
// carries Access-Control-Allow-Origin. A request from an origin the policy does
// not allow is served too, without the headers, and the browser keeps the
// answer from the page. What no route answers -- a 404, a 405 -- carries none.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

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

    /// The middleware step that applies this policy to a route.
    var step: Middleware {
        { request, response in
            guard request.headerBytes("origin") != nil else {
                if self.variesByOrigin { response.addHeader("vary", "Origin") }
                return nil
            }
            if request.method == .options, request.headerBytes("access-control-request-method") != nil {
                request.worker.pointee.addPreflightHeaders(request.slot, self,
                                                           routed: request.worker.pointee.routedMethods(request.slot))
                return HTTPStatus.noContent
            }
            request.worker.pointee.addCORSHeaders(request.slot, self)
            return nil
        }
    }
}

extension Worker {
    /// The headers every answer to an allowed origin carries.
    mutating func addCORSHeaders(_ slot: Int, _ policy: CORSPolicy) {
        if policy.variesByOrigin { addHeader(slot, "vary", "Origin") }
        guard let origin = requestHeader(slot, "origin"),
              let allowed = policy.allowOrigin(origin) else { return }
        addHeader(slot, "access-control-allow-origin", allowed)
        if policy.allowCredentials { addHeader(slot, "access-control-allow-credentials", "true") }
        if !policy.exposedHeaders.isEmpty {
            addHeader(slot, "access-control-expose-headers", policy.exposedHeaders.joined(separator: ", "))
        }
    }

    /// The headers of a preflight's answer. `routed` is what the path is
    /// routed for, or empty for a fallback, which answers any method.
    mutating func addPreflightHeaders(_ slot: Int, _ policy: CORSPolicy, routed: [HTTPMethod]) {
        var vary = policy.variesByOrigin ? "Origin, " : ""
        vary += policy.methods == nil ? "Access-Control-Request-Method, " : ""
        vary += policy.headers == nil ? "Access-Control-Request-Headers" : ""
        if vary.hasSuffix(", ") { vary.removeLast(2) }
        if !vary.isEmpty { addHeader(slot, "vary", vary) }
        guard let origin = requestHeader(slot, "origin"),
              let allowed = policy.allowOrigin(origin) else { return }
        addHeader(slot, "access-control-allow-origin", allowed)
        if policy.allowCredentials { addHeader(slot, "access-control-allow-credentials", "true") }

        let methods: String
        if let listed = policy.methods {
            methods = listed.compactMap { $0.token.map { "\($0)" } }.joined(separator: ", ")
        } else if !routed.isEmpty {
            methods = routed.compactMap { $0.token.map { "\($0)" } }.joined(separator: ", ")
        } else {
            methods = requestHeader(slot, "access-control-request-method") ?? ""
        }
        if !methods.isEmpty { addHeader(slot, "access-control-allow-methods", methods) }

        if let listed = policy.headers {
            if !listed.isEmpty { addHeader(slot, "access-control-allow-headers", listed.joined(separator: ", ")) }
        } else if let asked = requestHeader(slot, "access-control-request-headers"), !asked.isEmpty {
            addHeader(slot, "access-control-allow-headers", asked)
        }
        if let maxAge = policy.maxAge { addHeader(slot, "access-control-max-age", "\(maxAge)") }
    }

    /// The methods the path of the request on `slot` is routed for.
    mutating func routedMethods(_ slot: Int) -> [HTTPMethod] {
        guard let installed = application else { return [] }
        let c = table[slot]
        let path = c.pointee.head.path
        let headBase = c.pointee.headBase()
        let (base, count) = rootPath.strip(headBase + Int(path.offset), path.count)
        return installed.pointee.routes.allowedMethods(base, count, into: &c.pointee.routeParameters)
    }

    /// Answers a preflight to a path routed only for other methods, when one
    /// of those routes has a CORS policy. False when none has.
    mutating func answerPreflight(_ slot: Int, allowed: [HTTPMethod],
                                  _ base: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        guard let installed = application, installed.pointee.hasCORS,
              requestHeader(slot, "origin") != nil,
              requestHeader(slot, "access-control-request-method") != nil else { return false }
        let c = table[slot]
        for method in allowed {
            let route = installed.pointee.routes.match(method, base, count, into: &c.pointee.routeParameters)
            guard route >= 0, let policy = installed.pointee.corsPolicies[Int(route)] else { continue }
            addPreflightHeaders(slot, policy, routed: allowed)
            respond(slot, status: 204, nil, 0)
            return true
        }
        return false
    }

    /// A request header by lower-case name, as a string.
    mutating func requestHeader(_ slot: Int, _ name: StaticString) -> String? {
        requestHeader(slot, name.utf8Start, name.utf8CodeUnitCount)?.string
    }

    mutating func addHeader(_ slot: Int, _ name: String, _ value: String) {
        var name = name
        var value = value
        name.withUTF8 { n in
            value.withUTF8 { v in
                _ = addResponseHeader(slot, ByteSpan(n.baseAddress!, n.count), ByteSpan(v.baseAddress!, v.count))
            }
        }
    }
}
