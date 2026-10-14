//===----------------------------------------------------------------------===//
// The application: routes registered at start-up, compiled once, then served.
//
//     let app = Application()
//     app.get("/user/:id") { (id: Path<Int>) in JSON(user(id.value)) }
//     exit(app.run())
//
// Registration happens on one thread before anything is served. `run`
// compiles the routes into flat memory that every thread of every shard only
// reads, so serving never takes a lock or counts a reference to find a route.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega

/// GET, POST and the rest, as routes are registered by them.
public typealias HTTPMethod = GarudaWire.HTTPMethod

/// A handler that writes its own response.
public typealias Handler = @Sendable (borrowing Request, borrowing Response) async throws -> Void

/// What routes can be registered on.
public protocol RouteBuilder: AnyObject {
    /// Registers `handler` for `method` and `pattern`.
    func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler)

    /// Notes what a typed route's handler asks for, so `problems()` can find
    /// a route that cannot work before anything is served: how many path
    /// parameters it takes, and the `app.state` types it needs.
    func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int, states: [Any.Type])

    /// Gives the route registered last its entry in the OpenAPI document
    /// (OpenAPI.swift). The route methods call it, and return the entry.
    func document(_ operation: OpenAPIOperation)

    /// Adds what `note` says to the OpenAPI entry of every route in the
    /// current scope, wherever in it the call is, as `use` applies to them
    /// all. `authenticate` and `authorize` use it to say what they can
    /// answer. A note leaves alone what a route has said about itself.
    func describeRoutes(_ note: @escaping OperationNote)

    /// Runs `middleware` around the handler of every route in the current
    /// scope (Middleware.swift).
    func use(_ middleware: some Middleware)

    /// Mounts every route registered inside `register` under `prefix`, with
    /// the middleware `use` adds inside it running after the scope's own:
    ///
    /// ```
    /// app.group("/api") {
    ///     app.use(RequireToken())
    ///     app.get("/users/:id") { … }        // GET /api/users/:id
    ///     app.group("/admin") {
    ///         app.use(RequireAdmin())
    ///         app.delete("/users/:id") { … } // DELETE /api/admin/users/:id,
    ///     }                                   // RequireToken, then RequireAdmin
    /// }
    /// ```
    func group(_ prefix: String, _ register: () -> Void)

    /// Answers a request no route matches under the current scope's prefix,
    /// for any method, in place of 404; the most specific scope's answers.
    /// The scope's middleware runs in front of it. A path some other method
    /// has a route for is still 405 (Fallbacks.swift).
    func fallback(_ handler: @escaping Handler)
}

extension RouteBuilder {
    public func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int, states: [Any.Type]) {}
    public func document(_ operation: OpenAPIOperation) {}
    public func describeRoutes(_ note: @escaping OperationNote) {}

    // Each returns the route's OpenAPI entry, for `.summary(...)` and the
    // rest (OpenAPI.swift).
    @discardableResult
    public func get(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.get, pattern, handler)
    }
    @discardableResult
    public func head(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.head, pattern, handler)
    }
    @discardableResult
    public func post(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.post, pattern, handler)
    }
    @discardableResult
    public func put(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.put, pattern, handler)
    }
    @discardableResult
    public func delete(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.delete, pattern, handler)
    }
    @discardableResult
    public func patch(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.patch, pattern, handler)
    }
    @discardableResult
    public func options(_ pattern: String, _ handler: @escaping Handler) -> OpenAPIOperation {
        documentedRoute(.options, pattern, handler)
    }
}

public final class Application: RouteBuilder, @unchecked Sendable {
    var table = RouteTable()
    var routes: [RouteEntry] = []
    /// Middleware for every route, from `use` outside any group.
    var global: [any Middleware] = []
    /// Every group opened so far: the prefix it adds and the middleware `use`
    /// gave it.
    var groups: [(prefix: String, middleware: [any Middleware])] = []
    /// The groups open right now, outermost first.
    var openGroups: [Int] = []
    /// `app.state` registrations, and the shard hooks (State.swift).
    var stateFactories: [StateFactory] = []
    var startHooks: [@Sendable (ShardContext) async throws -> Void] = []
    var stopHooks: [@Sendable (ShardContext) async -> Void] = []
    /// What a path with a trailing slash no route has is answered with
    /// (TrailingSlash.swift).
    var trailingSlashPolicy = TrailingSlash.strict
    /// `app.onResponse` registrations (ResponseObservers.swift).
    var responseObservers: [ResponseObserver] = []
    /// Each route's OpenAPI entry, what scopes add to them, and the
    /// documents `openAPI` serves (OpenAPI.swift).
    var documentation = APIDocumentation()
    /// Each scope's `fallback`, its pattern the scope's prefix
    /// (Fallbacks.swift). Kept apart from `routes`: nothing in the route
    /// table, the checks or the OpenAPI document is about them.
    var fallbacks: [RouteEntry] = []
    /// The routes as connections read them, made the first time the
    /// application runs or is tested. Nothing can be added after that.
    var compiledApplication: CompiledApplication?

