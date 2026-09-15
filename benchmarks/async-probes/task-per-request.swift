// What an async handler costs on an executor owned by the worker loop, next to
// a synchronous call. Three shapes, one million requests each:
//   sync        a plain call
//   immediate   Task.immediate on the loop executor, no suspension
//   suspending  Task.immediate that awaits a continuation the loop resumes
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Jobs run on the thread that drains, in the order they were enqueued.
final class LoopExecutor: TaskExecutor, @unchecked Sendable {
    var jobs: [UnownedJob] = []
    var head = 0

    func enqueue(_ job: consuming ExecutorJob) {
        jobs.append(UnownedJob(job))
    }

    func drain() {
        while head < jobs.count {
            let job = jobs[head]
            head += 1
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
        jobs.removeAll(keepingCapacity: true)
        head = 0
    }
}

nonisolated(unsafe) var total = 0
nonisolated(unsafe) var parked: UnsafeContinuation<Int, Never>? = nil

@inline(never) func syncHandler(_ x: Int) -> Int { x &+ 1 }
@inline(never) func asyncHandler(_ x: Int) async -> Int { x &+ 1 }
@inline(never) func waitingHandler(_ x: Int) async -> Int {
    let y = await withUnsafeContinuation { parked = $0 }
    return x &+ y
}

func nanos() -> UInt64 {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

/// malloc calls so far, from malloc-counter.c under LD_PRELOAD; 0 without it.
let mallocCount: @convention(c) () -> Int = {
    // RTLD_DEFAULT is a null handle on glibc.
    guard let symbol = dlsym(nil, "probe_malloc_count") else {
        return { 0 }
    }
    return unsafeBitCast(symbol, to: (@convention(c) () -> Int).self)
}()

@main
struct Probe {
    static func main() {
        let n = 1_000_000
        let loop = LoopExecutor()
        loop.jobs.reserveCapacity(64)
        for round in 1...3 {
            var mallocs = mallocCount()
            var start = nanos()
            for i in 0..<n { total &+= syncHandler(i) }
            let sync = Double(nanos() - start) / Double(n)
            let syncMallocs = Double(mallocCount() - mallocs) / Double(n)

            mallocs = mallocCount()
            start = nanos()
            for i in 0..<n {
                Task.immediate(executorPreference: loop) { total &+= await asyncHandler(i) }
                loop.drain()
            }
            let immediate = Double(nanos() - start) / Double(n)
            let immediateMallocs = Double(mallocCount() - mallocs) / Double(n)

            mallocs = mallocCount()
            start = nanos()
            var ranInline = 0
            for i in 0..<n {
                Task.immediate(executorPreference: loop) { total &+= await waitingHandler(i) }
                // Reached its first await without the loop running it?
                if parked != nil { ranInline += 1 } else { loop.drain() }
                guard let c = parked else {
                    print("the handler never reached its await")
                    return
                }
                parked = nil
                c.resume(returning: 1)
                loop.drain()
            }
            let suspending = Double(nanos() - start) / Double(n)
            let suspendingMallocs = Double(mallocCount() - mallocs) / Double(n)

            print("round \(round): sync \(String(format2: sync)) ns \(String(format2: syncMallocs)) mallocs | immediate \(String(format2: immediate)) ns \(String(format2: immediateMallocs)) mallocs | suspending \(String(format2: suspending)) ns \(String(format2: suspendingMallocs)) mallocs | first await reached inline \(ranInline)/\(n)")
        }
    }
}

extension String {
    init(format2 value: Double) {
        let scaled = Int((value * 100).rounded())
        let frac = scaled % 100
        self = "\(scaled / 100).\(frac < 10 ? "0" : "")\(frac)"
    }
}
