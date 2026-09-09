//===----------------------------------------------------------------------===//
// ASGI dispatch.
//
// The integration with asyncio is the interesting part, and it is deliberately
// boring at runtime: our epoll/kqueue descriptor is itself pollable, so it is
// handed to the loop with `loop.add_reader(pollfd, drain)`. asyncio then treats
// the whole server as one more readable file descriptor and calls back into
// Swift when connections need service.
//
// That means:
//   * one thread, one event loop, one interpreter -- no worker threads;
//   * no cross-thread queues and no call_soon_threadsafe wakeups;
//   * the GIL is never handed back and forth, because nothing else wants it;
//   * uvloop works unchanged, since add_reader is part of the loop contract.
//
// `send` and `receive` are C-level callables (PyTrampoline) carrying a packed
// (generation, slot) token rather than a Python closure over server state. A
// send that completes immediately -- the common case, since the bytes just go
// into the write buffer -- returns a pre-completed awaitable that raises
// StopIteration on its first step, so `await send(...)` never round-trips
// through the event loop.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineASGI
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

public enum ASGIRuntime {
    nonisolated(unsafe) static var scope: ASGIScopeBuilder? = nil
    nonisolated(unsafe) static var app: PyObj! = nil
    nonisolated(unsafe) static var loop: PyObj! = nil
    nonisolated(unsafe) static var lifespan: PyObj? = nil
    nonisolated(unsafe) static var fnSpawn: PyObj! = nil
    nonisolated(unsafe) static var fnResolve: PyObj! = nil
    nonisolated(unsafe) static var fnRunUntil: PyObj! = nil
    nonisolated(unsafe) static var fnRunLoop: PyObj! = nil
    nonisolated(unsafe) static var fnStopLoop: PyObj! = nil
    nonisolated(unsafe) static var fnArmTimer: PyObj! = nil
    nonisolated(unsafe) static var fnTaskError: PyObj! = nil
    nonisolated(unsafe) static var fnFinish: PyObj! = nil
    nonisolated(unsafe) static var drainCallback: PyObj! = nil
    nonisolated(unsafe) static var timerCallback: PyObj! = nil
    nonisolated(unsafe) static var gracefulShutdownMs: UInt64 = 10_000

    // MARK: - Setup

    public static func prepare(app application: PyObj, config: ServerConfig) -> Bool {
        app = application

        guard let spawn = Interpreter.glueFunction("spawn"),
              let resolve = Interpreter.glueFunction("resolve"),
              let runUntil = Interpreter.glueFunction("run_until"),
              let runLoop = Interpreter.glueFunction("run_loop"),
              let stopLoop = Interpreter.glueFunction("stop_loop"),
              let armTimer = Interpreter.glueFunction("arm_timer"),
              let taskError = Interpreter.glueFunction("task_error"),
              let finish = Interpreter.glueFunction("finish"),
              let newLoop = Interpreter.glueFunction("new_loop") else {
            return false
        }
        fnSpawn = spawn
        fnResolve = resolve
        fnRunUntil = runUntil
        fnRunLoop = runLoop
        fnStopLoop = stopLoop
        fnArmTimer = armTimer
        fnTaskError = taskError
        fnFinish = finish
        gracefulShutdownMs = config.gracefulShutdownMs

        guard let l = pg_call1(newLoop, config.preferUvloop ? Interned.pyTrue : Interned.pyFalse) else {
            PyError.logPending("creating the event loop")
            return false
        }
        loop = l

        // --- lifespan startup ---
        var state: PyObj? = nil
        if config.callLifespan {
            guard let cls = pg_getattr(Interpreter.glue, "Lifespan") else {
                PyError.logPending("loading the lifespan driver")
                return false
            }
            defer { pg_decref(cls) }
            guard let rootObj = pg_str_intern(config.rootPath) else { return false }
            defer { pg_decref(rootObj) }
            guard let ls = pg_call2(cls, application, rootObj) else {
                PyError.logPending("creating the lifespan driver")
                return false
            }
            lifespan = ls
            guard let coro = pg_call_method0(ls, Interned[.nStartup]) else {
                PyError.logPending("starting lifespan")
                return false
            }
            let outcome = pg_call2(fnRunUntil, l, coro)
            pg_decref(coro)
            guard let outcome else {
                PyError.logPending("running lifespan startup")
                return false
            }
            defer { pg_decref(outcome) }
            if pg_is(outcome, Interned.none) == 0 {
                var n: pg_ssize_t = 0
                if let msg = pg_str_utf8_data(outcome, &n) {
                    Log.error { line in
                        line.str("lifespan startup failed: ")
                        line.bytes(UnsafeRawPointer(msg).assumingMemoryBound(to: UInt8.self), Int(n))
                    }
                }
                return false
            }
            if let st = pg_getattr(ls, "state") { state = st } else { pg_err_clear() }
        }

        guard let builder = ASGIScopeBuilder(scheme: config.scheme,
                                             rootPath: config.rootPath,
                                             serverHost: config.serverName,
                                             serverPort: Int(config.port),
                                             lifespanState: state) else {
            PyError.logPending("preparing the ASGI scope")
            return false
        }
        scope = builder
        return true
    }

