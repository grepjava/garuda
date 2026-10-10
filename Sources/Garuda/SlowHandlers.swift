//===----------------------------------------------------------------------===//
// Handlers that hold their worker.
//
// A worker is one thread, so while a handler computes without waiting, every
// other request on the worker waits for it. --slow-handler-ms (100 by
// default) names how long is too long, and a handler past it is warned about
// with its route, at most once every ten seconds, and counted on the metrics
// page by route.
//
// Two places find them. An async handler runs on a task, in jobs the worker's
// LoopExecutor times; one that ran long is traced back by the task's address
// to the route it was serving (HandlerTasks.swift). A synchronous handler runs
// inline, outside the executor, and is timed only where the time is already
// taken: with --metrics-port, the time from dispatch to the response head is,
// for a handler that answers inline, the time it held the worker. Timing it
// otherwise would put two clock reads on the fastest path there is.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

extension Worker {
    /// At most one warning this often, however many handlers run long.
    static let slowWarningIntervalMs: UInt64 = 10_000

    /// A handler of route `route` -- nil when the job was not a handler's --
    /// held the worker for `micros` without waiting. Counted against the
    /// route, and warned about unless another warning went out lately.
    mutating func handlerHeldTheWorker(route: Int32?, micros: UInt64) {
        if let route {
            RouteMetrics.slowRun(application, slot: busSlot, route: Int(route), micros: micros)
        }
        let now = av_monotonic_ms()
        guard slowWarnedAt == 0 || now &- slowWarnedAt >= Worker.slowWarningIntervalMs else {
            slowUnwarned += 1
            return
        }
        slowWarnedAt = now
        let more = slowUnwarned
        slowUnwarned = 0
        let label = route.flatMap { application?.pointee.routeLabel(Int($0)) }
        Log.warn { line in
            line.str(label == nil ? "a task" : "a handler")
            line.str(" held its worker for ")
            line.int(Int(micros / 1000))
            line.str(" ms without waiting")
            if var label {
                line.str(" (")
                label.withUTF8 { line.bytes($0.baseAddress!, $0.count) }
                line.str(")")
            }
            line.str("; every other request on the worker waited. Move CPU-heavy work into blocking { }, or raise --slow-handler-ms")
            if more > 0 {
                line.str(" [")
                line.int(more)
                line.str(" more since the last warning]")
            }
        }
    }
}

extension CompiledApplication {
    /// How a log line names route `route`: its method and pattern, or nil
    /// for none.
    func routeLabel(_ route: Int) -> String? {
        guard route >= 0, route < routePatterns.count else { return nil }
        let method = route < routeMethods.count ? routeMethods[route]?.token.map { "\($0)" } : nil
        return "\(method ?? "*") \(routePatterns[route] ?? "fallback")"
    }
}
