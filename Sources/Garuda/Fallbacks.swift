//===----------------------------------------------------------------------===//
// Fallbacks: what answers a request no route matches.
//
//     app.fallback { request, response in
//         response.send(status: .notFound, "no \(request.path)")
//     }
//     app.group("/api") {
//         app.use(RequireToken())
//         app.fallback { () in JSON(["error": "no such endpoint"]) }
//     }
//
// A fallback belongs to a scope -- the application, a group, a router -- and
// answers, in place of a 404, a request whose path is the scope's prefix or
// lies under it and that no route matches, for any method. The most specific
// scope's answers: the one with the longest prefix that is the whole path or
// a run of whole segments at its start, so `/api`'s answers `/api/x` and
// `/api`, and not `/apiary`. A path some route has for another method is
// still a 405, which says what it does take.
//
// A fallback is a route with no pattern: its scope's middleware, CORS policy,
// deadline and limits are put in front of it when the application compiles,
// as for any route, so a preflight under a scope with a policy is answered by
// the policy, with the method it asks for. Nothing in the route table leads to
// it: the connection's dispatch looks for one only once the table has
// matched nothing, so a request that matched a route pays nothing for it, and
// neither does an application with none. It is not in the OpenAPI document,
// and response observers see what it answers with no route.
//===----------------------------------------------------------------------===//

import GarudaWire

extension Application {
    public func fallback(_ handler: @escaping Handler) {
        precondition(compiledApplication == nil, "fallback added after the application was compiled")
        let prefix = currentPrefix
        precondition(!fallbacks.contains { $0.pattern == prefix },
                     "a second fallback for \(prefix.isEmpty ? "/" : prefix)")
        fallbacks.append(RouteEntry(method: .get, pattern: prefix, registeredPattern: "",
                                    parameters: 0, handler: handler, groups: openGroups))
    }
}

extension RouteBuilder {
    /// Registers a typed fallback: one that takes what it needs from the
    /// request and returns what it means, as a typed route does. It has no
    /// pattern, so it takes no `Path` parameters.
    @inlinable
    public func fallback<each E: RequestExtractor, R: ResponseConvertible>(
        _ handler: @escaping @concurrent @Sendable (repeat each E) async throws -> R
    ) {
        fallback { request, response in
            var parameter = 0
            let values = HandOver((repeat try await (each E).extract(from: request, parameter: &parameter)))
            try await callTyped(handler, values).value.write(to: response)
        }
    }
}

/// The fallbacks of a compiled application, longest prefix first, so the
/// most specific scope answers.
struct CompiledFallbacks {
    var prefixes: [[UInt8]] = []
    /// Each one's handler index, after the routes'.
    var routes: [Int32] = []

    init() {}

    /// `prefixes[i]` is answered by handler `first + i`.
    init(_ prefixes: [String], first: Int) {
        let sorted = prefixes.enumerated().sorted { $0.element.utf8.count > $1.element.utf8.count }
        for (i, prefix) in sorted {
            self.prefixes.append(Array(prefix.utf8))
            routes.append(Int32(first + i))
        }
    }

    var isEmpty: Bool { routes.isEmpty }

    /// The fallback for `path`: the one whose prefix is the whole path or a
    /// run of whole segments at its start. -1 for none.
    func match(_ path: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
        for (i, prefix) in prefixes.enumerated() {
            let n = prefix.count
            guard n <= count else { continue }
            var k = 0
            while k < n && prefix[k] == path[k] { k += 1 }
            if k == n && (n == 0 || n == count || path[n] == 0x2F) { return routes[i] }
        }
        return -1
    }
}