    public init() {}

    // MARK: Routes

    /// Registers `handler` for `method` and `pattern`: literal segments,
    /// `:param` segments and a trailing `*rest`, under the prefixes of the
    /// groups open now. A pattern that cannot be served, or a route added
    /// once the application has run or been tested, is a mistake in the
    /// program and stops it.
    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        precondition(compiledApplication == nil, "route \(pattern) added after the application was compiled")
        let full = joinPattern(currentPrefix, pattern)
        let parameters: Int
        do {
            parameters = try table.add(method, full, route: Int32(routes.count))
        } catch {
            preconditionFailure("route \(method) \(full): \(error)")
        }
        routes.append(RouteEntry(method: method, pattern: full, registeredPattern: pattern,
                                 parameters: parameters, handler: handler, groups: openGroups))
    }

    public func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int, states: [Any.Type]) {
        guard let last = routes.indices.last, routes[last].registeredPattern == pattern,
              routes[last].method == method else { return }
        routes[last].pathExtractors = pathParameters
        routes[last].states = states
    }

    // MARK: Scopes

    public func use(_ middleware: some Middleware) {
        precondition(compiledApplication == nil, "middleware added after the application was compiled")
        if let group = openGroups.last {
            groups[group].middleware.append(middleware)
        } else {
            global.append(middleware)
        }
    }

    public func group(_ prefix: String, _ register: () -> Void) {
        precondition(compiledApplication == nil, "group added after the application was compiled")
        groups.append((prefix: normalizedPrefix(prefix), middleware: []))
        openGroups.append(groups.count - 1)
        defer { openGroups.removeLast() }
        register()
    }

    /// The prefix routes registered now are mounted under.
    var currentPrefix: String {
        openGroups.map { groups[$0].prefix }.joined()
    }

    /// The middleware around route `index`, outermost first: global, then
    /// its groups from the outside in, as they stand when this is asked.
    func middleware(of route: RouteEntry) -> [any Middleware] {
        // A CORS policy is not in the order of `use`: the innermost scope's
        // runs in front of everything else (CORS.swift).
        // The markers of `maxBodySize` and `concurrencyLimit` are read at
        // compilation, not run (RequestLimits.swift).
        placingCORSFirst([global] + route.groups.map { group in
            groups[group].middleware.filter { !($0 is any ScopeLimitMarker) }
        })
    }

    // MARK: Checks

    /// What is wrong with the routes, in the order they were registered, and
    /// empty when there is nothing. `run` prints these and exits 2 rather
    /// than serving; a test can ask for them without starting anything:
    ///
    /// ```
    /// #expect(app.problems().isEmpty)
    /// ```
    ///
    /// It finds a handler taking more `Path` extractors than its pattern has
    /// parameters -- those are taken by position, so the extra one has
    /// nothing to take and every request to that route is a 500 -- and one
    /// asking for `State` of a type no `app.state` builds.
    public func problems() -> [String] {
        var found: [String] = []
        let built = Set(stateFactories.map(\.key))
        for route in routes {
            if route.pathExtractors > route.parameters {
                found.append("\(route.method.name) \(route.pattern) takes \(route.pathExtractors) Path "
                             + "parameters, and its pattern has \(route.parameters)")
            }
            for state in route.states where !built.contains(ObjectIdentifier(state)) {
                found.append("\(route.method.name) \(route.pattern) asks for State<\(state)>, "
                             + "and no app.state builds it")
            }
        }
        return found
    }

    // MARK: Compiling

    /// The routes as every connection reads them. Made once.
    func compile() -> CompiledApplication {
        if let compiledApplication { return compiledApplication }
        // The documents `openAPI` serves, written once from every route.
        writeServedDocuments()
        // Each route's middleware is put in front of it now, once: gathered
        // from its scopes as they stand at the end, so a `use` after the
        // routes it covers applies to them too. A route with none keeps its
        // own handler and pays nothing.
        // Fallbacks are served as routes after the real ones, which nothing
        // in the table leads to (Fallbacks.swift). A scope's limits wrap the
        // handler itself, inside every layer (RequestLimits.swift).
        var serving = routes + fallbacks
        var scopeLimits = ScopeLimits()
        var bodyLimits: [Int] = []
        for i in serving.indices {
            let (bodyLimit, permits) = scopeLimits.limits(of: serving[i].groups, in: groups)
            bodyLimits.append(bodyLimit)
            serving[i].handler = limited(serving[i].handler, permits)
            let layers = middleware(of: serving[i])
            if !layers.isEmpty { serving[i].handler = compose(layers, around: serving[i].handler) }
            serving[i].cors = (layers.first as? CORSMiddleware)?.policy
        }
        let compiled = CompiledApplication(table: table.compile(), routes: serving,
                                           stateFactories: stateFactories,
                                           startHooks: startHooks, stopHooks: stopHooks,
                                           trailingSlash: trailingSlashPolicy,
                                           observers: responseObservers,
                                           fallbacks: CompiledFallbacks(fallbacks.map(\.pattern),
                                                                        first: routes.count),
                                           bodyLimits: bodyLimits)
        compiledApplication = compiled
        return compiled
    }
}

