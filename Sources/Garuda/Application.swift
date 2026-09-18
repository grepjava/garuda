//===----------------------------------------------------------------------===//
// Application: the routes and hooks a program serves, and how it is run.
//
// An application is built up before it runs. Running it compiles the routes
// into flat memory, before the first fork, so that every worker process reads
// the same table without owning a copy; then it parses the command line, or
// takes a configuration, and runs the supervisor. `test` serves the same
// compiled routes from a worker in this process, with no socket bound, which
// is what lets a test suite run an application, or several, without starting
// a server.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CAvian
import AvianCore
import AvianHTTP

public final class Application: RouteBuilder {
    var routes = Routes()
    var startHooks: [(Int) -> Void] = []
    var prepareHooks: [(timeout: UInt64, hook: @Sendable (WorkerStartup) async throws -> Void)] = []
    var shutdownHooks: [(Int) -> Void] = []
    var responseObservers: [(CompletedRequest) -> Void] = []
    var trailingSlashPolicy = TrailingSlash.strict
    /// The OpenAPI documents `openAPI` serves, written when the application compiles.
    var openAPIDocuments: [OpenAPIDocumentBox] = []
    /// What each worker builds for itself at start-up, by the type handlers
    /// ask for it by, and how to tear it down (State.swift).
    var stateFactories: [(ObjectIdentifier, (Int) throws -> Any)] = []
    var stateShutdowns: [(ObjectIdentifier, (Any) -> Void)] = []
    /// The routes and hooks as workers read them, made the first time the
    /// application runs or is tested. Nothing can be added after that.
    var compiled: UnsafeMutablePointer<CompiledApplication>? = nil

    public init() {}

    deinit {
        if let compiled {
            compiled.pointee.destroy()
            compiled.deinitialize(count: 1)
            compiled.deallocate()
        }
    }

    // MARK: Routes