    /// Hands the poller to asyncio and runs until the loop stops.
    public static func runLoop(_ worker: UnsafeMutablePointer<Worker>) {
        guard let drain = PyTrampoline.make(asgiDrain, context: 0),
              let timer = PyTrampoline.make(asgiTimer, context: 0) else {
            PyError.logPending("creating the loop callbacks")
            return
        }
        drainCallback = drain
        timerCallback = timer

        // Prime the periodic sweep (idle timeouts, drain completion).
        if let r = pg_call2(fnArmTimer, loop, timer) { pg_decref(r) } else { pg_err_clear() }

        guard let pollFD = pg_int(Int(worker.pointee.poller.fd)) else { return }
        defer { pg_decref(pollFD) }

        if let r = pg_call3(fnRunLoop, loop, pollFD, drain) {
            pg_decref(r)
        } else {
            PyError.logPending("running the event loop")
        }

        shutdown()
    }

    /// Shuts the loop down in the order an application expects.
    ///
    /// Order matters and the previous arrangement had it backwards: cancelling
    /// every task before sending `lifespan.shutdown` cancels the lifespan task
    /// too, so the application never reaches the code after its `yield` and its
    /// cleanup -- closing database pools, flushing telemetry -- silently does
    /// not run. Request tasks are therefore drained first, with a deadline, and
    /// only then is the lifespan asked to shut down.
    static func shutdown() {
        if let timeout = pg_int(Int(gracefulShutdownMs)) {
            defer { pg_decref(timeout) }
            let ls = lifespan ?? Interned.none!
            if let outcome = pg_call3(fnFinish, loop, ls, timeout) {
                defer { pg_decref(outcome) }
                if pg_is(outcome, Interned.none) == 0 {
                    var n: pg_ssize_t = 0
                    if let msg = pg_str_utf8_data(outcome, &n) {
                        Log.warn { line in
                            line.str("lifespan shutdown reported: ")
                            line.bytes(UnsafeRawPointer(msg).assumingMemoryBound(to: UInt8.self),
                                       Int(n))
                        }
                    } else {
                        pg_err_clear()
                    }
                }
            } else {
                PyError.logPending("shutting the event loop down")
            }
        } else {
            pg_err_clear()
        }
        scope?.destroy()
        scope = nil
    }
}

// MARK: - Loop callbacks

/// asyncio calls this whenever the poller descriptor becomes readable.
private func asgiDrain(_ context: UInt64, _ args: PyObj?) -> PyObj? {
    guard let worker = currentWorker else { return nil }
    // Timeout 0: asyncio already told us there is something to collect.
    worker.pointee.drain(timeoutMillis: 0)
    return nil
}

/// Periodic housekeeping: idle timeouts and shutdown completion.
private func asgiTimer(_ context: UInt64, _ args: PyObj?) -> PyObj? {
    guard let worker = currentWorker else { return nil }
    worker.pointee.sweepTimeouts()

    // `sweepTimeouts` clears `running` when the shutdown deadline passes, so
    // that a stuck request cannot hold the loop open past the grace period.
    if !worker.pointee.running
        || (worker.pointee.draining && worker.pointee.table.liveCount == 0) {
        if let r = pg_call1(ASGIRuntime.fnStopLoop, ASGIRuntime.loop) {
            pg_decref(r)
        } else {
            pg_err_clear()
        }
        return nil
    }
    if let r = pg_call2(ASGIRuntime.fnArmTimer, ASGIRuntime.loop, ASGIRuntime.timerCallback) {
        pg_decref(r)
    } else {
        pg_err_clear()
    }
    return nil
}

