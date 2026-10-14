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

/// GET, POST and the rest, as routes are registered by them.
public typealias HTTPMethod = GarudaWire.HTTPMethod

/// A handler that writes its own response.
public typealias Handler = @Sendable (borrowing Request, borrowing Response) async throws -> Void

/// What routes can be registered on.
public protocol RouteBuilder: AnyObject {
    /// Registers `handler` for `method` and `pattern`.
    func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler)

    /// Notes what a typed route's handler asks for, so `problems()` can find
    /// a route that cannot work before anything is served.
    func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int)
}

extension RouteBuilder {
    public func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int) {}

    public func get(_ pattern: String, _ handler: @escaping Handler) { on(.get, pattern, handler) }
    public func head(_ pattern: String, _ handler: @escaping Handler) { on(.head, pattern, handler) }
    public func post(_ pattern: String, _ handler: @escaping Handler) { on(.post, pattern, handler) }
    public func put(_ pattern: String, _ handler: @escaping Handler) { on(.put, pattern, handler) }
    public func delete(_ pattern: String, _ handler: @escaping Handler) { on(.delete, pattern, handler) }
    public func patch(_ pattern: String, _ handler: @escaping Handler) { on(.patch, pattern, handler) }
    public func options(_ pattern: String, _ handler: @escaping Handler) { on(.options, pattern, handler) }
}

public final class Application: RouteBuilder, @unchecked Sendable {
    var table = RouteTable()
    var routes: [RouteEntry] = []
    /// The routes as connections read them, made the first time the
    /// application runs or is tested. Nothing can be added after that.
    var compiledApplication: CompiledApplication?

    public init() {}

    // MARK: Routes

    /// Registers `handler` for `method` and `pattern`: literal segments,
    /// `:param` segments and a trailing `*rest`. A pattern that cannot be
    /// served, or a route added once the application has run or been tested,
    /// is a mistake in the program and stops it.
    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        precondition(compiledApplication == nil, "route \(pattern) added after the application was compiled")
        let parameters: Int
        do {
            parameters = try table.add(method, pattern, route: Int32(routes.count))
        } catch {
            preconditionFailure("route \(method) \(pattern): \(error)")
        }
        routes.append(RouteEntry(method: method, pattern: pattern, parameters: parameters,
                                 handler: handler))
    }

    public func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int) {
        guard let last = routes.indices.last, routes[last].pattern == pattern,
              routes[last].method == method else { return }
        routes[last].pathExtractors = pathParameters
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
    /// parameters: those are taken by position, so the extra one has nothing
    /// to take and every request to that route is a 500.
    public func problems() -> [String] {
        var found: [String] = []
        for route in routes where route.pathExtractors > route.parameters {
            found.append("\(route.method) \(route.pattern) takes \(route.pathExtractors) Path "
                         + "parameters, and its pattern has \(route.parameters)")
        }
        return found
    }

    // MARK: Compiling

    /// The routes as every connection reads them. Made once.
    func compile() -> CompiledApplication {
        if let compiledApplication { return compiledApplication }
        let compiled = CompiledApplication(table: table.compile(), routes: routes)
        compiledApplication = compiled
        return compiled
    }
}

/// A route as it is registered.
struct RouteEntry {
    var method: HTTPMethod
    var pattern: String
    /// How many parameters the pattern captures.
    var parameters: Int
    var handler: Handler
    /// How many `Path` extractors the handler takes, when it is typed.
    var pathExtractors = 0
    /// Registered through `app.heavy`.
    var heavy = false
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

    init(table: CompiledRoutes, routes: [RouteEntry]) {
        self.table = table
        routeCount = routes.count
        costs = RouteCosts(declared: routes.map(\.heavy), names: routes.map { "\($0.method) \($0.pattern)" })
        handlers = .allocate(capacity: max(1, routes.count))
        for (i, route) in routes.enumerated() { (handlers + i).initialize(to: route.handler) }
    }

    deinit {
        handlers.deinitialize(count: routeCount)
        handlers.deallocate()
        table.destroy()
    }
}
