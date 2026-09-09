//===----------------------------------------------------------------------===//
// WSGI dispatch.
//
// PEP 3333 is a blocking contract: the application is called, it returns an
// iterable, and the server drains it. Peregrine can run that two ways.
//
//   * Inline (the default). The worker loop calls the application itself, and
//     concurrency comes from process-level fan-out over SO_REUSEPORT. Nothing
//     is shared, nothing is locked, and a request costs one function call.
//   * Pooled (--wsgi-threads N). The loop hands the request to a thread and
//     goes back to serving sockets. This is what an application that waits on a
//     database wants: the waits overlap instead of queueing behind each other.
//
// Both paths build the environ here, on the loop thread, because the environ is
// derived from the request head and the head belongs to the connection. What
// differs afterwards is only who calls the application and where the response
// bytes are staged; the serialisation itself is shared, in WSGIResponse.swift,
// so the two produce identical output.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineWSGI

extension Worker {

    mutating func dispatchWSGI(_ slot: Int) {
        let c = table[slot]
        guard wsgi != nil else {
            failRequest(slot, status: 500)
            return
        }

        // WSGI has no way to express a protocol upgrade, so say so plainly
        // rather than handing the application a request it cannot answer.
        if c.pointee.head.flags.contains(.upgrade),
           websocketKey(slot, base: c.pointee.headBase()) != nil {
            failRequest(slot, status: 501)
            return
        }

        // --- request body as a single bytes object ---
        var bodyObj: PyObj?
        if c.pointee.body.readableBytes > 0 {
            let n = c.pointee.body.readableBytes
            bodyObj = UnsafePointer(c.pointee.body.readPointer)
                .withMemoryRebound(to: CChar.self, capacity: n) { p in
                    pg_bytes(p, pg_ssize_t(n))
                }
        } else {
            bodyObj = Interned.emptyBytes
            pg_incref(bodyObj!)
        }
        guard let body = bodyObj else {
            PyError.logPending("allocating the request body")
            failRequest(slot, status: 500)
            return
        }
        defer { pg_decref(body) }

        // --- environ ---
        let base = c.pointee.headBase()
        let forwarded = forwardedInfo(slot, base: base)
        guard let environ = wsgi!.buildEnviron(base: base,
                                               head: c.pointee.head,
                                               headers: headers,
                                               body: body,
                                               remoteAddr: c.pointee.remoteAddrObj,
                                               remotePort: c.pointee.remotePortObj) else {
            PyError.logPending("building the WSGI environ")
            failRequest(slot, status: 500)
            return
        }
        if !applyForwarded(forwarded, toEnviron: environ) {
            pg_decref(environ)
            PyError.logPending("applying forwarded headers")
            failRequest(slot, status: 500)
            return
        }

        guard let startResponse = WSGIStartResponse.make() else {
            pg_decref(environ)
            PyError.logPending("allocating start_response")
            failRequest(slot, status: 500)
            return
        }

        dates.refresh()
        if wsgiPool != nil {
            // Ownership of both objects passes to the job.
            submitWSGIJob(slot, environ: environ, startResponse: startResponse)
            return
        }
        defer {
            pg_decref(startResponse)
            pg_decref(environ)
        }
        callInline(slot, environ: environ, startResponse: startResponse)
    }

    // MARK: - Inline execution

    private mutating func callInline(_ slot: Int, environ: PyObj, startResponse: PyObj) {
        guard let result = wsgi!.call(environ: environ, startResponse: startResponse) else {
            PyError.logPending("application error")
            failRequest(slot, status: 500)
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
            failRequest(slot, status: 500)
            return
        }

        emitWSGIResponse(slot, status: statusObj, headerList: headerList,
                         startResponse: startResponse, result: result)
    }

    /// Serialises the response into the connection write buffer, flushing
    /// opportunistically as the body is produced.
    private mutating func emitWSGIResponse(_ slot: Int,
                                           status statusObj: PyObj,
                                           headerList: PyObj,
                                           startResponse: PyObj,
                                           result: PyObj) {
        let c = table[slot]

        let snapshot = WSGIRequestSnapshot(httpMinor: c.pointee.head.httpMinor,
                                           keepAlive: c.pointee.flags.contains(.keepAlive),
                                           suppressBody: c.pointee.flags.contains(.suppressBody),
                                           date: UnsafePointer(dates.bytes))
        // The buffer descriptor is copied out and back rather than passed
        // inout, because the flush below needs the connection to itself.
        var out = c.pointee.write
        let plan = WSGIResponseBuilder.writeHead(&out,
                                                 statusObj: statusObj,
                                                 headerList: headerList,
                                                 startResponse: startResponse,
                                                 result: result,
                                                 snapshot: snapshot)
        if !plan.ok {
            out.clear()
            c.pointee.write = out
            Log.error(plan.failure)
            failRequest(slot, status: 500)
            return
        }
        c.pointee.write = out
        applyPlan(slot, plan)
        logAccess(slot, status: plan.status)

        if !plan.suppressBody {
            // Legacy write() output goes out ahead of the iterable.
            if let written = WSGIStartResponse.writtenChunks(startResponse) {
                let n = Int(pg_list_size(written))
                var k = 0
                while k < n {
                    guard let part = pg_list_get(written, pg_ssize_t(k)) else { break }
                    k += 1
                    if !appendBodyPart(slot, part, chunked: plan.chunked) { return }
                }
            }

            if PySeq.isSequence(result) {
                let n = PySeq.count(result)
                var k = 0
                while k < n {
                    guard let part = PySeq.item(result, k) else { break }
                    k += 1
                    if !appendBodyPart(slot, part, chunked: plan.chunked) { return }
                }
            } else {
                guard let iterator = pg_iter(result) else {
                    PyError.logPending("iterating the application response")
                    // Headers are already queued; the only honest signal left
                    // is to drop the connection.
                    closeConnection(slot)
                    return
                }
                defer { pg_decref(iterator) }
                while let part = pg_iter_next(iterator) {
                    let ok = appendBodyPart(slot, part, chunked: plan.chunked)
                    pg_decref(part)
                    if !ok { return }
                }
                if pg_err_check() != 0 {
                    PyError.logPending("application iterator raised")
                    closeConnection(slot)
                    return
                }
            }
        }

        if plan.chunked && !plan.suppressBody {
            var tail = c.pointee.write
            HTTPResponseWriter.writeLastChunk(&tail)
            c.pointee.write = tail
        }

        c.pointee.state = .writing
        _ = flush(slot)
    }