// MARK: - Dispatch

extension Worker {

    mutating func dispatchASGI(_ slot: Int) {
        let c = table[slot]
        guard ASGIRuntime.scope != nil else {
            failRequest(slot, status: 500)
            return
        }

        // A WebSocket upgrade is still an HTTP request at this point; from here
        // it takes a different route entirely.
        if c.pointee.head.flags.contains(.upgrade) {
            let upgradeBase = c.pointee.headBase()
            if let key = websocketKey(slot, base: upgradeBase) {
                if !config.websocketsEnabled {
                    failRequest(slot, status: 501)
                    return
                }
                dispatchWebSocket(slot, key: key, base: upgradeBase)
                return
            }
        }

        // The client tuple is per connection, not per request.
        if c.pointee.clientTuple == nil,
           let addr = c.pointee.remoteAddrObj,
           let port = c.pointee.remotePortObj {
            c.pointee.clientTuple = pg_tuple2(addr, port)
        }

        let base = c.pointee.headBase()
        // A trusted proxy can replace both the client and the scheme, so the
        // per-request values are worked out before the scope is built.
        let forwarded = forwardedInfo(slot, base: base)
        let forwardedClient = forwardedClientTuple(forwarded)
        defer { if let f = forwardedClient { pg_decref(f) } }
        var schemeOverride: PyObj? = nil
        if let https = forwarded.https {
            schemeOverride = https ? Interned[.vHTTPS] : Interned[.vHTTP]
        }

        guard let scopeDict = ASGIRuntime.scope!.build(
                base: base,
                head: c.pointee.head,
                headers: headers,
                client: forwardedClient ?? c.pointee.clientTuple,
                schemeOverride: schemeOverride) else {
            PyError.logPending("building the ASGI scope")
            failRequest(slot, status: 500)
            return
        }
        defer { pg_decref(scopeDict) }

        let token = PollToken.make(slot: slot, generation: c.pointee.generation)
        guard let receiveFn = PyTrampoline.make(asgiReceive, context: token),
              let sendFn = PyTrampoline.make(asgiSend, context: token) else {
            PyError.logPending("creating the ASGI channels")
            failRequest(slot, status: 500)
            return
        }
        c.pointee.receiveCallable = receiveFn
        c.pointee.sendCallable = sendFn

        guard let coro = pg_call3(ASGIRuntime.app, scopeDict, receiveFn, sendFn) else {
            PyError.logPending("calling the application")
            failRequest(slot, status: 500)
            return
        }
        defer { pg_decref(coro) }

        guard let doneCb = PyTrampoline.make(asgiTaskDone, context: token) else {
            PyError.logPending("creating the completion callback")
            failRequest(slot, status: 500)
            return
        }
        defer { pg_decref(doneCb) }

        guard let task = pg_call3(ASGIRuntime.fnSpawn, ASGIRuntime.loop, coro, doneCb) else {
            PyError.logPending("scheduling the application task")
            failRequest(slot, status: 500)
            return
        }
        c.pointee.task = task

        // With the body already complete there is nothing more to read for this
        // request, and leaving READ armed on a level-triggered poller would spin
        // on any pipelined bytes. EPOLLRDHUP still reports a disconnect.
        updateBodyReadInterest(slot)
    }

    /// New body bytes arrived while the application is running.
    mutating func onBodyProgress(_ slot: Int) {
        let c = table[slot]
        if c.pointee.state != .dispatching { return }

        if c.pointee.flags.contains(.peerClosed) && c.pointee.bodyRemaining != 0 {
            c.pointee.flags.insert(.disconnected)
        }
        if c.pointee.bodyRemaining < 0 {
            _ = advanceChunkedBody(slot)
            let d = table[slot]
            if d.pointee.state == .free { return }
            // advanceChunkedBody flips to .dispatching on completion; for ASGI
            // the request is already dispatched, so stay put.
            d.pointee.state = .dispatching
        }
        deliverPendingReceive(slot)
    }

