//===----------------------------------------------------------------------===//
// Routers: routes built on their own and merged into an application.
//
//     func usersRoutes() -> Router {
//         let router = Router()
//         router.use(requireToken)
//         router.get("/:id") { (id: Path<Int>) in … }
//         router.post("/") { (user: Body<NewUser>) in … }
//         return router
//     }
//
//     app.nest("/users", usersRoutes())      // GET /users/:id, POST /users
//     app.merge(healthRoutes())              // as if registered here
//
// A router takes everything an application does -- routes of every kind,
// `use`, `group`, `deadline`, `fallback`, other routers -- and remembers it.
// Merging replays it into the application at that point, inside whatever
// group is open there: the routes take its prefix, and its middleware runs
// in front of the router's own. A router is a description, not a copy of
// state, so the same one can be merged under two prefixes.
//
// Every registration API is written once, on `RouteBuilder`, which both
// `Application` and `Router` are.
//===----------------------------------------------------------------------===//

import AvianHTTP

/// Something routes are registered on: an `Application`, or a `Router` to be
/// merged into one.
public protocol RouteBuilder: AnyObject {
    /// Registers `handler` for `method` and `pattern`: literal segments,
    /// `:param` segments and a trailing `*rest`.
    func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler)

    /// Registers an async handler, run on one of the worker's handler tasks.
    func onAsync(_ method: HTTPMethod, _ pattern: String, _ handler: sending @escaping AsyncHandler)

    /// Registers a route that reads its request body as it arrives, held to
    /// `maxBodySize`.
    func onStreamingBody(_ method: HTTPMethod, _ pattern: String, maxBodySize: Int,
                         _ handler: sending @escaping StreamingBodyHandler)

    /// Mounts every route registered inside `register` under `prefix`, and
    /// scopes any `use` and `fallback` called inside it to those routes.
    func group(_ prefix: String, _ register: () -> Void)

    /// Gives every route registered inside `register` a deadline.
    func deadline(milliseconds: UInt32, _ register: () -> Void)

    /// Runs `middleware` before the handler of every route in the current
    /// scope.
    func use(_ middleware: @escaping Middleware)

    /// Runs an async `middleware` before the handler of every route in the
    /// current scope.
    func use(_ middleware: sending @escaping AsyncMiddleware)

    /// Answers a request no route matches, under the current scope's prefix,
    /// in place of 404. The scope's middleware runs in front of it. A path
    /// some other method has a route for is still 405.
    func fallback(_ handler: @escaping Handler)

    /// An async fallback, as `fallback` with a synchronous one.
    func fallback(_ handler: sending @escaping AsyncHandler)
}

extension RouteBuilder {
    public func get(_ pattern: String, _ handler: @escaping Handler) { on(.get, pattern, handler) }
    public func head(_ pattern: String, _ handler: @escaping Handler) { on(.head, pattern, handler) }
    public func post(_ pattern: String, _ handler: @escaping Handler) { on(.post, pattern, handler) }
    public func put(_ pattern: String, _ handler: @escaping Handler) { on(.put, pattern, handler) }
    public func delete(_ pattern: String, _ handler: @escaping Handler) { on(.delete, pattern, handler) }
    public func patch(_ pattern: String, _ handler: @escaping Handler) { on(.patch, pattern, handler) }
    public func options(_ pattern: String, _ handler: @escaping Handler) { on(.options, pattern, handler) }

    /// A streaming route with no limit of its own on the body.
    public func onStreamingBody(_ method: HTTPMethod, _ pattern: String,
                                _ handler: sending @escaping StreamingBodyHandler) {
        onStreamingBody(method, pattern, maxBodySize: .max, handler)
    }

    /// Registers everything `router` holds here, as if it had been
    /// registered at this point: inside the group that is open, with that
    /// group's prefix and middleware.
    public func merge(_ router: Router) {
        router.replay(into: self)
    }

    /// Registers everything `router` holds under `prefix`: `group(prefix)`
    /// with the router merged inside it.
    public func nest(_ prefix: String, _ router: Router) {
        group(prefix) { router.replay(into: self) }
    }
}

/// Routes, middleware and fallbacks built on their own, to be merged into an
/// application or another router.
public final class Router: RouteBuilder {
    enum Entry {
        case route(HTTPMethod, String, Handler)
        case async(HTTPMethod, String, AsyncHandler)
        case streaming(HTTPMethod, String, Int, StreamingBodyHandler)
        case use(MiddlewareStep)
        case group(String, [Entry])
        case deadline(UInt32, [Entry])
        case fallback(Handler)
        case asyncFallback(AsyncHandler)
    }

    /// What has been registered, innermost open group last.
    private var open: [[Entry]] = [[]]

    public init() {}

    var entries: [Entry] { open[0] }