    /// Records the framing decisions the builder made on the connection.
    private mutating func applyPlan(_ slot: Int, _ plan: WSGIHeadPlan) {
        let c = table[slot]
        if plan.keepAlive {
            c.pointee.flags.insert(.keepAlive)
        } else {
            c.pointee.flags.remove(.keepAlive)
        }
        if plan.chunked { c.pointee.flags.insert(.chunkedResponse) }
        if plan.suppressBody { c.pointee.flags.insert(.suppressBody) }
    }

    /// Appends one body part, applying backpressure. Returns false if the
    /// connection died.
    private mutating func appendBodyPart(_ slot: Int, _ part: PyObj, chunked: Bool) -> Bool {
        let c = table[slot]
        var out = c.pointee.write
        let ok = WSGIResponseBuilder.writeBodyPart(&out, part, chunked: chunked)
        c.pointee.write = out
        if !ok {
            PyError.logPending("response body part")
            closeConnection(slot)
            return false
        }
        // Keep memory bounded on large streaming responses.
        if c.pointee.write.readableBytes > config.writeHighWaterMark {
            if !flushWithBackpressure(slot) { return false }
        }
        return true
    }

    // MARK: - Pooled execution

    private mutating func submitWSGIJob(_ slot: Int, environ: PyObj, startResponse: PyObj) {
        guard let wsgiPool else {
            pg_decref(startResponse)
            pg_decref(environ)
            failRequest(slot, status: 500)
            return
        }
        let c = table[slot]
        let job = WSGIJob(slot: slot,
                          generation: c.pointee.generation,
                          environ: environ,
                          startResponse: startResponse,
                          httpMinor: c.pointee.head.httpMinor,
                          keepAlive: c.pointee.flags.contains(.keepAlive),
                          suppressBody: c.pointee.flags.contains(.suppressBody),
                          date: UnsafePointer(dates.bytes))
        c.pointee.poolJob = job
        // The connection belongs to the job now. Read interest has to go: a
        // level-triggered poller would spin on pipelined bytes that nothing is
        // going to consume until the job finishes.
        setInterest(slot, [])
        wsgiPool.submit(job)
    }

    /// The pool's completion pipe became readable.
    mutating func collectPoolResults() {
        guard let wsgiPool else { return }
        wsgiPool.drainWakeup()
        let batch = wsgiPool.takeReady()
        for job in batch {
            let slot = job.slot
            if slot >= table.capacity { continue }
            let c = table[slot]
            if c.pointee.state == .free || c.pointee.generation != job.generation {
                // The connection is gone. The thread stops at its next
                // checkpoint; it owns the job from here.
                wsgiPool.cancel(job)
                continue
            }
            pumpPoolJob(slot)
        }
    }

    /// Moves whatever a pool thread has produced onto the socket, and finalises
    /// the response once the thread reports it complete.
    mutating func pumpPoolJob(_ slot: Int) {
        let c = table[slot]
        guard let wsgiPool, let job = c.pointee.poolJob else { return }

        // While the socket is behind, leave the bytes with the job: that is
        // what makes the producing thread block instead of buffering.
        if c.pointee.write.readableBytes > config.writeHighWaterMark {
            setInterest(slot, [.write])
            return
        }

        var out = c.pointee.write
        let done = wsgiPool.take(job, into: &out)
        c.pointee.write = out

        if !done {
            _ = flush(slot)
            return
        }

        c.pointee.poolJob = nil

        if job.failed && !job.headersWritten {
            failRequest(slot, status: 500)
            return
        }
        if job.failed {
            // Headers went out and then the application broke: the message
            // cannot be terminated honestly, so close.
            Log.warn("application failed after its response had started")
            _ = flush(slot)
            closeConnection(slot)
            return
        }
        if !job.keepAlive { c.pointee.flags.remove(.keepAlive) }
        if job.chunked { c.pointee.flags.insert(.chunkedResponse) }
        logAccess(slot, status: job.status)
        c.pointee.state = .writing
        _ = flush(slot)
    }
}
