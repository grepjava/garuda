//===----------------------------------------------------------------------===//
// The optional WSGI thread pool.
//
// PEP 3333 is a blocking contract, and a synchronous application spends most of
// its wall clock waiting: on a database, on a cache, on an HTTP call to another
// service. The GIL is not what limits that -- CPython releases it around every
// blocking syscall -- so running one request at a time per process leaves a
// worker idle precisely when the application is busy waiting. A bounded pool
// lets those waits overlap. CPU-bound applications get nothing from it, which
// is why the default is still one thread and the inline path is unchanged.
//
// The split of responsibilities is what keeps this safe:
//
//   * The loop thread owns every connection, every buffer and the poller. It
//     builds the environ (which needs the request head, and therefore the
//     connection) and hands the job over.
//   * A pool thread owns only the job: it holds the GIL, calls the application,
//     and serialises the response into the job's own buffer.
//   * Bytes cross back through that buffer under one mutex, and the loop is
//     told about them through a pipe the poller already watches -- the same
//     wakeup mechanism as a socket, so no new blocking point exists.
//
// A pool thread never touches a Connection, and the loop thread never touches
// the application. The one thing they share is the job.
//
// Backpressure is real rather than advisory: when a job's buffer passes the
// high water mark the producing thread releases the GIL and blocks until the
// loop has written enough of it to the socket. A streaming response therefore
// runs at the speed of the client, not the speed of the application.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineWSGI

/// One request handed to a pool thread.
///
/// Fields fall into three groups: inputs written by the loop before submission
/// and never touched again; outputs written by the thread and read by the loop,
/// all guarded by the pool mutex; and the plan, written by the thread before it
/// reports completion and read by the loop afterwards.
public final class WSGIJob {
    // --- identity, immutable after submission ---
    let slot: Int
    let generation: UInt32

    // --- inputs, owned by the thread once it starts ---
    var environ: PyObj?
    var startResponse: PyObj?

    // --- request snapshot, so the thread never reads connection state ---
    let httpMinor: UInt8
    let keepAliveIn: Bool
    let suppressBody: Bool
    let date: UnsafeMutablePointer<UInt8>
    /// Borrowed; both live for the process.
    let altSvc: UnsafePointer<UInt8>?
    let altSvcLength: Int
    /// The response is bound for an HTTP/2 or HTTP/3 stream, so its head is
    /// staged rather than written as text.
    let multiplexed: Bool

    // --- shared, guarded by the pool mutex ---
    var out = ByteBuffer()
    var finished = false
    var queued = false
    var cancelled = false

    // --- plan, written before `finished` is set ---
    var failed = false
    var headersWritten = false
    var chunked = false
    var keepAlive = true
    var status = 0

    init(slot: Int, generation: UInt32,
         environ: PyObj, startResponse: PyObj,
         httpMinor: UInt8, keepAlive: Bool, suppressBody: Bool,
         date: UnsafePointer<UInt8>,
         altSvc: UnsafePointer<UInt8>? = nil, altSvcLength: Int = 0,
         multiplexed: Bool = false) {
        self.slot = slot
        self.generation = generation
        self.environ = environ
        self.startResponse = startResponse
        self.httpMinor = httpMinor
        self.keepAliveIn = keepAlive
        self.suppressBody = suppressBody
        self.keepAlive = keepAlive
        self.altSvc = altSvc
        self.altSvcLength = altSvcLength
        self.multiplexed = multiplexed
        // The Date header must be the one from when the request was accepted,
        // and the shared cache will have moved on by the time a slow
        // application returns.
        self.date = UnsafeMutablePointer<UInt8>.allocate(capacity: 29)
        self.date.update(from: date, count: 29)
    }

    deinit {
        date.deallocate()
        out.destroy()
    }
}

public final class WSGIPool {
    private let mutex: OpaquePointer
    /// Signalled when a job is queued, or when the pool is stopping.
    private let workCond: OpaquePointer
    /// Signalled when the loop has drained part of a job's output.
    private let drainCond: OpaquePointer

