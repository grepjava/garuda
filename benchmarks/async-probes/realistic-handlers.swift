// Does a reused handler task stay allocation-free with realistic handlers?
// Each variant runs on one long-lived task on the loop executor, one million
// requests, and each request waits once on a continuation the loop resumes.
//
//   E1  4 KiB of locals held across the await
//   E2  five nested async calls, each with locals, the wait at the bottom
//   E3  a handler that throws a payload-free error every request
//   E4  a handler that throws an error carrying a String
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

enum Plain: Error { case notFound }
struct Described: Error { var message: String }

nonisolated(unsafe) var total = 0
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var parked: UnsafeContinuation<Int, Never>? = nil
nonisolated(unsafe) var inbox: UnsafeContinuation<Int, Never>? = nil

@inline(never) func wait() async -> Int {
    await withUnsafeContinuation { parked = $0 }
}

@inline(never) func bigFrame(_ x: Int) async -> Int {
    var local = InlineArray<4096, UInt8>(repeating: 1)
    local[x & 4095] = 2
    let y = await wait()
    return Int(local[x & 4095]) &+ Int(local[(x + 1) & 4095]) &+ y
}

@inline(never) func nested(_ depth: Int, _ x: Int) async -> Int {
    let a = x &* 3, b = x &+ depth, c = a ^ b
    if depth == 0 { return c &+ (await wait()) }
    return (await nested(depth - 1, x &+ 1)) &+ a &+ b &+ c
}

@inline(never) func throwsPlain(_ x: Int) async throws -> Int {
    _ = await wait()
    if x >= 0 { throw Plain.notFound }
    return x
}

@inline(never) func throwsTyped(_ x: Int) async throws(Plain) -> Int {
    _ = await wait()
    if x >= 0 { throw Plain.notFound }
    return x
}

@inline(never) func throwsDescribed(_ x: Int) async throws -> Int {
    _ = await wait()
    if x >= 0 { throw Described(message: "user \(x & 1023) not found") }
    return x
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

/// Runs `n` requests through one reused task whose body is `handler`.
func run(_ name: String, _ n: Int, _ loop: LoopExecutor,
         _ handler: @escaping @Sendable (Int) async -> Void) {
    Task(executorPreference: loop) {
        while true {
            let x = await withUnsafeContinuation { inbox = $0 }
            if x < 0 { break }
            await handler(x)
        }
    }
    loop.drain()
    // Warm the task's allocator before counting.
    for i in 0..<1000 { step(i, loop) }
    let m = mallocCount()
    let start = nanos()
    for i in 0..<n { step(i, loop) }
    let ns = Double(nanos() - start) / Double(n)
    let mallocs = Double(mallocCount() - m) / Double(n)
    let c = inbox!
    inbox = nil
    c.resume(returning: -1)
    loop.drain()
    print("  \(name): \(Int(ns.rounded())) ns, \(Int((mallocs * 1000).rounded())) mallocs per 1000 requests")
}

func step(_ i: Int, _ loop: LoopExecutor) {
    let c = inbox!
    inbox = nil
    c.resume(returning: i)
    loop.drain()
    let p = parked!
    parked = nil
    p.resume(returning: 1)
    loop.drain()
}

@main
struct Probe {
    static func main() {
        let n = 1_000_000
        let loop = LoopExecutor()
        loop.jobs.reserveCapacity(64)
        for round in 1...2 {
            print("round \(round)")
            run("E1 4 KiB across the await", n, loop) { x in total &+= await bigFrame(x) }
            run("E2 five nested calls", n, loop) { x in total &+= await nested(5, x) }
            run("E3 throws a plain error", n, loop) { x in
                do { total &+= try await throwsPlain(x) } catch { failures &+= 1 }
            }
            run("E4 throws an error with a String", n, loop) { x in
                do { total &+= try await throwsDescribed(x) } catch { failures &+= 1 }
            }
            run("E5 typed throws(Plain)", n, loop) { x in
                do throws(Plain) { total &+= try await throwsTyped(x) } catch { failures &+= 1 }
            }
        }
        print("failures \(failures)")
    }
}
