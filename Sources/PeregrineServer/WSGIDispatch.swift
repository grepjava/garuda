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
        // A multiplexed request carries its scheme as a pseudo-header, which
        // is the only place it appears; a trusted proxy may still override it
        // below, exactly as it does for HTTP/1.
        if c.pointee.isStream && c.pointee.h2Scheme {
            if pg_dict_set(environ, Interned[.wsgiURLScheme], Interned[.vHTTPS]) != 0 {
                pg_decref(environ)
                PyError.logPending("setting the request scheme")
                failRequest(slot, status: 500)
                return
            }
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

    /// Everything the response builder needs about this connection.
    func wsgiSnapshot(_ slot: Int) -> WSGIRequestSnapshot {
        let c = table[slot]
        return WSGIRequestSnapshot(httpMinor: c.pointee.head.httpMinor,
                                   keepAlive: c.pointee.flags.contains(.keepAlive),
                                   suppressBody: c.pointee.flags.contains(.suppressBody),
                                   date: UnsafePointer(dates.bytes),
                                   // Alt-Svc says where HTTP/3 is; a client
                                   // already multiplexing over HTTP/3 does not
                                   // need telling, and one on HTTP/2 hears it
                                   // from here.
                                   altSvc: c.pointee.isH3Stream ? nil : config.altSvc,
                                   altSvcLength: config.altSvcLength,
                                   multiplexed: c.pointee.isStream)
    }

    // MARK: - Inline execution

    private mutating func callInline(_ slot: Int, environ: PyObj, startResponse: PyObj) {
        // The legacy write() callable sends as it is called, so it needs a way
        // back to this connection while the application is still running. The
        // box lives on this frame, which encloses the whole call.
        var box = WSGIInlineWriteContext(slot: slot)
        let result: PyObj? = withUnsafeMutablePointer(to: &box) { boxPtr in
            WSGIStartResponse.setSink(startResponse, wsgiInlineWriteSink,
                                      context: UnsafeMutableRawPointer(boxPtr))
            return wsgi!.call(environ: environ, startResponse: startResponse)
        }

        // The client went away mid-write. The connection is closed and the
        // response is logged; there is nothing left to send it on.
        if box.dead {
            if let result {
                closeIterable(result)
                pg_decref(result)
            } else {
                pg_err_clear()
            }
            return
        }

        guard let result else {
            PyError.logPending("application error")
            if box.headSent {
                // The head is already on the wire, so a 500 is not available
                // any more. Dropping the connection is the only honest signal
                // left -- and on a chunked response the missing terminator is
                // exactly how a client is told the body is incomplete.
                closeConnection(slot)
                return
            }
            failRequest(slot, status: 500)
            return
        }
        defer {
            closeIterable(result)
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
                         startResponse: startResponse, result: result,
                         written: box)
    }

    /// PEP 3333: close() must be called if the iterable provides it.
    private func closeIterable(_ result: PyObj) {
        if pg_hasattr(result, "close") == 1 {
            if let r = pg_call_method0(result, Interned[.nClose]) {
                pg_decref(r)
            } else {
                PyError.logPending("iterable close()")
            }
        }
    }

    /// Serialises the response into the connection write buffer, flushing
    /// opportunistically as the body is produced.
    private mutating func emitWSGIResponse(_ slot: Int,
                                           status statusObj: PyObj,
                                           headerList: PyObj,
                                           startResponse: PyObj,
                                           result: PyObj,
                                           written: WSGIInlineWriteContext) {
        let c = table[slot]

        // A write() already sent the head and settled the framing, so the only
        // thing left is whatever the application returned on top of it.
        if written.headSent {
            emitWSGIBody(slot, result: result, plan: written.plan)
            return
        }

        let snapshot = wsgiSnapshot(slot)
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
        emitWSGIBody(slot, result: result, plan: plan)
    }

    /// Writes whatever the application returned, and closes the message.
    private mutating func emitWSGIBody(_ slot: Int, result: PyObj, plan: WSGIHeadPlan) {
        let c = table[slot]

        if !plan.suppressBody {
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
                // Each block goes to the socket before the next one is asked
                // for, which is what PEP 3333 requires of an iterator and the
                // only way a generator that yields, waits, and yields again
                // reaches the client while it waits. A list gets the batched
                // treatment above instead: every part is already in hand, so
                // nothing is kept waiting by writing them together.
                while let part = pg_iter_next(iterator) {
                    let ok = appendBodyPart(slot, part, chunked: plan.chunked,
                                            flushNow: true)
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

        // The application has returned, so the message is whole. On a stream
        // that is what says where it ends -- there is no chunked terminator
        // and no connection close to imply it.
        c.pointee.flags.insert(.responseComplete)
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
    ///
    /// `flushNow` is for the producers that have someone waiting on the other
    /// end of the block -- an iterator between yields, a `write()` inside the
    /// application. The block is drained all the way out before control goes
    /// back, waiting on the socket if the client is behind, because on this
    /// path the application runs on the loop thread: whatever is left here has
    /// nothing to send it until the application returns. That is one write
    /// syscall per block when the client keeps up, and the application waiting
    /// on the client when it does not, which is what backpressure means.
    private mutating func appendBodyPart(_ slot: Int, _ part: PyObj, chunked: Bool,
                                         flushNow: Bool = false) -> Bool {
        let c = table[slot]
        var out = c.pointee.write
        let ok = WSGIResponseBuilder.writeBodyPart(&out, part, chunked: chunked)
        c.pointee.write = out
        if !ok {
            PyError.logPending("response body part")
            closeConnection(slot)
            return false
        }
        if flushNow {
            return flushWithBackpressure(slot, until: 0)
        }
        // A batched producer only has to be kept from running away with memory.
        if c.pointee.write.readableBytes > config.writeHighWaterMark {
            return flushWithBackpressure(slot)
        }
        return true
    }

    // MARK: - The legacy write() callable, inline

    /// Sends one block the application passed to `write()`, head included if
    /// this is the first of them.
    fileprivate mutating func legacyWriteInline(
        _ box: UnsafeMutablePointer<WSGIInlineWriteContext>,
        startResponse: PyObj,
        part: PyObj
    ) -> Int32 {
        // An application that caught the last failure and kept writing. The
        // slot is closed and may already belong to another connection, so the
        // only safe thing is to keep saying no.
        if box.pointee.dead {
            pg_err_set_str(pg_exc_os(), "the client closed the connection")
            return -1
        }
        let slot = box.pointee.slot

        if !box.pointee.headSent {
            guard let statusObj = WSGIStartResponse.status(startResponse),
                  let headerList = WSGIStartResponse.headers(startResponse) else {
                pg_err_set_str(pg_exc_runtime(), "write() before start_response()")
                return -1
            }
            let c = table[slot]
            var out = c.pointee.write
            // No return value exists yet and none can arrive in time, so the
            // framing is whatever the application declared or chunked.
            let plan = WSGIResponseBuilder.writeHead(&out,
                                                     statusObj: statusObj,
                                                     headerList: headerList,
                                                     startResponse: startResponse,
                                                     result: nil,
                                                     snapshot: wsgiSnapshot(slot))
            if !plan.ok {
                out.clear()
                c.pointee.write = out
                Log.error(plan.failure)
                box.pointee.dead = true
                failRequest(slot, status: 500)
                pg_err_set_str(pg_exc_runtime(), "the response head was rejected")
                return -1
            }
            c.pointee.write = out
            applyPlan(slot, plan)
            logAccess(slot, status: plan.status)
            box.pointee.plan = plan
            box.pointee.headSent = true
        }

        // HEAD, 204, 304: the head goes out, the body is dropped. PEP 3333 has
        // the application write it either way.
        if box.pointee.plan.suppressBody { return 0 }

        if !appendBodyPart(slot, part, chunked: box.pointee.plan.chunked, flushNow: true) {
            box.pointee.dead = true
            if pg_err_check() == 0 {
                pg_err_set_str(pg_exc_os(), "the client closed the connection")
            }
            return -1
        }
        return 0
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
                          date: UnsafePointer(dates.bytes),
                          altSvc: c.pointee.isH3Stream ? nil : config.altSvc,
                          altSvcLength: config.altSvcLength,
                          multiplexed: c.pointee.isStream)
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
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }
}

// MARK: - The write() sink

/// What the inline `write()` sink needs while the application runs, and what it
/// leaves behind for the code that finishes the response.
///
/// It lives on `callInline`'s frame, which encloses the application call, so
/// nothing can reach a `write()` after the frame is gone.
struct WSGIInlineWriteContext {
    let slot: Int
    /// The framing the first write settled. The application's return value is
    /// written on top of it, under the same rules.
    var plan = WSGIHeadPlan()
    var headSent = false
    /// The client went away during a write, so the connection is already
    /// closed and the slot must not be touched again.
    var dead = false

    init(slot: Int) { self.slot = slot }
}

/// The C entry point `write()` reaches. The worker comes from the thread-local
/// rather than the context, because the inline path runs the application on the
/// loop thread by definition.
private func wsgiInlineWriteSink(_ ctx: UnsafeMutableRawPointer?,
                                 _ startResponse: PyObj?,
                                 _ part: PyObj?) -> Int32 {
    guard let ctx, let startResponse, let part, let worker = currentWorker else {
        pg_err_set_str(pg_exc_runtime(), "write() outside a request")
        return -1
    }
    let box = ctx.assumingMemoryBound(to: WSGIInlineWriteContext.self)
    return worker.pointee.legacyWriteInline(box, startResponse: startResponse, part: part)
}