    private var pending: [WSGIJob] = []
    private var ready: [WSGIJob] = []
    private var stopping = false
    private var liveThreads = 0
    private var running = 0

    /// Read end of the completion pipe, registered with the poller.
    public let wakeupFD: Int32
    private let wakeWriteFD: Int32

    let highWaterMark: Int
    let lowWaterMark: Int
    /// Bytes a thread stages locally before taking the mutex. Small enough that
    /// a streaming response reaches the client promptly, large enough that a
    /// many-part response does not lock once per part.
    let stageThreshold = 32 * 1024

    private let app: PyObj
    private let threads: Int

    public init?(threads: Int, worker: UnsafeMutablePointer<Worker>) {
        guard let m = pg_mutex_new(), let wc = pg_cond_new(), let dc = pg_cond_new() else {
            return nil
        }
        var fds: (Int32, Int32) = (-1, -1)
        let ok = withUnsafeMutablePointer(to: &fds) { p -> Bool in
            p.withMemoryRebound(to: Int32.self, capacity: 2) { pg_pipe($0) == 0 }
        }
        guard ok, let application = worker.pointee.wsgi?.app else { return nil }

        self.mutex = m
        self.workCond = wc
        self.drainCond = dc
        self.wakeupFD = fds.0
        self.wakeWriteFD = fds.1
        self.app = application
        self.threads = threads
        self.highWaterMark = worker.pointee.config.writeHighWaterMark
        self.lowWaterMark = worker.pointee.config.writeLowWaterMark

        // Threads are started after everything else is in place, because one
        // may pick up work before this initialiser has returned.
        let context = Unmanaged.passUnretained(self).toOpaque()
        for _ in 0..<threads {
            if pg_thread_spawn(wsgiPoolThreadMain, context) != 0 {
                Log.error("could not start a WSGI pool thread")
                if liveThreads == 0 { return nil }
                break
            }
            liveThreads += 1
        }
    }

    /// Jobs a thread is still working on.
    ///
    /// Counted from submission until the thread has finished with the job, not
    /// until the loop has written the response out. That is deliberate: when a
    /// client disconnects mid-request the connection goes away immediately but
    /// the thread is still inside the application, and shutdown has to wait for
    /// it rather than finalise the interpreter underneath it.
    public var inFlight: Int {
        pg_mutex_lock(mutex)
        let n = running
        pg_mutex_unlock(mutex)
        return n
    }

    // MARK: - Loop side

    /// Queues a job. Called on the loop thread with the GIL held.
    public func submit(_ job: WSGIJob) {
        pg_mutex_lock(mutex)
        running += 1
        pending.append(job)
        pg_mutex_unlock(mutex)
        pg_cond_signal(workCond)
    }

    /// Consumes the wakeup byte(s). The pipe is only a readiness signal; the
    /// queue itself carries the information.
    public func drainWakeup() {
        var scratch = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        while true {
            let n = withUnsafeMutableBytes(of: &scratch) { raw in
                pg_read(wakeupFD, raw.baseAddress!, 8)
            }
            if n <= 0 { break }
        }
    }

    /// Jobs with something to report. Clearing `queued` lets a thread that is
    /// still producing enqueue the same job again.
    public func takeReady() -> [WSGIJob] {
        pg_mutex_lock(mutex)
        let batch = ready
        ready.removeAll(keepingCapacity: true)
        for job in batch { job.queued = false }
        pg_mutex_unlock(mutex)
        return batch
    }

    /// Moves whatever the thread has produced into `dst`. Returns true once the
    /// job is complete and its plan can be applied.
    public func take(_ job: WSGIJob, into dst: inout ByteBuffer) -> Bool {
        pg_mutex_lock(mutex)
        let available = job.out.readableBytes
        if available > 0 {
            dst.write(UnsafePointer(job.out.readPointer), available)
            job.out.clear()
        }
        let done = job.finished
        pg_mutex_unlock(mutex)
        // Whatever was blocked at the high water mark can carry on now.
        if available > 0 { pg_cond_broadcast(drainCond) }
        return done
    }