    /// Registers `handler` for `method` and `pattern`: literal segments,
    /// `:param` segments and a trailing `*rest`. A pattern that cannot be
    /// served, or a route added once the application has run or been tested,
    /// is a mistake in the program and stops it.
    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        precondition(compiled == nil, "route \(pattern) added after the application was compiled")
        routes.on(method, pattern, handler)
    }

    /// Registers an async handler, run on one of the worker's handler tasks.
    /// An `await` resumes on the worker's own thread, so the handler sees the
    /// same request and response a synchronous one does.
    public func onAsync(_ method: HTTPMethod, _ pattern: String, _ handler: sending @escaping AsyncHandler) {
        precondition(compiled == nil, "route \(pattern) added after the application was compiled")
        routes.onAsync(method, pattern, handler)
    }

    /// Gives every route registered inside `register` a deadline: a request
    /// still unanswered `milliseconds` after it was dispatched is answered
    /// 504, and a handler waiting on the engine for it is unwound.
    ///
    ///     app.deadline(milliseconds: 500) {
    ///         app.get("/report") { … }
    ///     }
    ///
    /// A deadline bounds **waiting, not computing**. A worker is one thread,
    /// so nothing can preempt a handler that loops without awaiting: that
    /// handler still stops its worker, deadline or no. What this covers is a
    /// handler waiting on something that never comes back.
    ///
    /// Nested calls apply the innermost deadline, and restore the outer one
    /// afterwards.
    public func deadline(milliseconds: UInt32, _ register: () -> Void) {
        precondition(compiled == nil, "deadline added after the application was compiled")
        let previous = routes.currentDeadline
        routes.currentDeadline = milliseconds
        defer { routes.currentDeadline = previous }
        register()
    }

    // MARK: Groups and middleware

    /// Mounts every route registered inside `register` under `prefix`, and
    /// scopes any `use` called inside it to those routes.
    ///
    ///     app.group("/api") {
    ///         app.use(requireToken)
    ///         app.get("/users/:id") { … }        // GET /api/users/:id
    ///         app.group("/admin") {
    ///             app.use(requireAdmin)
    ///             app.delete("/users/:id") { … } // DELETE /api/admin/users/:id,
    ///         }                                   // requireToken, then requireAdmin
    ///     }
    ///
    /// Groups nest; prefixes join and middleware runs from the outside in.
    public func group(_ prefix: String, _ register: () -> Void) {
        precondition(compiled == nil, "group added after the application was compiled")
        precondition(prefix.hasPrefix("/"), "a group prefix starts with /: \(prefix)")
        var trimmed = prefix
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        routes.groups.append((prefix: trimmed == "/" ? "" : trimmed, middleware: []))
        routes.openGroups.append(routes.groups.count - 1)
        defer { routes.openGroups.removeLast() }
        register()
    }

    /// Runs `middleware` before the handler of every route in the current
    /// scope: every route, outside a group, or every route in the group this
    /// is called inside.
    ///
    /// Order of registration does not matter: a `use` after the routes it
    /// covers applies to them as surely as one before. What does matter is
    /// the order of `use` calls within a scope, which is the order they run.
    public func use(_ middleware: @escaping Middleware) {
        use(step: .sync(middleware))
    }

    /// Runs an async `middleware` before the handler of every route in the
    /// current scope, as `use` does. A closure that does not await is not
    /// async, and takes the synchronous `use`.
    ///
    ///     app.use { request, _ async throws -> (any ResponseConvertible)? in
    ///         guard let token = request.header("authorization"),
    ///               let user = try await sessions.user(token) else {
    ///             return HTTPStatus.unauthorized
    ///         }
    ///         request[context: CurrentUser.self] = user
    ///         return nil
    ///     }
    public func use(_ middleware: sending @escaping AsyncMiddleware) {
        use(step: .async(middleware))
    }

    private func use(step: MiddlewareStep) {
        precondition(compiled == nil, "middleware added after the application was compiled")
        if let group = routes.openGroups.last {
            routes.groups[group].middleware.append(step)
        } else {
            routes.global.append(step)
        }
    }

    // MARK: Worker hooks

    /// Runs in each worker process before it accepts a connection -- a
    /// replacement worker is not handed its slot until every hook has
    /// returned -- with the worker's index. Hooks run in the order added.
    public func onWorkerStart(_ hook: @escaping (_ worker: Int) -> Void) {
        precondition(compiled == nil, "hook added after the application was compiled")
        startHooks.append(hook)
    }

    /// Runs in each worker before it accepts anything, with the worker's
    /// index, and may await: a schema to migrate, a cache to warm, a secret to
    /// fetch. Hooks run in the order they were added.
    ///
    /// ```
    /// app.state { _ in PostgresPool(configuration) }
    /// app.prepare { start in
    ///     try await start.state(PostgresPool.self).migrate(migrations)
    /// }
    /// ```
    ///
    /// The worker's state is built first, and its listening socket is
    /// registered only once every hook has returned, so a connection that
    /// arrives meanwhile waits in the backlog rather than reaching a worker
    /// that is not ready. A hook that throws or outstays
    /// `timeoutMilliseconds` stops the worker, which the supervisor reports as
    /// a worker that would not start.
    public func prepare(timeoutMilliseconds: UInt64 = 30_000,
                        _ hook: @escaping @Sendable (_ start: WorkerStartup) async throws -> Void) {
        precondition(compiled == nil, "a prepare hook added after the application was compiled")
        precondition(timeoutMilliseconds > 0, "a prepare hook needs time to run in")
        prepareHooks.append((timeoutMilliseconds, hook))
    }

    /// Runs in each worker process once its in-flight requests have finished
    /// or --graceful-timeout has run out, with the worker's index.
    public func onWorkerShutdown(_ hook: @escaping (_ worker: Int) -> Void) {
        precondition(compiled == nil, "hook added after the application was compiled")
        shutdownHooks.append(hook)
    }

    // MARK: Running

    /// Parses the process's command line as the `garuda` executable does,
    /// then serves until shut down. Returns the process exit status.
    public func run() -> Int32 {
        switch GarudaCLI.parse(argc: Int(CommandLine.argc), argv: CommandLine.unsafeArgv) {
        case .exit(let status):
            return status
        case .run(let config):
            return serve(config)
        }
    }

    /// Parses `arguments` as the `garuda` executable parses its command line,
    /// then serves. For an application with commands of its own:
    ///
    /// ```
    /// // starter serve -- --port 8080 --workers 4
    /// case "serve":
    ///     var mine = Array(CommandLine.arguments.dropFirst(2))
    ///     if mine.first == "--" { mine.removeFirst() }
    ///     exit(app.run(arguments: mine))
    /// ```
    ///
    /// `arguments` holds the flags only, without the program name. An
    /// unknown flag prints the usage and returns 2, as it does for `garuda`.
    public func run(arguments: [String]) -> Int32 {
        var storage = (["garuda"] + arguments).map { strdup($0) }
        defer { for pointer in storage { free(pointer) } }
        storage.append(nil)
        return storage.withUnsafeMutableBufferPointer { argv -> Int32 in
            switch GarudaCLI.parse(argc: argv.count - 1, argv: argv.baseAddress!) {
            case .exit(let status):
                return status
            case .run(let config):
                return serve(config)
            }
        }
    }

    /// Serves with `configuration` instead of the command line. It is checked
    /// and completed the way the command line's is: certificate pairs, the
    /// https scheme on a TLS listener, Alt-Svc for HTTP/3 and the port string
    /// are derived from it, and a mistake is reported and returns status 2.
    /// Strings in a `ServerConfig` must outlive the server; `ServerConfig.string`
    /// makes one that does.
    public func run(configuration: ServerConfig) -> Int32 {
        var config = configuration
        var inputs = GarudaCLI.ConfigurationInputs()
        if let cert = config.tlsCertPath, let key = config.tlsKeyPath {
            inputs.tlsCerts = [cert] + config.tlsExtraCerts.map { $0.cert }
            inputs.tlsKeys = [key] + config.tlsExtraCerts.map { $0.key }
        }
        inputs.staticRoutes = config.staticRoutes
        inputs.schemeGiven = strcmp(config.scheme, "http") != 0
        if let status = GarudaCLI.finish(&config, inputs) {
            return status
        }
        return serve(config)
    }

    func serve(_ config: ServerConfig) -> Int32 {
        GarudaRuntime.application = compile()
        defer { GarudaRuntime.application = nil }
        return GarudaRuntime.run(config: config)
    }

    // MARK: Testing

    /// A client for this application's routes, served from a worker in this
    /// process with a configuration for tests. Each use makes a new one.
    public var test: TestClient {
        var config = ServerConfig()
        config.maxConnections = 16
        return TestClient(application: self, configuration: config)
    }

    /// A client for this application's routes with `configuration`, for a
    /// test of a server feature: --request-id, --root-path and the like.
    public func testClient(configuration: ServerConfig) -> TestClient {
        TestClient(application: self, configuration: configuration)
    }

    // MARK: Compiling

    func compile() -> UnsafeMutablePointer<CompiledApplication> {
        if let compiled { return compiled }
        for box in openAPIDocuments {
            box.json = Array(writeOpenAPIJSON(routes.openAPIDocument(box.info), indent: true).utf8)
        }
        let count = routes.handlers.count
        let handlers = UnsafeMutablePointer<Handler>.allocate(capacity: max(1, count))
        for (i, handler) in routes.handlersWithMiddleware().enumerated() {
            (handlers + i).initialize(to: handler)
        }
        let deadlines = UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, count))
        for (i, allowed) in routes.deadlines.enumerated() {
            (deadlines + i).initialize(to: allowed)
        }
        let bodyLimits = UnsafeMutablePointer<Int>.allocate(capacity: max(1, count))
        for (i, limit) in routes.bodyLimits.enumerated() {
            (bodyLimits + i).initialize(to: limit)
        }
        let wholeBodyLimits = UnsafeMutablePointer<Int>.allocate(capacity: max(1, count))
        for (i, limit) in routes.wholeBodyLimits.enumerated() {
            (wholeBodyLimits + i).initialize(to: limit)
        }
        let start = startHooks
        let prepare = prepareHooks
        let shutdown = shutdownHooks
        let observers = responseObservers
        let application = UnsafeMutablePointer<CompiledApplication>.allocate(capacity: 1)
        application.initialize(to: CompiledApplication(
            routes: routes.table.compile(),
            handlers: handlers,
            deadlines: deadlines,
            bodyLimits: bodyLimits,
            wholeBodyLimits: wholeBodyLimits,
            streamsBodies: routes.bodyLimits.contains { $0 >= 0 }
                || routes.wholeBodyLimits.contains { $0 >= 0 },
            fallbacks: CompiledFallbacks(routes.fallbacks),
            corsPolicies: (0..<count).map { routes.corsPolicy($0) },
            hasCORS: routes.cors != nil || !routes.groupCORS.isEmpty,
            handlerCount: count,
            stateFactories: stateFactories,
            stateShutdowns: stateShutdowns,
            onPrepare: prepare.isEmpty ? nil : { @Sendable start in
                for entry in prepare { try await entry.hook(start) }
            },
            prepareTimeoutMilliseconds: prepare.reduce(0) { $0 + $1.timeout },
            onStart: start.isEmpty ? nil : { index in for hook in start { hook(index) } },
            onShutdown: shutdown.isEmpty ? nil : { index in for hook in shutdown { hook(index) } },
            routePatterns: routes.patterns,
            routeMethods: routes.methods,
            trailingSlash: trailingSlashPolicy,
            onResponse: observers.isEmpty ? nil : { completed in for observe in observers { observe(completed) } }))
        compiled = application
        return application
    }
}

