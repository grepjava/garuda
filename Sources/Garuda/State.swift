//===----------------------------------------------------------------------===//
// Shard state and lifecycle: what each shard builds before it serves, and
// what it does when it stops.
//
//     app.state { shard in try await PostgresPool.connect(url) }
//     app.onShardStart { start in
//         try await start.state(PostgresPool.self).migrate(migrations)
//     }
//     app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) in … }
//
// A shard is a process. Its state is built in it, after it starts and before
// it accepts anything, so a pool, a client or a cache belongs to that shard
// alone; every thread of the shard shares it, which is why it is Sendable.
// What every shard must see lives outside the processes, in a database, or in
// a shared region (Vega's ShardOptions.sharedRegions).
//
// A factory or a start hook that throws stops the shard's start-up: it exits
// rather than serve without what it needs, and the supervisor tries again.
//
// Once built, the state is only read. A handler's lookup scans a short flat
// table by type: no lock, no dictionary, nothing counted.
//===----------------------------------------------------------------------===//

/// The shard a factory or hook runs in.
public struct ShardInfo: Sendable {
    /// 0 for the first shard, and so on; 0 when serving in one process.
    public let index: Int
    /// How many shards the server has.
    public let count: Int
    /// The shard's worker threads.
    public let threads: Int

    public init(index: Int, count: Int, threads: Int) {
        self.index = index
        self.count = count
        self.threads = threads
    }
}

/// What a start or stop hook is handed: the shard, and its state.
public struct ShardContext: Sendable {
    public let shard: ShardInfo
    let services: ServiceTable

    /// What `app.state` built for `Value` in this shard.
    public func state<Value>(_ type: Value.Type) throws(HTTPError) -> Value {
        guard let value = services.find(Value.self) else { throw missingState(Value.self) }
        return value
    }
}

// MARK: - Registering

extension Application {
    /// Builds a value in each shard, before it accepts anything, for handlers
    /// that ask for `State<Value>` and middleware that calls `request.state`.
    /// Factories run in the order registered, so one may read what an earlier
    /// one built through `start.state`. `shutdown` runs when the shard has
    /// stopped serving, newest first.
    ///
    /// One value per type: registering a type twice is a mistake, and stops
    /// the program.
    public func state<Value: Sendable>(
        _ make: @escaping @Sendable (_ start: ShardContext) async throws -> Value,
        shutdown: (@Sendable (Value) async -> Void)? = nil
    ) {
        precondition(compiledApplication == nil, "state added after the application was compiled")
        let key = ObjectIdentifier(Value.self)
        precondition(!stateFactories.contains { $0.key == key },
                     "app.state registered \(Value.self) twice; one type is one value")
        var stop: (@Sendable (any Sendable) async -> Void)?
        if let shutdown {
            stop = { stored in
                if let value = stored as? Value { await shutdown(value) }
            }
        }
        let build: @Sendable (ShardContext) async throws -> any Sendable = { start in try await make(start) }
        stateFactories.append(StateFactory(key: key, name: "\(Value.self)", make: build, shutdown: stop))
    }

    /// Runs in each shard once its state is built and before it accepts a
    /// connection: a schema to migrate, a cache to warm. Hooks run in the
    /// order added; one that throws stops the shard.
    public func onShardStart(_ hook: @escaping @Sendable (_ start: ShardContext) async throws -> Void) {
        precondition(compiledApplication == nil, "hook added after the application was compiled")
        startHooks.append(hook)
    }

    /// Runs in each shard when it has stopped serving -- the requests in
    /// progress answered -- and before its state is shut down. Hooks run in
    /// the reverse of the order added.
    public func onShardStop(_ hook: @escaping @Sendable (_ stop: ShardContext) async -> Void) {
        precondition(compiledApplication == nil, "hook added after the application was compiled")
        stopHooks.append(hook)
    }
}

/// One `app.state` registration.
struct StateFactory: Sendable {
    let key: ObjectIdentifier
    let name: String
    let make: @Sendable (ShardContext) async throws -> any Sendable
    let shutdown: (@Sendable (any Sendable) async -> Void)?
}

// MARK: - Building and finding

