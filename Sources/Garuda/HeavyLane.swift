//===----------------------------------------------------------------------===//
// The heavy lane: slow handlers never hold more than half a shard's threads.
//
// Work stealing alone lets a burst of requests that each hold the CPU for
// milliseconds take every thread, and then a quick request waits behind them
// -- what the `skew` workload measures. So each route keeps an average of how
// long its handler holds a thread, and a route whose average passes
// `ServerConfig.heavyThreshold`, or one registered through `app.heavy`, is
// heavy: its handler runs only once it holds one of the shard's heavy-lane
// permits, of which there are half as many as threads, rounded up. The other
// threads are left to everything else.
//
// "Holds a thread" is not wall time. A handler that awaits a database or a
// timer gives its thread up while it waits, and is not heavy for waiting.
// Vega's job stamp tells the two apart: a handler that finishes in the job it
// started in never suspended, and only then is its time a sample. A handler
// that computes between awaits is not seen this way; register it with
// `app.heavy`.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Synchronization
import Vega

/// What each route's handler costs, as the connections measure it.
final class RouteCosts: @unchecked Sendable {
    let count: Int
    /// Smoothed thread-hold time, in nanoseconds.
    private let average: UnsafeMutablePointer<Atomic<UInt64>>
    /// Registered through `app.heavy`.
    private let declared: [Bool]
    /// "GET /report/:id", for the log.
    private let names: [String]
    /// Past this a route is heavy. Set when serving starts.
    var thresholdNanos: UInt64 = 500_000
    /// The shard's heavy-lane permits; nil leaves every route unbounded.
    var lane: Vega.Semaphore?

    /// Heavy handlers running on each physical core, by `Runtime.currentCore`
    /// (modulo `coreSlots`): nil unless the shard's threads span two cores or
    /// more and the platform says which is which. See `claimCore`.
    private var coreLoad: UnsafeMutablePointer<Atomic<Int32>>?
    /// The cores the shard's threads run on, and the heavy handlers running.
    private var shardCores = 0
    private let heavyRunning = Atomic<Int>(0)
    private static let coreSlots = 256
    /// How many times a heavy handler moves before running where it is.
    private static let maxMoves = 8

    /// Per route: how many runs in a row were seen to finish in the job they
    /// started in, up to `steadyRuns`, or `suspends` once one did not.
    private let quiet: UnsafeMutablePointer<Atomic<UInt8>>
    private static let steadyRuns: UInt8 = 16
    private static let suspends: UInt8 = 255

    init(declared: [Bool], names: [String] = []) {
        count = declared.count
        self.declared = declared
        self.names = names
        average = .allocate(capacity: max(1, count))
        for i in 0..<max(1, count) { (average + i).initialize(to: Atomic(0)) }
        quiet = .allocate(capacity: max(1, count))
        for i in 0..<max(1, count) { (quiet + i).initialize(to: Atomic(0)) }
    }

    deinit {
        if let coreLoad {
            coreLoad.deinitialize(count: Self.coreSlots)
            coreLoad.deallocate()
        }
        average.deinitialize(count: max(1, count))
        average.deallocate()
        quiet.deinitialize(count: max(1, count))
        quiet.deallocate()
    }

    /// Whether route `index` has run often enough without ever suspending to
    /// be run where its request arrived, on the task that read it -- an
    /// HTTP/2 stream on its connection's reader (HTTP2.swift) -- rather than
    /// handed to a task of its own.
    @inline(__always)
    func neverSuspends(_ index: Int) -> Bool {
        let n = quiet[index].load(ordering: .relaxed)
        return n >= RouteCosts.steadyRuns && n != RouteCosts.suspends
    }

    /// Notes whether a run of route `index`, middleware and all, suspended:
    /// `stamp` is the job it started in. Off a Vega worker nothing can be
    /// told, and nothing is noted. One run that suspends is enough for good.
    @inline(__always)
    func noteRun(_ index: Int, startedIn stamp: JobStamp) {
        guard stamp != .none else { return }
        let n = quiet[index].load(ordering: .relaxed)
        if n == RouteCosts.suspends { return }
        if Runtime.currentJobStamp != stamp {
            quiet[index].store(RouteCosts.suspends, ordering: .relaxed)
        } else if n < RouteCosts.steadyRuns {
            quiet[index].store(n &+ 1, ordering: .relaxed)
        }
    }

    /// Notes that route `index` waits, whatever its runs have shown: it
    /// streams its answer.
    func markSuspends(_ index: Int) {
        quiet[index].store(RouteCosts.suspends, ordering: .relaxed)
    }

    /// Whether route `index` runs in the heavy lane.
    @inline(__always)
    func isHeavy(_ index: Int) -> Bool {
        declared[index] || average[index].load(ordering: .relaxed) > thresholdNanos
    }

    /// Readies the lane for a shard of `threads` threads on `cores` physical
    /// cores (0: not known).
    func configure(_ config: ServerConfig, threads: Int, cores: Int = 0) {
        let (seconds, attos) = config.heavyThreshold.components
        thresholdNanos = UInt64(max(0, seconds)) &* 1_000_000_000 &+ UInt64(max(0, attos) / 1_000_000_000)
        lane = config.heavyLane ? Vega.Semaphore(permits: max(1, (threads + 1) / 2)) : nil
        if lane != nil, cores > 1, coreLoad == nil {
            shardCores = cores
            let load = UnsafeMutablePointer<Atomic<Int32>>.allocate(capacity: Self.coreSlots)
            for i in 0..<Self.coreSlots { (load + i).initialize(to: Atomic(0)) }
            coreLoad = load
        }
    }