    /// The connection went away. The thread stops at its next checkpoint and
    /// releases the job's Python references itself.
    public func cancel(_ job: WSGIJob) {
        pg_mutex_lock(mutex)
        job.cancelled = true
        job.out.clear()
        pg_mutex_unlock(mutex)
        pg_cond_broadcast(drainCond)
    }

    /// Stops the threads, waiting up to `deadlineMs` for the ones still inside
    /// an application call. Anything past the deadline is abandoned: the
    /// process is about to exit, and a thread stuck in a third-party library is
    /// not going to become unstuck.
    public func shutdown(deadlineMs: UInt64) {
        pg_mutex_lock(mutex)
        stopping = true
        pg_mutex_unlock(mutex)
        pg_cond_broadcast(workCond)
        pg_cond_broadcast(drainCond)

        let deadline = pg_monotonic_ms() &+ max(deadlineMs, 100)
        while pg_monotonic_ms() < deadline {
            pg_mutex_lock(mutex)
            let remaining = liveThreads
            pg_mutex_unlock(mutex)
            if remaining == 0 { return }
            // The threads need the GIL to finish; the loop thread must not
            // hold it while waiting for them.
            let saved = pg_gil_save()
            _ = pg_poll_single(wakeupFD, 0, 20)
            pg_gil_restore(saved)
        }
        Log.warn("WSGI pool threads did not stop within the grace period")
    }

    // MARK: - Thread side

    fileprivate func runThread() {
        while true {
            pg_mutex_lock(mutex)
            while pending.isEmpty && !stopping {
                pg_cond_wait(workCond, mutex)
            }
            if pending.isEmpty {
                // Only reachable when stopping.
                liveThreads -= 1
                pg_mutex_unlock(mutex)
                return
            }
            let job = pending.removeFirst()
            pg_mutex_unlock(mutex)
            execute(job)
        }
    }

    private func execute(_ job: WSGIJob) {
        let gil = pg_gil_ensure()
        runApplication(job)
        if let e = job.environ { pg_decref(e); job.environ = nil }
        if let s = job.startResponse { pg_decref(s); job.startResponse = nil }
        pg_gil_release(gil)

        pg_mutex_lock(mutex)
        job.finished = true
        running -= 1
        if !job.queued { job.queued = true; ready.append(job) }
        pg_mutex_unlock(mutex)
        wake()
    }

