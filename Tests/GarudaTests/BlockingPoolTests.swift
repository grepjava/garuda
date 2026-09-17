import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import CAvian
@testable import Garuda

// The blocking pool: work handed to its threads, what comes back, and the
// queue limit. scripts/handler-test.py checks that a worker keeps serving
// while its work runs.

/// A gate a pool thread waits at until the test opens it.
private final class Gate: @unchecked Sendable {
    let lock = av_mutex_new()!
    let opened = av_cond_new()!
    var open = false

    deinit {
        av_cond_free(opened)
        av_mutex_free(lock)
    }

    func wait() {
        av_mutex_lock(lock)
        while !open { av_cond_wait(opened, lock) }
        av_mutex_unlock(lock)
    }

    func release() {
        av_mutex_lock(lock)
        open = true
        av_cond_broadcast(opened)
        av_mutex_unlock(lock)
    }
}

@Suite("Blocking pool", .serialized)
struct BlockingPoolTests {

    @Test func aHandlersWorkRunsOffTheWorkerAndReturns() throws {
        let app = Application()
        app.get("/work/:n") { (n: Path<Int>) async throws -> String in
            let worker = Int(bitPattern: av_worker_current())
            let (sum, sameThread) = try await blocking { () -> (Int, Bool) in
                ((1...n.value).reduce(0, +), Int(bitPattern: av_worker_current()) == worker)
            }
            return "\(sum) \(sameThread) \(Int(bitPattern: av_worker_current()) == worker)"
        }
        app.get("/fails") { () async throws -> String in
            try await blocking { throw HTTPError.conflict("no") }
        }
        let client = app.test
        // Summed on a pool thread, which is not the worker, and the handler
        // carries on back on the worker.
        #expect(try client.get("/work/100").text == "5050 false true")
        #expect(try client.get("/work/10").text == "55 false true")
        #expect(try client.get("/fails").status == 409)
    }

    @Test func offAWorkerTheWorkRunsWhereItIsCalled() async throws {
        #expect(try await blocking { 6 * 7 } == 42)
    }

    @Test func workPastTheQueueIsRefused() throws {
        let pool = try #require(BlockingPool(threads: 1, queue: 1))
        defer { pool.stop() }
        let gate = Gate()
        nonisolated(unsafe) var ran: [Int] = []
        let lock = av_mutex_new()!
        defer { av_mutex_free(lock) }

        func job(_ n: Int, waits: Bool) -> BlockingJob {
            let job = BlockingJob()
            job.run = {
                if waits { gate.wait() }
                av_mutex_lock(lock)
                ran.append(n)
                av_mutex_unlock(lock)
            }
            return job
        }
        #expect(pool.submit(job(1, waits: true)) == nil)
        // Whether or not the thread has taken the first yet, one more fits
        // and the one after does not.
        #expect(pool.submit(job(2, waits: false)) == nil)
        #expect(pool.submit(job(3, waits: false)) == .full)
        gate.release()

        var finished = 0
        for _ in 0..<500 where finished < 2 {
            finished += pool.takeFinished().count
            usleep(2_000)
        }
        #expect(finished == 2)
        av_mutex_lock(lock)
        #expect(ran == [1, 2])
        av_mutex_unlock(lock)
    }

    @Test func threadsStartAsWorkWaits() throws {
        let pool = try #require(BlockingPool(threads: 4, queue: 0))
        defer { pool.stop() }
        let gate = Gate()
        for _ in 0..<4 {
            let job = BlockingJob()
            job.run = { gate.wait() }
            #expect(pool.submit(job) == nil)
        }
        // Four threads, each holding one piece of work, and no queue.
        let fifth = BlockingJob()
        #expect(pool.submit(fifth) == .full)
        gate.release()
        var finished = 0
        for _ in 0..<500 where finished < 4 {
            finished += pool.takeFinished().count
            usleep(2_000)
        }
        #expect(finished == 4)
        // With the threads idle again, work is taken at once. A thread goes
        // back to waiting just after it hands its work over, so allow it that.
        var accepted = false
        for _ in 0..<500 where !accepted {
            accepted = pool.submit(BlockingJob()) == nil
            if !accepted { usleep(2_000) }
        }
        #expect(accepted)
    }
}