/// A shard's state by type: written while the shard starts, only read after.
final class ServiceTable: @unchecked Sendable {
    private var keys: UnsafeMutablePointer<ObjectIdentifier>
    private var values: UnsafeMutablePointer<any Sendable>
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        keys = .allocate(capacity: self.capacity)
        values = .allocate(capacity: self.capacity)
    }

    deinit {
        values.deinitialize(count: count)
        values.deallocate()
        keys.deallocate()
    }

    /// Adds a value. Only while the shard starts, from one task.
    func add(_ key: ObjectIdentifier, _ value: any Sendable) {
        precondition(count < capacity, "more state than was registered")
        (keys + count).initialize(to: key)
        (values + count).initialize(to: value)
        count += 1
    }

    @inline(__always)
    func find<Value>(_ type: Value.Type) -> Value? {
        let key = ObjectIdentifier(type)
        var i = 0
        while i < count {
            if keys[i] == key { return values[i] as? Value }
            i &+= 1
        }
        return nil
    }

    func value(at index: Int) -> (ObjectIdentifier, any Sendable) {
        (keys[index], values[index])
    }
}

extension CompiledApplication {
    /// Builds the state and runs the start hooks, in this shard. Throws what
    /// a factory or hook throws.
    func startShard(_ shard: ShardInfo) async throws {
        let context = ShardContext(shard: shard, services: services)
        startTracing()
        for factory in stateFactories {
            do {
                services.add(factory.key, try await factory.make(context))
            } catch {
                throw ShardStartError(what: "app.state for \(factory.name)", error: error)
            }
        }
        for (i, hook) in startHooks.enumerated() {
            do {
                try await hook(context)
            } catch {
                throw ShardStartError(what: "onShardStart hook \(i + 1)", error: error)
            }
        }
        makeShardTracer(shard)
        startScheduledJobs(context)
    }

    /// Runs the stop hooks, then shuts the state down, newest first.
    func stopShard(_ shard: ShardInfo) async {
        let context = ShardContext(shard: shard, services: services)
        await stopScheduledJobs()
        for hook in stopHooks.reversed() { await hook(context) }
        for i in stride(from: services.count - 1, through: 0, by: -1) {
            let (key, value) = services.value(at: i)
            if let factory = stateFactories.first(where: { $0.key == key }), let shutdown = factory.shutdown {
                await shutdown(value)
            }
        }
    }
}

/// A shard that could not start, and why.
struct ShardStartError: Error, CustomStringConvertible {
    let what: String
    let error: any Error
    var description: String { "\(what) failed: \(error)" }
}

func missingState(_ type: Any.Type) -> HTTPError {
    // The program never registered it: a fault here, not the client's.
    HTTPError(.internalServerError, "no \(type) was registered with app.state")
}

// MARK: - Reaching it from a request

/// A value the shard built at start-up, asked for by its type:
///
///     app.get("/user/:id") { (id: Path<Int>, db: State<Database>) in … }
///
/// A route asking for a type no `app.state` builds is found by `problems()`,
/// before the server starts.
public struct State<Value: Sendable>: RequestExtractor, Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Self {
        State(try request.state(Value.self))
    }
}

/// An extractor that needs something `app.state` builds, so that a route
/// asking for what nothing registers is found before the server starts.
///
/// `State<T>?` does not conform: an optional extractor is nil where the one
/// it wraps would have refused, which is a route saying it can do without.
protocol StateRequiring {
    static var requiredStateType: Any.Type { get }
}

extension State: StateRequiring {
    static var requiredStateType: Any.Type { Value.self }
}

/// The state type `E` requires, if any.
@usableFromInline
func requiredState<E: RequestExtractor>(_ type: E.Type) -> [Any.Type] {
    (type as? any StateRequiring.Type).map { [$0.requiredStateType] } ?? []
}

extension Request {
    /// What `app.state` built for `Value` in this shard: for middleware,
    /// which takes no extractors.
    public func state<Value>(_ type: Value.Type) throws(HTTPError) -> Value {
        guard let app = exchange.pointee.application,
              let value = app._withUnsafeGuaranteedRef({ $0.services.find(Value.self) }) else {
            throw missingState(Value.self)
        }
        return value
    }
}