    /// Runs the application and serialises its response. The GIL is held on
    /// entry and on exit; it is released only while parked on backpressure.
    private func runApplication(_ job: WSGIJob) {
        guard let environ = job.environ, let startResponse = job.startResponse else {
            job.failed = true
            return
        }
        guard let result = pg_call2(app, environ, startResponse) else {
            PyError.logPending("application error")
            job.failed = true
            return
        }
        defer {
            // PEP 3333: close() must be called if the iterable provides it.
            if pg_hasattr(result, "close") == 1 {
                if let r = pg_call_method0(result, Interned[.nClose]) {
                    pg_decref(r)
                } else {
                    PyError.logPending("iterable close()")
                }
            }
            pg_decref(result)
        }

        guard WSGIStartResponse.wasCalled(startResponse),
              let statusObj = WSGIStartResponse.status(startResponse),
              let headerList = WSGIStartResponse.headers(startResponse) else {
            Log.error("application returned without calling start_response")
            job.failed = true
            return
        }

        var staged = ByteBuffer()
        defer { staged.destroy() }

        let snapshot = WSGIRequestSnapshot(httpMinor: job.httpMinor,
                                           keepAlive: job.keepAliveIn,
                                           suppressBody: job.suppressBody,
                                           date: UnsafePointer(job.date),
                                           altSvc: job.altSvc,
                                           altSvcLength: job.altSvcLength,
                                           multiplexed: job.multiplexed)
        let plan = WSGIResponseBuilder.writeHead(&staged,
                                                 statusObj: statusObj,
                                                 headerList: headerList,
                                                 startResponse: startResponse,
                                                 result: result,
                                                 snapshot: snapshot)
        if !plan.ok {
            Log.error(plan.failure)
            job.failed = true
            return
        }
        job.status = plan.status
        job.chunked = plan.chunked
        job.keepAlive = plan.keepAlive
        job.headersWritten = true

        if !plan.suppressBody {
            // Legacy write() output goes out ahead of the iterable.
            if let written = WSGIStartResponse.writtenChunks(startResponse) {
                let n = Int(pg_list_size(written))
                var k = 0
                while k < n {
                    guard let part = pg_list_get(written, pg_ssize_t(k)) else { break }
                    k += 1
                    if !emit(job, part, plan.chunked, &staged) { return }
                }
            }

            if PySeq.isSequence(result) {
                let n = PySeq.count(result)
                var k = 0
                while k < n {
                    guard let part = PySeq.item(result, k) else { break }
                    k += 1
                    if !emit(job, part, plan.chunked, &staged) { return }
                }
            } else {
                guard let iterator = pg_iter(result) else {
                    PyError.logPending("iterating the application response")
                    job.failed = true
                    return
                }
                defer { pg_decref(iterator) }
                while let part = pg_iter_next(iterator) {
                    let ok = emit(job, part, plan.chunked, &staged)
                    pg_decref(part)
                    if !ok { return }
                }
                if pg_err_check() != 0 {
                    PyError.logPending("application iterator raised")
                    job.failed = true
                    return
                }
            }
        }

        if plan.chunked && !plan.suppressBody {
            HTTPResponseWriter.writeLastChunk(&staged)
        }
        _ = handoff(job, &staged)
    }

    /// Serialises one body part, handing bytes over once enough have piled up.
    private func emit(_ job: WSGIJob, _ part: PyObj, _ chunked: Bool,
                      _ staged: inout ByteBuffer) -> Bool {
        if !WSGIResponseBuilder.writeBodyPart(&staged, part, chunked: chunked) {
            PyError.logPending("response body part")
            job.failed = true
            return false
        }
        if staged.readableBytes < stageThreshold { return true }
        return handoff(job, &staged)
    }

    /// Publishes staged bytes and blocks while the loop is behind.
    ///
    /// The GIL is released before parking. Holding it here would stop the loop
    /// thread from doing the very work this thread is waiting for -- the
    /// deadlock this whole design exists to avoid.
    private func handoff(_ job: WSGIJob, _ staged: inout ByteBuffer) -> Bool {
        pg_mutex_lock(mutex)
        if job.cancelled {
            pg_mutex_unlock(mutex)
            return false
        }
        let n = staged.readableBytes
        if n > 0 {
            job.out.write(UnsafePointer(staged.readPointer), n)
            staged.clear()
        }
        let wakeNeeded = !job.queued
        if wakeNeeded { job.queued = true; ready.append(job) }
        let backedUp = job.out.readableBytes > highWaterMark
        pg_mutex_unlock(mutex)
        if wakeNeeded { wake() }
        if !backedUp { return true }

        let saved = pg_gil_save()
        pg_mutex_lock(mutex)
        while job.out.readableBytes > lowWaterMark && !job.cancelled && !stopping {
            pg_cond_wait(drainCond, mutex)
        }
        let alive = !job.cancelled
        pg_mutex_unlock(mutex)
        pg_gil_restore(saved)
        return alive
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = pg_write(wakeWriteFD, &byte, 1)
    }
}

private func wsgiPoolThreadMain(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<WSGIPool>.fromOpaque(raw).takeUnretainedValue().runThread()
}