    /// Resolves a `receive()` future if a message is now available.
    ///
    /// Delivering empties the body buffer, so read interest is re-evaluated
    /// afterwards: this is what lifts backpressure once the application has
    /// caught up.
    mutating func deliverPendingReceive(_ slot: Int) {
        let c = table[slot]
        guard let future = c.pointee.pendingReceive else { return }
        guard let message = nextReceiveMessage(slot, blocking: false) else { return }
        c.pointee.pendingReceive = nil
        if let r = pg_call2(ASGIRuntime.fnResolve, future, message) {
            pg_decref(r)
        } else {
            PyError.logPending("resolving receive()")
        }
        pg_decref(message)
        pg_decref(future)
        updateBodyReadInterest(slot)
    }

    /// Builds the next ASGI receive message, or nil when nothing is ready.
    mutating func nextReceiveMessage(_ slot: Int, blocking: Bool) -> PyObj? {
        let c = table[slot]

        if c.pointee.flags.contains(.websocketMode) {
            return nextWebSocketMessage(slot)
        }

        // Once the response is complete the request is over as far as the
        // application is concerned, whatever is left of the body. ASGI says
        // receive() reports the disconnect then; parking instead would hold the
        // task open, and the connection is not reusable until the task ends.
        if c.pointee.flags.contains(.responseComplete) {
            c.pointee.flags.insert(.disconnectSent)
            return ASGIMessage.httpDisconnect()
        }

        if c.pointee.flags.contains(.disconnected) || c.pointee.flags.contains(.peerClosed) {
            if c.pointee.flags.contains(.bodyDelivered)
                || c.pointee.flags.contains(.disconnected) {
                c.pointee.flags.insert(.disconnectSent)
                return ASGIMessage.httpDisconnect()
            }
        }

        let available = c.pointee.body.readableBytes
        let complete = c.pointee.bodyRemaining == 0
        if available > 0 {
            let bodyObj = UnsafePointer(c.pointee.body.readPointer)
                .withMemoryRebound(to: CChar.self, capacity: available) { p in
                    pg_bytes(p, pg_ssize_t(available))
                }
            guard let bodyObj else { return nil }
            defer { pg_decref(bodyObj) }
            c.pointee.body.clear()
            if complete { c.pointee.flags.insert(.bodyDelivered) }
            return ASGIMessage.httpRequest(body: bodyObj, moreBody: !complete)
        }
        if complete && !c.pointee.flags.contains(.bodyDelivered) {
            c.pointee.flags.insert(.bodyDelivered)
            return ASGIMessage.httpRequest(body: Interned.emptyBytes, moreBody: false)
        }
        return nil
    }

    // MARK: - Response

    mutating func asgiResponseStart(_ slot: Int, message: PyObj) -> Bool {
        let c = table[slot]
        if c.pointee.flags.contains(.responseStarted) {
            pg_err_set_str(pg_exc_runtime(), "http.response.start sent twice")
            return false
        }
        guard let statusObj = pg_dict_get(message, Interned[.status]) else {
            pg_err_set_str(pg_exc_value(), "http.response.start needs a status")
            return false
        }
        let status = Int(pg_int_as_long(statusObj))
        if status < 100 || status > 599 {
            pg_err_set_str(pg_exc_value(), "status out of range")
            return false
        }

        dates.refresh()
        c.pointee.write.reserve(512)
        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: status)

        var seen: ResponseHeaderKind = []
        var declaredLength = -1