    /// With a lane permit held, before a heavy handler runs: spreads heavy
    /// handlers over the shard's physical cores. Two on the hyperthreads of
    /// one core run at about half speed each, and leave the quick requests
    /// one core fewer than one on each core does: on the `skew` workload,
    /// 84k quick requests a second against 120k. So while a heavy handler
    /// already runs on the caller's core and some core runs none, the caller
    /// moves to whichever worker is free next, a few times at most; then it
    /// is counted on the core it is on. The permit's next waiter resumes
    /// where the permit was released, on a core `releaseCore` has just
    /// freed, so once spread they stay spread without moving again.
    /// Returns the slot to release, or -1.
    func claimCore() async -> Int {
        guard let load = coreLoad else { return -1 }
        var moves = 0
        while true {
            guard let core = Runtime.currentCore else { return -1 }
            let slot = core % Self.coreSlots
            if moves == Self.maxMoves || load[slot].load(ordering: .relaxed) == 0
                || heavyRunning.load(ordering: .relaxed) >= shardCores {
                load[slot].add(1, ordering: .relaxed)
                heavyRunning.add(1, ordering: .relaxed)
                return slot
            }
            moves += 1
            await Runtime.yieldToAnyWorker()
        }
    }

    /// The heavy handler counted by `claimCore` on `slot` is done.
    func releaseCore(_ slot: Int) {
        guard slot >= 0, let load = coreLoad else { return }
        load[slot].subtract(1, ordering: .relaxed)
        heavyRunning.subtract(1, ordering: .relaxed)
    }

    /// The smoothed thread-hold time of route `index`.
    func averageNanos(_ index: Int) -> UInt64 {
        average[index].load(ordering: .relaxed)
    }

    /// Whether to time this run of route `index`. Heavy routes are timed
    /// every run, so one that turns quick again leaves the lane promptly;
    /// light ones one run in sixteen, so a route every thread serves is not
    /// a cache line every thread writes.
    @inline(__always)
    func shouldSample(_ index: Int, heavy: Bool, now: UInt64) -> Bool {
        heavy || now & 15 == 0 || average[index].load(ordering: .relaxed) == 0
    }

    /// Folds one run's thread-hold time into route `index`'s average, an
    /// eighth at a time. Concurrent updates may lose one another: the average
    /// is a hint, and a lost sample changes nothing that matters.
    func record(_ index: Int, nanos: UInt64) {
        let sample = max(1, nanos)
        let old = average[index].load(ordering: .relaxed)
        let new = old == 0 ? sample : old - old / 8 + sample / 8
        guard new != old else { return }
        average[index].store(new, ordering: .relaxed)
        if (old > thresholdNanos) != (new > thresholdNanos), !declared[index] {
            Log.debug("\(index < names.count ? names[index] : "route \(index)") \(new > thresholdNanos ? "enters" : "leaves") the heavy lane: \(new / 1000) us average, last run \(nanos / 1000) us")
        }
    }
}

/// Now, in nanoseconds, from the monotonic clock: what the lane times with.
@inline(__always)
func monotonicNanos() -> UInt64 {
    #if canImport(Glibc) || canImport(Darwin)
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    #else
    let (seconds, attos) = clockOrigin.duration(to: .now).components
    return UInt64(seconds) &* 1_000_000_000 &+ UInt64(attos / 1_000_000_000)
    #endif
}

#if !(canImport(Glibc) || canImport(Darwin))
/// Where `monotonicNanos` counts from without clock_gettime.
let clockOrigin = ContinuousClock.now
#endif

/// Now, in microseconds since the epoch, from the wall clock: what
/// --request-start-header stamps a request with, for an agent to set against
/// its own clock.
func wallClockMicros() -> UInt64 {
    var ts = timespec()
    #if canImport(Glibc) || canImport(Darwin)
    clock_gettime(CLOCK_REALTIME, &ts)
    #else
    timespec_get(&ts, TIME_UTC)
    #endif
    return UInt64(ts.tv_sec) &* 1_000_000 &+ UInt64(ts.tv_nsec) / 1000
}

// MARK: - Declaring heavy routes

extension Application {
    /// Routes registered through this run in the heavy lane from the first
    /// request, whatever they are measured to cost:
    ///
    /// ```
    /// app.heavy.get("/report/:id") { (id: Path<Int>) in JSON(try render(id.value)) }
    /// ```
    ///
    /// For a handler that computes between awaits, which measuring cannot
    /// see; one that computes without awaiting is found by itself.
    public var heavy: some RouteBuilder { HeavyRoutes(self) }
}

/// The routes `app.heavy` registers.
final class HeavyRoutes: RouteBuilder {
    let application: Application

    init(_ application: Application) {
        self.application = application
    }

    func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        application.on(method, pattern, handler)
        application.routes[application.routes.count - 1].heavy = true
    }

    func fallback(_ handler: @escaping Handler) {
        application.fallback(handler)
        application.fallbacks[application.fallbacks.count - 1].heavy = true
    }

    func noteRoute(_ method: HTTPMethod, _ pattern: String, pathParameters: Int, states: [Any.Type]) {
        application.noteRoute(method, pattern, pathParameters: pathParameters, states: states)
    }

    func document(_ operation: OpenAPIOperation) {
        application.document(operation)
    }

    func describeRoutes(_ note: @escaping OperationNote) {
        application.describeRoutes(note)
    }

    func use(_ middleware: some Middleware) {
        application.use(middleware)
    }

    func group(_ prefix: String, _ register: () -> Void) {
        application.group(prefix, register)
    }
}
