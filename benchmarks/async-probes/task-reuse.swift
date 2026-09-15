// Cheaper ways to run an async handler on the worker thread. One million
// requests per variant, each reported as ns per request, mallocs per request
// (under LD_PRELOAD and malloc-counter.c), and how many ran up to their first await
// on the calling thread.
//
//   A  Task.immediate, no executor preference, from the loop's plain code
//   B  the loop itself runs as a job on its executor; Task.immediate from there
//   C  one long-lived task reused for every request (no Task per request)
//   D  as C, with a handler that waits once and is resumed by the loop
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
nonisolated(unsafe) var ran = false
nonisolated(unsafe) var inline = 0
nonisolated(unsafe) var parked: UnsafeContinuation<Int, Never>? = nil
nonisolated(unsafe) var inbox: UnsafeContinuation<Int, Never>? = nil
nonisolated(unsafe) var elapsed: UInt64 = 0

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

let mallocCount: @convention(c) () -> Int = {
    // RTLD_DEFAULT is a null handle on glibc.
    guard let symbol = dlsym(nil, "probe_malloc_count") else { return { 0 } }
    return unsafeBitCast(symbol, to: (@convention(c) () -> Int).self)
}()

func report(_ name: String, _ n: Int, _ ns: UInt64, _ mallocs: Int) {
    let perRequest = Double(ns) / Double(n)
    let m = Double(mallocs) / Double(n)
    print("  \(name): \(Int(perRequest.rounded())) ns, \(Int((m * 100).rounded()) / 100).\(Int((m * 100).rounded()) % 100) mallocs, inline \(inline)/\(n)")
}

@main
struct Probe {
    static func main() {
        let n = 1_000_000
        let loop = LoopExecutor()
        loop.jobs.reserveCapacity(64)

        for round in 1...2 {
            print("round \(round)")

            // A: no preference. It runs on this thread until it suspends; it
            // never suspends here, so it should finish inline.
            inline = 0
            var m = mallocCount()
            var start = nanos()
            for i in 0..<n {
                ran = false
                Task.immediate { ran = true; total &+= await asyncHandler(i) }
                if ran { inline += 1 }
            }
            report("A immediate, no preference", n, nanos() - start, mallocCount() - m)

            // B: the benchmark loop is itself a job on the loop executor.
            inline = 0
            m = mallocCount()
            start = nanos()
            Task(executorPreference: loop) {
                for i in 0..<n {
                    ran = false
                    Task.immediate(executorPreference: loop) { ran = true; total &+= await asyncHandler(i) }
                    if ran { inline += 1 }
                }
            }
            loop.drain()
            report("B immediate, loop as a job", n, nanos() - start, mallocCount() - m)

            // C: one task, reused. Each request resumes it once.
            inline = 0
            Task(executorPreference: loop) {
                while true {
                    let x = await withUnsafeContinuation { inbox = $0 }
                    if x < 0 { break }
                    total &+= await asyncHandler(x)
                }
            }
            loop.drain()
            m = mallocCount()
            start = nanos()
            for i in 0..<n {
                let c = inbox!
                inbox = nil
                c.resume(returning: i)
                loop.drain()
            }
            report("C reused task", n, nanos() - start, mallocCount() - m)
            let stopC = inbox!
            inbox = nil
            stopC.resume(returning: -1)
            loop.drain()

            // D: one task, reused, with a handler that waits once.
            inline = 0
            Task(executorPreference: loop) {
                while true {
                    let x = await withUnsafeContinuation { inbox = $0 }
                    if x < 0 { break }
                    total &+= await waitingHandler(x)
                }
            }
            loop.drain()
            m = mallocCount()
            start = nanos()
            for i in 0..<n {
                let c = inbox!
                inbox = nil
                c.resume(returning: i)
                loop.drain()
                let p = parked!
                parked = nil
                p.resume(returning: 1)
                loop.drain()
            }
            report("D reused task, one wait", n, nanos() - start, mallocCount() - m)
            let stopD = inbox!
            inbox = nil
            stopD.resume(returning: -1)
            loop.drain()
        }
    }
}
