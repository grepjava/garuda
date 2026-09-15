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

import CGaruda
import GarudaCore
import GarudaHTTP

public final class Application {
    var routes = Routes()
    var startHooks: [(Int) -> Void] = []
    var shutdownHooks: [(Int) -> Void] = []
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

    public func get(_ pattern: String, _ handler: @escaping Handler) { on(.get, pattern, handler) }
    public func head(_ pattern: String, _ handler: @escaping Handler) { on(.head, pattern, handler) }
    public func post(_ pattern: String, _ handler: @escaping Handler) { on(.post, pattern, handler) }
    public func put(_ pattern: String, _ handler: @escaping Handler) { on(.put, pattern, handler) }
    public func delete(_ pattern: String, _ handler: @escaping Handler) { on(.delete, pattern, handler) }
    public func patch(_ pattern: String, _ handler: @escaping Handler) { on(.patch, pattern, handler) }
    public func options(_ pattern: String, _ handler: @escaping Handler) { on(.options, pattern, handler) }

    /// Registers `handler` for `method` and `pattern`: literal segments,
    /// `:param` segments and a trailing `*rest`. A pattern that cannot be
    /// served, or a route added once the application has run or been tested,
    /// is a mistake in the program and stops it.
    public func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        precondition(compiled == nil, "route \(pattern) added after the application was compiled")
        routes.on(method, pattern, handler)
    }

    /// Registers an async handler, run on one of the worker's handler tasks.
    /// Internal until step 3 registers typed async handlers on it.
    func onAsync(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping AsyncHandler) {
        precondition(compiled == nil, "route \(pattern) added after the application was compiled")
        routes.on(method, pattern) { request, _ in
            request.worker.pointee.runOnTask(request.slot, handler)
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
        let count = routes.handlers.count
        let handlers = UnsafeMutablePointer<Handler>.allocate(capacity: max(1, count))
        for (i, handler) in routes.handlers.enumerated() {
            (handlers + i).initialize(to: handler)
        }
        let start = startHooks
        let shutdown = shutdownHooks
        let application = UnsafeMutablePointer<CompiledApplication>.allocate(capacity: 1)
        application.initialize(to: CompiledApplication(
            routes: routes.table.compile(),
            handlers: handlers,
            handlerCount: count,
            onStart: start.isEmpty ? nil : { index in for hook in start { hook(index) } },
            onShutdown: shutdown.isEmpty ? nil : { index in for hook in shutdown { hook(index) } }))
        compiled = application
        return application
    }
}

/// An application as a worker reads it: flat routes, handlers by route
/// number, and the hooks. Owned by its `Application`.
struct CompiledApplication {
    let routes: CompiledRoutes
    let handlers: UnsafeMutablePointer<Handler>
    let handlerCount: Int
    let onStart: ((Int) -> Void)?
    let onShutdown: ((Int) -> Void)?

    func destroy() {
        routes.destroy()
        handlers.deinitialize(count: handlerCount)
        handlers.deallocate()
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