        if let headerList = pg_dict_get(message, Interned[.headers]),
           pg_is(headerList, Interned.none) == 0 {
            guard PySeq.isSequence(headerList) else {
                pg_err_set_str(pg_exc_value(),
                               "http.response.start headers must be a list of pairs")
                return false
            }
            let count = PySeq.count(headerList)
            var i = 0
            while i < count {
                // The specification says "an iterable of [name, value]
                // two-item iterables", so a list pair is exactly as valid as a
                // tuple pair; frameworks emit both.
                guard let item = PySeq.item(headerList, i),
                      let (nameObj, valueObj) = PySeq.pair(item) else {
                    pg_err_set_str(pg_exc_value(),
                                   "each response header must be a (name, value) pair")
                    return false
                }
                i += 1
                guard let nameView = PyBytesView.of(nameObj) else {
                    pg_err_set_str(pg_exc_value(), "a response header name is not bytes")
                    return false
                }
                guard let valueView = PyBytesView.of(valueObj) else {
                    nameView.release()
                    pg_err_set_str(pg_exc_value(), "a response header value is not bytes")
                    return false
                }
                let name = nameView.span
                let value = valueView.span

                let kind = HTTPResponseWriter.classify(name)
                seen.formUnion(kind)
                var failure: StaticString? = nil
                if kind.contains(.contentLength) {
                    declaredLength = parseDecimal(value.base, value.count)
                    if declaredLength < 0 { failure = "malformed content-length" }
                    // Recorded, not echoed: the framing decision below emits
                    // exactly one Content-Length.
                } else if kind.contains(.transferEncoding) {
                    // Transfer framing belongs to the server.
                } else if kind.contains(.connection) {
                    if containsTokenLowercased(value.base, value.count, "close") {
                        c.pointee.flags.remove(.keepAlive)
                    }
                } else if !HTTPResponseWriter.writeHeader(&c.pointee.write,
                                                          name: name, value: value) {
                    failure = "header contains a control character"
                }
                valueView.release()
                nameView.release()
                if let failure {
                    pg_err_set_str(pg_exc_value(), staticCString(failure))
                    return false
                }
            }
        }

        if HTTPResponseWriter.statusForbidsBody(status) {
            declaredLength = 0
            c.pointee.flags.insert(.suppressBody)
        }

        if declaredLength >= 0 {
            c.pointee.responseRemaining = declaredLength
            HTTPResponseWriter.writeContentLength(&c.pointee.write, declaredLength)
        } else if c.pointee.head.httpMinor == 1 {
            c.pointee.responseRemaining = -1
            c.pointee.flags.insert(.chunkedResponse)
            HTTPResponseWriter.writeChunkedEncoding(&c.pointee.write)
        } else {
            c.pointee.responseRemaining = -1
            c.pointee.flags.remove(.keepAlive)
        }

