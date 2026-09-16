//===----------------------------------------------------------------------===//
// Typed application state: what a worker builds once, and handlers reach.
//
//     app.state { _ in try Database.connect(url: env("DATABASE_URL")) }
//     app.get("/user/:id") { (id: Path<Int>, db: State<Database>) in ... }
//
// Each worker is a process. A factory runs once in each of them, after the
// fork and before that worker reports ready, so what it builds -- a connection
// pool, a client, a cache -- belongs to that worker alone and is never shared
// across the fork. A factory that throws stops its worker's start-up with the
// error rather than serving without what it needed.
//
// State every worker must see lives outside the process: a database, a cache.
// An object captured before the fork is copied into each worker, not shared.
//===----------------------------------------------------------------------===//

import GarudaCore

/// A service the worker built at start-up, asked for by its type.
public struct State<Value>: RequestExtractor {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        guard let stored = request.worker.pointee.services[ObjectIdentifier(Value.self)],
              let value = stored as? Value else {
            // The program never registered it: that is a fault here, not the
            // client's mistake.
            throw HTTPError(.internalServerError,
                            "no \(Value.self) was registered with app.state")
        }
        return State(value)
    }
}

extension Application {
    /// Builds a value in each worker, after the fork and before that worker
    /// accepts anything, and hands it to handlers that ask for
    /// `State<Value>`. `shutdown` runs when the worker's loop has ended.
    ///
    /// One value per type: registering the same type twice replaces what the
    /// first factory would have built.
    public func state<Value>(_ make: @escaping (_ worker: Int) throws -> Value,
                             shutdown: ((Value) -> Void)? = nil) {
        precondition(compiled == nil, "state added after the application was compiled")
        let key = ObjectIdentifier(Value.self)
        stateFactories.append((key, { index in try make(index) }))
        if let shutdown {
            stateShutdowns.append((key, { stored in
                if let value = stored as? Value { shutdown(value) }
            }))
        }
    }
}

extension Worker {
    /// Runs the application's state factories for this worker. Throws what a
    /// factory throws, which stops the worker starting.
    mutating func buildState(_ application: UnsafeMutablePointer<CompiledApplication>?,
                             index: Int) throws {
        // Before the guard, and not throwing: every worker needs to know what
        // the system says about nameservers, including one with no application
        // behind it, and a machine with no resolv.conf is a machine with no
        // DNS configured rather than a reason to refuse to start. Read once
        // here because a worker is one thread and opening a file in the middle
        // of a request to answer a question about a hostname is the blocking
        // this whole layer exists to avoid.
        resolverConfig = ResolverConfig.read()
        guard let application else { return }
        for (key, make) in application.pointee.stateFactories {
            services[key] = try make(index)
        }
    }

    /// Tears down what the factories built, newest first.
    mutating func tearDownState(_ application: UnsafeMutablePointer<CompiledApplication>?) {
        if let application {
            for (key, shutdown) in application.pointee.stateShutdowns.reversed() {
                if let value = services[key] { shutdown(value) }
            }
        }
        services.removeAll()
    }
}