/// A route as it is registered.
struct RouteEntry {
    var method: HTTPMethod
    /// With its groups' prefixes.
    var pattern: String
    /// As it was given to `on`, inside its groups.
    var registeredPattern: String
    /// How many parameters the pattern captures.
    var parameters: Int
    var handler: Handler
    /// The groups it was registered inside, outermost first.
    var groups: [Int] = []
    /// How many `Path` extractors the handler takes, when it is typed.
    var pathExtractors = 0
    /// Registered through `app.heavy`.
    var heavy = false
    /// The `app.state` types its handler asks for, when it is typed.
    var states: [Any.Type] = []
    /// The CORS policy in front of it, for a preflight to its path that no
    /// OPTIONS route takes (CORS.swift).
    var cors: CORSPolicy? = nil
}

/// The routes, laid out for serving: a flat route table and the handlers by
/// route index. Only ever read once made, from any thread.
final class CompiledApplication: @unchecked Sendable {
    let table: CompiledRoutes
    let handlers: UnsafeMutablePointer<Handler>
    let routeCount: Int
    /// What each route's handler costs, and the heavy lane.
    let costs: RouteCosts
    /// Spare connection memory, by worker thread.
    let connections = ConnectionCache()
    /// The runtime serving it, for the work a request leaves running beside
    /// its handler: an event stream's keep-alive. Set before it serves.
    var runtime: Runtime?
    /// This shard's state, and what builds it and stops it (State.swift).
    let services: ServiceTable
    /// How starting went, once a test client has started it.
    let testStart = Mutex<Result<Void, any Error>?>(nil)
    let stateFactories: [StateFactory]
    let startHooks: [@Sendable (ShardContext) async throws -> Void]
    let stopHooks: [@Sendable (ShardContext) async -> Void]
    /// Each route's CORS policy, by route index, and whether any route has
    /// one: a path with none never looks (CORS.swift).
    let corsPolicies: [CORSPolicy?]
    let hasCORS: Bool
    /// What a path with a trailing slash no route has is answered with.
    let trailingSlash: TrailingSlash
    /// What `app.onResponse` registered, and each route's pattern by index
    /// for them to be told (ResponseObservers.swift).
    let observers: [ResponseObserver]
    let patterns: [String]
    /// Each scope's fallback, by prefix, its handlers after the routes'
    /// (Fallbacks.swift).
    let fallbacks: CompiledFallbacks
    /// Each handler's body limit, -1 for `--max-body`, and whether any has
    /// one: a connection matches a request to its route before reading its
    /// body only then (RequestLimits.swift).
    let bodyLimits: [Int]
    let hasBodyLimits: Bool

    init(table: CompiledRoutes, routes: [RouteEntry], stateFactories: [StateFactory] = [],
         startHooks: [@Sendable (ShardContext) async throws -> Void] = [],
         stopHooks: [@Sendable (ShardContext) async -> Void] = [],
         trailingSlash: TrailingSlash = .strict,
         observers: [ResponseObserver] = [],
         fallbacks: CompiledFallbacks = CompiledFallbacks(),
         bodyLimits: [Int] = []) {
        self.table = table
        self.trailingSlash = trailingSlash
        self.observers = observers
        self.fallbacks = fallbacks
        self.bodyLimits = bodyLimits
        hasBodyLimits = bodyLimits.contains { $0 >= 0 }
        // A fallback is never reported as a route.
        let routed = routes.count - fallbacks.routes.count
        patterns = routes[..<routed].map(\.pattern)
        self.stateFactories = stateFactories
        self.startHooks = startHooks
        self.stopHooks = stopHooks
        services = ServiceTable(capacity: stateFactories.count)
        routeCount = routes.count
        corsPolicies = routes.map(\.cors)
        hasCORS = corsPolicies.contains { $0 != nil }
        costs = RouteCosts(declared: routes.map(\.heavy), names: routes.enumerated().map { i, route in
            i < routed ? "\(route.method.name) \(route.pattern)"
                       : "the fallback for \(route.pattern.isEmpty ? "/" : route.pattern)"
        })
        handlers = .allocate(capacity: max(1, routes.count))
        for (i, route) in routes.enumerated() { (handlers + i).initialize(to: route.handler) }
    }

    deinit {
        handlers.deinitialize(count: routeCount)
        handlers.deallocate()
        table.destroy()
    }
}