        if !seen.contains(.date) { HTTPResponseWriter.writeDate(&c.pointee.write, dates) }
        if !seen.contains(.server) { c.pointee.write.write("Server: peregrine\r\n") }
        HTTPResponseWriter.writeConnection(&c.pointee.write,
                                           keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&c.pointee.write)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: status)
        return true
    }

    mutating func asgiResponseBody(_ slot: Int, message: PyObj) -> Bool {
        let c = table[slot]
        if !c.pointee.flags.contains(.responseStarted) {
            pg_err_set_str(pg_exc_runtime(), "http.response.body before http.response.start")
            return false
        }

        if c.pointee.flags.contains(.responseComplete) {
            pg_err_set_str(pg_exc_runtime(),
                           "http.response.body after the response was completed")
            return false
        }

        var more = false
        if let moreObj = pg_dict_get(message, Interned[.moreBody]) {
            more = pg_is_true(moreObj) == 1
        }

        // A declared Content-Length is a promise to the client and to every
        // intermediary between here and it. Both ways of breaking it are
        // handled the same way: keep the promise on the wire, tell the
        // application it has a bug, and close the connection so that nothing
        // is left half-said and no later request reuses it.
        let suppress = c.pointee.flags.contains(.suppressBody)
        var overflow = false

        if let bodyObj = pg_dict_get(message, Interned[.body]), !suppress {
            var data: UnsafePointer<CChar>?
            var len: pg_ssize_t = 0
            var owner: PyObj?
            if pg_as_bytes(bodyObj, &data, &len, &owner) != 0 { return false }
            defer { pg_release_bytes(owner) }
            if len > 0, let data {
                var take = Int(len)
                if c.pointee.responseRemaining >= 0 {
                    // Writing past the declared length would run into the next
                    // response on a keep-alive connection, which is response
                    // smuggling however innocent the intent.
                    if take > c.pointee.responseRemaining {
                        take = c.pointee.responseRemaining
                        overflow = true
                    }
                    c.pointee.responseRemaining -= take
                }
                if take > 0 {
                    let p = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
                    if c.pointee.flags.contains(.chunkedResponse) {
                        HTTPResponseWriter.writeChunk(&c.pointee.write, p, take)
                    } else {
                        c.pointee.write.write(p, take)
                    }
                }
            }
        }

        // The other half of the same promise: a client told to expect N bytes
        // and given fewer waits for the rest until its own timeout.
        let short = !more && !suppress && c.pointee.responseRemaining > 0

        if !more || overflow || short {
            if c.pointee.flags.contains(.chunkedResponse) && !suppress {
                HTTPResponseWriter.writeLastChunk(&c.pointee.write)
            }
            c.pointee.flags.insert(.responseComplete)
            c.pointee.state = .writing
        }
        if overflow || short {
            c.pointee.flags.remove(.keepAlive)
        }
        _ = flush(slot)

        // A task already parked in receive() when the response completed has to
        // be woken and told so, or it waits for a body the server will never
        // read and the connection waits for the task.
        if c.pointee.flags.contains(.responseComplete) {
            deliverPendingReceive(slot)
        }

        if overflow {
            pg_err_set_str(pg_exc_runtime(),
                           "response body is longer than the declared Content-Length")
            return false
        }
        if short {
            pg_err_set_str(pg_exc_runtime(),
                           "response ended before the declared Content-Length was sent")
            return false
        }
        return true
    }

    /// Called when the application task finishes, successfully or not.
    mutating func asgiTaskFinished(_ slot: Int, error: Bool) {
        let c = table[slot]
        if let t = c.pointee.task {
            pg_decref(t)
            c.pointee.task = nil
        }
        if let s = c.pointee.sendCallable { pg_decref(s); c.pointee.sendCallable = nil }
        if let r = c.pointee.receiveCallable { pg_decref(r); c.pointee.receiveCallable = nil }
        if let f = c.pointee.pendingReceive { pg_decref(f); c.pointee.pendingReceive = nil }

        if c.pointee.flags.contains(.websocketMode) {
            websocketTaskFinished(slot, error: error)
            return
        }

        if !c.pointee.flags.contains(.responseStarted) {
            failRequest(slot, status: error ? 500 : 500)
            return
        }
        if !c.pointee.flags.contains(.responseComplete) {
            // The application stopped mid-response; there is no valid way to
            // terminate the message except by closing.
            Log.warn("application finished without completing the response")
            closeConnection(slot)
            return
        }
        if c.pointee.state == .writing && c.pointee.write.isEmpty {
            finishResponse(slot)
        }
    }

    /// After a response is fully flushed, ASGI connections may still be waiting
    /// on the application task, so recycling is deferred until both are done.
    @inlinable
    public func asgiAwaitingTask(_ slot: Int) -> Bool {
        appProtocol == .asgi && table[slot].pointee.task != nil
    }

    // MARK: - Write backpressure

    /// Whether the socket has fallen far enough behind that the application
    /// must stop producing.
    @inlinable
    public func writerShouldPause(_ slot: Int) -> Bool {
        table[slot].pointee.write.readableBytes > config.writeHighWaterMark
    }

    /// The Future `await send()` should suspend on. Owned reference.
    ///
    /// One Future serves however many sends pile up: a well-behaved
    /// application awaits each send before issuing the next, and one that does
    /// not still ends up waiting for the same drain.
    mutating func drainWaiter(_ slot: Int) -> PyObj? {
        let c = table[slot]
        if let existing = c.pointee.drainWaiter {
            pg_incref(existing)
            return existing
        }
        guard let future = pg_call_method0(ASGIRuntime.loop, Interned[.nCreateFuture]) else {
            PyError.logPending("creating a drain future")
            return nil
        }
        c.pointee.drainWaiter = future
        // The socket is not currently draining on its own: nothing armed write
        // interest, because the buffer filled up inside this send.
        setInterest(slot, [.read, .write])
        pg_incref(future)
        return future
    }
}

// MARK: - Channel callables

@inline(__always)
func resolveSlot(_ token: UInt64) -> Int {
    guard let worker = currentWorker else { return -1 }
    let slot = PollToken.slot(token)
    if slot >= worker.pointee.table.capacity { return -1 }
    let c = worker.pointee.table[slot]
    if c.pointee.state == .free { return -1 }
    if c.pointee.generation != PollToken.generation(token) { return -1 }
    return slot
}

