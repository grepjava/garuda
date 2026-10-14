//===----------------------------------------------------------------------===//
// Middleware: code around a route's handler, in layers.
//
//     app.use { request, response, next in
//         let began = monotonicNanos()
//         try await next()                       // the rest of the chain
//         response.addHeader("server-timing", "app;dur=\(...)")
//     }
//     app.group("/api") {
//         app.use(RequireToken())
//         app.get("/users/:id") { … }            // GET /api/users/:id
//     }
//
// Each layer runs before the ones inside it and gets the response back after
// them: it can answer and not call `next` (a refused token), change the
// response after `next` (a header, a status), or catch what the handler threw
// (a retry, a transaction rolled back). Global middleware is outermost, then
// each group's from the outside in.
//
// A route's chain is put together once, when the application compiles. Per
// request it costs one call per layer; `next` cannot escape the call, so
// nothing is allocated for it.
//===----------------------------------------------------------------------===//

/// A layer around route handlers.
///
/// ```
/// struct RequireToken: Middleware {
///     func handle(_ request: borrowing Request, _ response: borrowing Response,
///                 next: () async throws -> Void) async throws {
///         guard request.header("authorization") != nil else {
///             return response.send(status: .unauthorized)
///         }
///         try await next()
///     }
/// }
/// ```
public protocol Middleware: Sendable {
    /// Handles a request on its way to the route's handler. Call `next` at
    /// most once to run the rest of the chain; return without calling it to
    /// answer here instead.
    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws
}

/// Middleware as a closure, for `use { request, response, next in … }`.
public typealias MiddlewareFunction = @Sendable (
    _ request: borrowing Request, _ response: borrowing Response, _ next: () async throws -> Void
) async throws -> Void

/// A closure registered with `use`.
struct ClosureMiddleware: Middleware {
    let body: MiddlewareFunction

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        try await body(request, response, next)
    }
}

extension RouteBuilder {
    /// Runs `body` around the handler of every route in the current scope:
    /// every route outside a group, or every route of the group it is called
    /// in. The order of `use` calls within a scope is the order they run;
    /// whether they come before or after the routes they cover does not
    /// matter.
    public func use(_ body: @escaping MiddlewareFunction) {
        use(ClosureMiddleware(body: body))
    }
}

/// Wraps `handler` in `layers`, the first outermost: the handler a route
/// with that middleware runs.
func compose(_ layers: [any Middleware], around handler: @escaping Handler) -> Handler {
    var composed = handler
    for layer in layers.reversed() {
        let inner = composed
        composed = { request, response in
            // Request and response are views of one exchange: the layers
            // inside get views of it too.
            let x = request.exchange
            try await layer.handle(request, response) {
                try await inner(Request(x), Response(x))
            }
        }
    }
    return composed
}

/// Joins a group's prefix to a pattern registered inside it. A group's own
/// root, "/", is the prefix itself rather than the prefix and a slash.
func joinPattern(_ prefix: String, _ pattern: String) -> String {
    prefix.isEmpty ? pattern : (pattern == "/" ? prefix : prefix + pattern)
}

/// A group prefix as it is joined: no trailing slash, and "/" alone is no
/// prefix at all.
func normalizedPrefix(_ prefix: String) -> String {
    precondition(prefix.hasPrefix("/"), "a group prefix starts with /: \(prefix)")
    var trimmed = prefix
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed == "/" ? "" : trimmed
}

// MARK: - Routers

/// Routes and middleware built on their own, to be merged into an
/// application -- or another router -- with `merge` or `nest`:
///
/// ```
/// let users = Router()
/// users.use(RequireToken())
/// users.get("/:id") { (id: Path<Int>) in … }
/// app.nest("/users", users)                     // GET /users/:id
/// ```
///
/// A router keeps what it was given and adds it again each time it is
/// merged, so the same router can be mounted under two prefixes.
public final class Router: RouteBuilder, @unchecked Sendable {
    enum Entry {
        case route(HTTPMethod, String, Handler)
        case note(HTTPMethod, String, Int, [Any.Type])
        case use(any Middleware)
        case group(String, [Entry])
    }

    /// What has been registered, innermost open group last.
    private var open: [[Entry]] = [[]]

    public init() {}

    private func add(_ entry: Entry) {
        open[open.count - 1].append(entry)
    }

    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        add(.route(method, pattern, handler))
    }

    public func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int, states: [Any.Type]) {
        add(.note(method, pattern, pathParameters, states))
    }

    public func use(_ middleware: some Middleware) {
        add(.use(middleware))
    }

    public func group(_ prefix: String, _ register: () -> Void) {
        _ = normalizedPrefix(prefix)
        open.append([])
        register()
        add(.group(prefix, open.removeLast()))
    }

    /// Registers everything this router holds on `builder`, in order.
    func replay(into builder: some RouteBuilder) {
        precondition(open.count == 1, "a router was merged from inside one of its own groups")
        Router.replay(open[0], into: builder)
    }

    private static func replay(_ entries: [Entry], into builder: some RouteBuilder) {
        for entry in entries {
            switch entry {
            case .route(let method, let pattern, let handler): builder.on(method, pattern, handler)
            case .note(let method, let pattern, let count, let states):
                builder.noteRoute(method, pattern, pathParameters: count, states: states)
            case .use(let middleware): builder.use(middleware)
            case .group(let prefix, let inner): builder.group(prefix) { replay(inner, into: builder) }
            }
        }
    }
}

extension RouteBuilder {
    /// Registers everything `router` holds here: inside the group open at
    /// this point, with its prefix and its middleware.
    public func merge(_ router: Router) {
        router.replay(into: self)
    }

    /// Registers everything `router` holds under `prefix`.
    public func nest(_ prefix: String, _ router: Router) {
        group(prefix) { router.replay(into: self) }
    }
}