    private func add(_ entry: Entry) {
        open[open.count - 1].append(entry)
    }

    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        add(.route(method, pattern, handler))
    }

    public func onAsync(_ method: HTTPMethod, _ pattern: String, _ handler: sending @escaping AsyncHandler) {
        add(.async(method, pattern, handler))
    }

    public func onStreamingBody(_ method: HTTPMethod, _ pattern: String, maxBodySize: Int,
                                _ handler: sending @escaping StreamingBodyHandler) {
        add(.streaming(method, pattern, maxBodySize, handler))
    }

    public func group(_ prefix: String, _ register: () -> Void) {
        precondition(prefix.hasPrefix("/"), "a group prefix starts with /: \(prefix)")
        open.append([])
        register()
        add(.group(prefix, open.removeLast()))
    }

    public func deadline(milliseconds: UInt32, _ register: () -> Void) {
        open.append([])
        register()
        add(.deadline(milliseconds, open.removeLast()))
    }

    public func use(_ middleware: @escaping Middleware) {
        add(.use(.sync(middleware)))
    }

    public func use(_ middleware: sending @escaping AsyncMiddleware) {
        add(.use(.async(middleware)))
    }

    public func fallback(_ handler: @escaping Handler) {
        add(.fallback(handler))
    }

    public func fallback(_ handler: sending @escaping AsyncHandler) {
        add(.asyncFallback(handler))
    }

    /// Registers every entry on `builder`, in the order they were made.
    func replay(into builder: some RouteBuilder) {
        precondition(open.count == 1, "a router was merged from inside one of its own groups")
        Router.replay(entries, into: builder)
    }

    private static func replay(_ entries: [Entry], into builder: some RouteBuilder) {
        for entry in entries {
            switch entry {
            case .route(let method, let pattern, let handler):
                builder.on(method, pattern, handler)
            case .async(let method, let pattern, let handler):
                nonisolated(unsafe) let handler = handler
                builder.onAsync(method, pattern, handler)
            case .streaming(let method, let pattern, let limit, let handler):
                nonisolated(unsafe) let handler = handler
                builder.onStreamingBody(method, pattern, maxBodySize: limit, handler)
            case .use(.sync(let middleware)):
                builder.use(middleware)
            case .use(.async(let middleware)):
                nonisolated(unsafe) let middleware = middleware
                builder.use(middleware)
            case .group(let prefix, let inner):
                builder.group(prefix) { replay(inner, into: builder) }
            case .deadline(let milliseconds, let inner):
                builder.deadline(milliseconds: milliseconds) { replay(inner, into: builder) }
            case .fallback(let handler):
                builder.fallback(handler)
            case .asyncFallback(let handler):
                nonisolated(unsafe) let handler = handler
                builder.fallback(handler)
            }
        }
    }
}

// MARK: - Fallbacks in the route table

extension Routes {
    /// Registers `handler` as the fallback for the current scope. It is a
    /// route with no pattern: it has a route number, so middleware and a
    /// deadline are assembled for it like any other, but nothing in the
    /// table leads to it.
    mutating func fallback(_ handler: @escaping Handler, async asyncHandler: AsyncHandler?) {
        let prefix = currentPrefix
        precondition(!fallbacks.contains { $0.prefix == prefix },
                     "a second fallback for \(prefix.isEmpty ? "/" : prefix)")
        fallbacks.append((prefix: prefix, route: Int32(handlers.count)))
        handlers.append(handler)
        asyncHandlers.append(asyncHandler)
        deadlines.append(currentDeadline)
        bodyLimits.append(-1)
        routeGroups.append(openGroups)
    }
}

extension Application {
    public func fallback(_ handler: @escaping Handler) {
        precondition(compiled == nil, "fallback added after the application was compiled")
        routes.fallback(handler, async: nil)
    }

    public func fallback(_ handler: sending @escaping AsyncHandler) {
        precondition(compiled == nil, "fallback added after the application was compiled")
        routes.fallback({ request, _ in request.worker.pointee.runOnTask(request.slot, handler) },
                        async: handler)
    }
}

/// The fallbacks of a compiled application, longest prefix first, so the
/// most specific scope answers.
struct CompiledFallbacks {
    var prefixes: [[UInt8]] = []
    var routes: [Int32] = []

    init(_ fallbacks: [(prefix: String, route: Int32)]) {
        for (prefix, route) in fallbacks.sorted(by: { $0.prefix.utf8.count > $1.prefix.utf8.count }) {
            prefixes.append(Array(prefix.utf8))
            routes.append(route)
        }
    }

    var isEmpty: Bool { routes.isEmpty }

    /// The fallback route for `path`: the one whose prefix is the whole path
    /// or a run of whole segments at its start. -1 for none.
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