func asgiSend(_ token: UInt64, _ args: PyObj?) -> PyObj? {
    guard let args, pg_tuple_size(args) == 1, let message = pg_tuple_get(args, 0) else {
        pg_err_set_str(pg_exc_type(), "send() takes exactly one message")
        return nil
    }
    guard pg_is_dict(message) != 0 else {
        pg_err_set_str(pg_exc_type(), "an ASGI message must be a dict")
        return nil
    }

    let slot = resolveSlot(token)
    if slot < 0 {
        // The connection is gone. Applications routinely send after a client
        // disconnects; swallowing it matches every other ASGI server.
        return PyImmediate.make(nil)
    }
    guard let worker = currentWorker else { return PyImmediate.make(nil) }

    guard let typeObj = pg_dict_get(message, Interned[.type]) else {
        pg_err_set_str(pg_exc_value(), "an ASGI message needs a type")
        return nil
    }
    var n: pg_ssize_t = 0
    guard let typeStr = pg_str_utf8_data(typeObj, &n) else { return nil }
    let t = UnsafeRawPointer(typeStr).assumingMemoryBound(to: UInt8.self)

    if worker.pointee.table[slot].pointee.flags.contains(.websocketMode) {
        if !worker.pointee.websocketSend(slot, type: t, typeLength: Int(n), message: message) {
            return nil
        }
    } else if n == 19 && equalsExact(t, 19, "http.response.start") {
        if !worker.pointee.asgiResponseStart(slot, message: message) { return nil }
    } else if n == 18 && equalsExact(t, 18, "http.response.body") {
        if !worker.pointee.asgiResponseBody(slot, message: message) { return nil }
    } else {
        pg_err_set_str(pg_exc_value(), "unsupported ASGI message type")
        return nil
    }

    // Writing may have closed the connection, so the slot is re-checked rather
    // than reused.
    let after = resolveSlot(token)
    if after >= 0, worker.pointee.writerShouldPause(after) {
        if let waiter = worker.pointee.drainWaiter(after) { return waiter }
    }
    // Completed synchronously: hand back an awaitable that never suspends.
    return PyImmediate.make(nil)
}

func asgiReceive(_ token: UInt64, _ args: PyObj?) -> PyObj? {
    let slot = resolveSlot(token)
    if slot < 0 {
        guard let msg = ASGIMessage.httpDisconnect() else { return nil }
        defer { pg_decref(msg) }
        return PyImmediate.make(msg)
    }
    guard let worker = currentWorker else { return nil }
    let c = worker.pointee.table[slot]

    if let ready = worker.pointee.nextReceiveMessage(slot, blocking: false) {
        defer { pg_decref(ready) }
        // Taking the buffered bytes is what makes room for the next read.
        worker.pointee.updateBodyReadInterest(slot)
        return PyImmediate.make(ready)
    }

    // Nothing to deliver yet: park on a Future the server resolves when more
    // body arrives or the client disconnects.
    if let existing = c.pointee.pendingReceive {
        pg_incref(existing)
        return existing
    }
    guard let future = pg_call_method0(ASGIRuntime.loop, Interned[.nCreateFuture]) else {
        PyError.logPending("creating a receive future")
        return nil
    }
    c.pointee.pendingReceive = future
    pg_incref(future)
    return future
}

func asgiTaskDone(_ token: UInt64, _ args: PyObj?) -> PyObj? {
    guard let worker = currentWorker else { return nil }
    var failed = false
    if let args, pg_tuple_size(args) == 1, let task = pg_tuple_get(args, 0) {
        if let info = pg_call1(ASGIRuntime.fnTaskError, task) {
            if pg_is(info, Interned.none) == 0 {
                failed = true
                var n: pg_ssize_t = 0
                if let text = pg_str_utf8_data(info, &n) {
                    Log.error("application task failed")
                    Log.raw(UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), Int(n))
                }
            }
            pg_decref(info)
        } else {
            pg_err_clear()
        }
    }
    let slot = resolveSlot(token)
    if slot >= 0 {
        worker.pointee.asgiTaskFinished(slot, error: failed)
    }
    return nil
}