/// An application as a worker reads it: flat routes, handlers by route
/// number, and the hooks. Owned by its `Application`.
struct CompiledApplication {
    let routes: CompiledRoutes
    let handlers: UnsafeMutablePointer<Handler>
    /// Milliseconds each route is allowed, by route number, 0 for none.
    let deadlines: UnsafeMutablePointer<UInt32>
    /// Each route's streamed body limit, -1 for a route given its body whole.
    let bodyLimits: UnsafeMutablePointer<Int>
    /// Each whole-body route's own limit, -1 for `--max-body`.
    let wholeBodyLimits: UnsafeMutablePointer<Int>
    /// Whether any route streams its body or has a limit of its own, so a
    /// request with a body is matched at its head only when one might.
    let streamsBodies: Bool
    /// Each scope's fallback, for a request no route matches.
    let fallbacks: CompiledFallbacks
    /// Each route's CORS policy, by route number, for a preflight to a path
    /// routed only for other methods.
    let corsPolicies: [CORSPolicy?]
    let hasCORS: Bool
    let handlerCount: Int
    let stateFactories: [(ObjectIdentifier, (Int) throws -> Any)]
    let stateShutdowns: [(ObjectIdentifier, (Any) -> Void)]
    /// Async start-up work, run before the worker accepts anything.
    let onPrepare: (@Sendable (WorkerStartup) async throws -> Void)?
    /// How long every prepare hook together may take.
    let prepareTimeoutMilliseconds: UInt64
    let onStart: ((Int) -> Void)?
    let onShutdown: ((Int) -> Void)?
    /// Each route's pattern, by route number, nil for a fallback.
    let routePatterns: [String?]
    /// Each route's method, nil for a fallback, for metrics by route.
    let routeMethods: [HTTPMethod?]
    /// What a path with a trailing slash no route has gets.
    let trailingSlash: TrailingSlash
    /// Every `onResponse` observer, in order, or nil for none.
    let onResponse: ((CompletedRequest) -> Void)?

    func destroy() {
        routes.destroy()
        handlers.deinitialize(count: handlerCount)
        handlers.deallocate()
        deadlines.deinitialize(count: handlerCount)
        deadlines.deallocate()
        bodyLimits.deinitialize(count: handlerCount)
        bodyLimits.deallocate()
        wholeBodyLimits.deinitialize(count: handlerCount)
        wholeBodyLimits.deallocate()
    }
}

extension GarudaRuntime {
    /// The application this process serves, set by `Application.run` before
    /// the supervisor starts, so that every worker forked from it serves the
    /// same compiled routes. A test client does not use it.
    nonisolated(unsafe) static var application: UnsafeMutablePointer<CompiledApplication>? = nil
}

extension ServerConfig {
    /// A C string for a configuration field, kept for the life of the process
    /// the way `argv` is.
    public static func string(_ value: String) -> UnsafePointer<CChar> {
        UnsafePointer(strdup(value)!)
    }
}
