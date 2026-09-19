//===----------------------------------------------------------------------===//
// The engine side of the handler API: dispatching to a route, the response
// sink every handler's answer goes through, and what a Request reads.
//
// The sink is the one place a handler's status, headers and body become a
// response, on every protocol. It frames the body for the transport, adds the
// server's own headers unless the handler set them, and holds the body to any
// Content-Length the handler declared: a longer one is cut to it, and a shorter
// one ends the exchange the way a truncated message must -- the HTTP/1.1
// connection closed, the stream reset -- so a client never takes it for whole.
//
// A request's headers are read from the worker's shared header table, which the
// next head parsed anywhere on the worker overwrites. `headersOwner` says whose
// they are, and a request whose table has moved on has its head parsed again:
// the head bytes stay put until the request is answered, so that costs a parse
// and never a copy, and the common request that is answered before anything
// else is parsed pays nothing.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import Tracing

/// Which request the worker's header table was last filled for.
struct HeaderTableOwner {
    var slot: Int32 = -1
    var generation: UInt32 = 0
    var requestId: UInt32 = 0
}

/// Walks the records `addResponseHeader` wrote: a little-endian 16-bit name
/// length, a 16-bit value length, the name in lowercase, then the value.
@inline(__always)
func forEachHeaderRecord(_ records: borrowing ByteBuffer, _ body: (ByteSpan, ByteSpan) -> Void) {
    let total = records.readableBytes
    if total == 0 { return }
    let base = UnsafePointer(records.readPointer)
    var at = 0
    while at &+ 4 <= total {
        let p = base + at
        let nameLength = Int(p[0]) | Int(p[1]) << 8
        let valueLength = Int(p[2]) | Int(p[3]) << 8
        body(ByteSpan(p + 4, nameLength), ByteSpan(p + 4 + nameLength, valueLength))
        at &+= 4 &+ nameLength &+ valueLength
    }
}

extension Worker {

    // MARK: - The header table

    /// Records that the header table now holds the request on `slot`.
    @inline(__always)
    mutating func ownHeaders(_ slot: Int) {
        let c = table[slot]
        headersOwner = HeaderTableOwner(slot: Int32(truncatingIfNeeded: slot),
                                        generation: c.pointee.generation,
                                        requestId: c.pointee.requestId)
    }

    /// Makes the header table describe the request on `slot`.
    @inline(__always)
    mutating func ensureHeaders(_ slot: Int) {
        let c = table[slot]
        if headersOwner.slot == Int32(truncatingIfNeeded: slot)
            && headersOwner.generation == c.pointee.generation
            && headersOwner.requestId == c.pointee.requestId { return }
        reparseHeaders(slot)
    }

    mutating func reparseHeaders(_ slot: Int) {
        let c = table[slot]
        var scratch = HTTPRequestHead()
        _ = HTTPParser.parse(c.pointee.headBase(), c.pointee.head.headEnd,
                             maxHeadSize: config.maxHeadSize,
                             maxHeaders: config.maxHeaders,
                             headers: headers,
                             head: &scratch)
        ownHeaders(slot)
    }

    /// Whether an HTTP/1.1 request asks to become a WebSocket.
    mutating func isWebSocketUpgrade(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.isStream || !c.pointee.head.flags.contains(.upgrade) { return false }
        ensureHeaders(slot)
        let base = c.pointee.headBase()
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 7,
                  equalsLowercased(base + Int(h.name.offset), 7, "upgrade") else { continue }
            let value = h.value.span(in: base)
            return value.count == 9 && equalsLowercased(value.base, 9, "websocket")
        }
        return false
    }

    // MARK: - Dispatch

    /// Matches the request against the installed routes and runs its handler,
    /// or answers 404.
    mutating func dispatchRoute(_ slot: Int) {
        guard let installed = application else {
            if serveSPAFallback(slot) { return }
            respond(slot, status: 404, nil, 0)
            return
        }
        let c = table[slot]
        let path = c.pointee.head.path
        let headBase = c.pointee.headBase()
        // --root-path: routes are matched on the path within the mount. A
        // path outside it is matched as it came, as behind a proxy that has
        // already taken the prefix off.
        let stripped = rootPath.strip(headBase + Int(path.offset), path.count)
        let base = stripped.0
        var count = stripped.1
        var route = installed.pointee.routes.match(c.pointee.head.method, base, count,
                                                   into: &c.pointee.routeParameters)
        if route < 0, let trimmed = pathWithoutTrailingSlash(installed, base, count, &c.pointee.routeParameters) {
            if installed.pointee.trailingSlash == .redirect {
                if redirectWithoutTrailingSlash(slot) { return }
            } else {
                count = trimmed
                route = installed.pointee.routes.match(c.pointee.head.method, base, count,
                                                       into: &c.pointee.routeParameters)
            }
        }
        if route < 0 {
            // No route is an ordinary answer, not a failure: the connection
            // stays open for the next request.
            //
            // A path some other method would have matched is a 405, and says
            // which methods in Allow -- RFC 9110 requires the header, and a
            // client told only "not found" goes looking for a URL that exists.
            let allowed = installed.pointee.routes.allowedMethods(base, count,
                                                                  into: &c.pointee.routeParameters)
            guard !allowed.isEmpty else {
                let fallback = installed.pointee.fallbacks.isEmpty
                    ? -1 : installed.pointee.fallbacks.match(base, count)
                guard fallback >= 0 else {
                    if serveSPAFallback(slot) { return }
                    respond(slot, status: 404, nil, 0)
                    return
                }
                c.pointee.routeParameters = RouteParameters()
                c.pointee.routeOffset = Int32(truncatingIfNeeded: base - headBase)
                c.pointee.routeIndex = fallback
                let allowedMs = installed.pointee.deadlines[Int(fallback)]
                if allowedMs > 0 { armDeadline(slot, ms: UInt64(allowedMs)) }
                runHandler(slot, installed.pointee.handlers[Int(fallback)])
                return
            }
            if c.pointee.head.method == .options && answerPreflight(slot, allowed: allowed, base, count) {
                return
            }
            var value = ""
            for method in allowed {
                guard let token = method.token else { continue }
                if !value.isEmpty { value += ", " }
                value += "\(token)"
            }
            let name: StaticString = "Allow"
            var bytes = value
            bytes.withUTF8 { v in
                _ = addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                      ByteSpan(v.baseAddress!, v.count))
            }
            respond(slot, status: 405, nil, 0)
            return
        }
        c.pointee.routeOffset = Int32(truncatingIfNeeded: base - headBase)
        c.pointee.routeIndex = route
        let allowed = installed.pointee.deadlines[Int(route)]
        if allowed > 0 { armDeadline(slot, ms: UInt64(allowed)) }
        runHandler(slot, installed.pointee.handlers[Int(route)])
    }

    /// Calls `handler` with views of the request on `slot`, and makes sure the
    /// request is answered one way or another once it returns.
    mutating func runHandler(_ slot: Int, _ handler: Handler) {
        let c = table[slot]
        let generation = c.pointee.generation
        let requestId = c.pointee.requestId
        withUnsafeMutablePointer(to: &self) { worker in
            let request = Request(worker: worker, slot: slot)
            var response = Response(worker: worker, slot: slot,
                                    generation: generation, requestId: requestId)
            do {
                // Traced, the handler runs inside its request's span, which
                // is what the spans it starts, and the calls it makes, are
                // children of.
                if let span = worker.pointee.requestSpan(slot) {
                    try ServiceContext.$current.withValue(span.context) {
                        try handler(request, &response)
                    }
                } else {
                    try handler(request, &response)
                }
            } catch {
                worker.pointee.handlerThrew(slot, generation: generation,
                                            requestId: requestId, error)
                return
            }
            worker.pointee.handlerReturned(slot, generation: generation, requestId: requestId)
        }
    }

    /// Whether the slot still holds the very request a handler was given.
    ///
    /// A handler that waits on something other than the engine is not unwound
    /// when its request is cancelled: it resumes, and by then the slot may
    /// hold a different request. Everything a `Response` does is checked
    /// against this first, so a late answer is dropped rather than sent to
    /// whoever took the slot.
    @inline(__always)
    func stillHolds(_ slot: Int, generation: UInt32, requestId: UInt32) -> Bool {
        let c = table[slot]
        return c.pointee.state != .free
            && c.pointee.generation == generation
            && c.pointee.requestId == requestId
            // Timed out: the request is still on the slot, but it has been
            // answered 504 and is no longer this handler's to speak for.
            && !c.pointee.flags.contains(.timedOut)
    }

    /// The request on `slot` ran past the deadline its route was given.
    ///
    /// The handler may be waiting, in which case it is unwound, or running,
    /// which nothing can preempt: a worker is one thread. Either way the
    /// client is answered now, and `.timedOut` makes everything the handler
    /// does afterwards a no-op rather than an error in the log.
    mutating func deadlineFired(_ slot: Int, generation: UInt32, requestId: UInt32) {
        let c = table[slot]
        guard c.pointee.state == .dispatching,
              c.pointee.generation == generation,
              c.pointee.requestId == requestId,
              !c.pointee.flags.contains(.responseStarted) else { return }
        Log.error("a handler passed its deadline; answering 504")
        noteHandlerFailure(slot, "the handler passed its deadline")
        c.pointee.flags.insert(.timedOut)
        let task = c.pointee.contKind == .task ? Int(c.pointee.contTask) : -1
        // A synchronous handler parked on a timer of its own is waiting for
        // an answer nobody wants now; a task is cancelled after the answer
        // goes out, so its unwinding cannot answer over the top of it.
        if task < 0 { clearContinuation(slot) }
        respondError(slot, status: .gatewayTimeout, reason: "the handler passed its deadline")
        if task >= 0 { handlerTasks?.cancel(task) }
        // A deadline does not go through `cancelOps` while a task holds the
        // slot, so the waits that are not the engine's are ended here.
        wakeCancelWaiters(slot)
    }

    /// Whether the request a handler was given is still the one on the slot,
    /// unanswered and not parked.
    @inline(__always)
    func handlerOwes(_ slot: Int, generation: UInt32, requestId: UInt32) -> Bool {
        let c = table[slot]
        return c.pointee.state == .dispatching
            && c.pointee.generation == generation
            && c.pointee.requestId == requestId
            && !c.pointee.isParked
            && !c.pointee.flags.contains(.responseStarted)
    }

    func handlerFinished(_ slot: Int, generation: UInt32, requestId: UInt32) -> Bool {
        !handlerOwes(slot, generation: generation, requestId: requestId)
    }

    mutating func handlerReturned(_ slot: Int, generation: UInt32, requestId: UInt32) {
        // A request on a task is the task's to settle (`taskFinished`).
        guard table[slot].pointee.contKind != .task,
              handlerOwes(slot, generation: generation, requestId: requestId) else { return }
        Log.error("a handler returned without answering or waiting; answering 500")
        noteHandlerFailure(slot, "the handler returned without answering")
        respond(slot, status: 500, nil, 0)
    }

    mutating func handlerThrew(_ slot: Int, generation: UInt32, requestId: UInt32, _ error: any Error) {
        // An error the application planned for is an answer, not a fault, so
        // it is not logged as one.
        let answer = error as? any ResponseError
        if answer == nil {
            let description = String(describing: error)
            Log.error { line in
                line.str("handler threw: ")
                description.withCString { line.cstr($0) }
            }
            if tracer != nil, stillHolds(slot, generation: generation, requestId: requestId) {
                requestSpan(slot)?.recordError(error)
            }
            noteHandlerFailure(slot, "handler threw: " + description)
        }
        let c = table[slot]
        guard c.pointee.state != .free, c.pointee.generation == generation,
              c.pointee.requestId == requestId else { return }
        if c.pointee.state == .dispatching && !c.pointee.flags.contains(.responseStarted) {
            // A wait armed before the throw is for an answer that is not coming.
            clearContinuation(slot)
            if let answer {
                respondError(slot, status: answer.status, reason: answer.reason,
                             fields: answer.fields)
            } else {
                respond(slot, status: 500, nil, 0)
            }
        }
    }

    /// Parks the request on a timer, to call `handler` when it fires.
    mutating func suspend(_ slot: Int, milliseconds: UInt64, then handler: @escaping Handler) {
        let c = table[slot]
        guard c.pointee.state == .dispatching, !c.pointee.isParked,
              !c.pointee.flags.contains(.responseStarted) else {
            Log.error("a handler waited on a request that was already answered or waiting")
            return
        }
        if !armDelay(slot, ms: milliseconds, kind: .handler) {
            respond(slot, status: 503, nil, 0)
            return
        }
        c.pointee.contHandler = handler
    }

    // MARK: - Response headers

    mutating func addResponseHeader(_ slot: Int, _ name: ByteSpan, _ value: ByteSpan) -> Bool {
        let c = table[slot]
        guard c.pointee.state == .dispatching, !c.pointee.flags.contains(.responseStarted),
              name.count > 0, name.count <= 0xFFFF, value.count <= 0xFFFF else { return false }
        var i = 0
        while i < name.count {
            if !isTokenChar(name.base[i]) { return false }
            i &+= 1
        }
        i = 0
        while i < value.count {
            if !isFieldValueChar(value.base[i]) { return false }
            i &+= 1
        }
        if HTTPResponseWriter.classify(name) == .contentLength {
            guard ByteSpan(value.base, value.count).integer != nil else { return false }
        }
        let records = UnsafeMutablePointer(mutating: c).pointer(to: \.responseHeaders)!
        records.pointee.reserve(4 &+ name.count &+ value.count)
        records.pointee.writeByte(UInt8(truncatingIfNeeded: name.count))
        records.pointee.writeByte(UInt8(truncatingIfNeeded: name.count >> 8))
        records.pointee.writeByte(UInt8(truncatingIfNeeded: value.count))
        records.pointee.writeByte(UInt8(truncatingIfNeeded: value.count >> 8))
        i = 0
        while i < name.count {
            records.pointee.writeByte(asciiLower(name.base[i]))
            i &+= 1
        }
        if value.count > 0 { records.pointee.write(value) }
        return true
    }

    // MARK: - The response sink

    /// Answers the request on `slot` with `status`, the handler's headers and
    /// `count` bytes of `body`.
    ///
    /// `streaming` sends only the head, with no length unless the handler
    /// declared one, and leaves the response open for `streamBody` to write
    /// and `finishStreamingResponse` to end (StreamingResponse.swift). A
    /// response that has no body to stream -- HEAD, 204, 304 -- is sent whole.
    mutating func respond(_ slot: Int, status: Int, _ body: UnsafePointer<UInt8>?, _ count: Int,
                          streaming: Bool = false) {
        var body = body
        var count = count
        let c = table[slot]
        guard c.pointee.state == .dispatching, !c.pointee.isParked,
              !c.pointee.flags.contains(.responseStarted) else {
            Log.error("a handler answered a request that was already answered or waiting")
            return
        }
        if let hooks = takeSendHooks(slot) {
            respond(slot, through: hooks, status: status, body, count, streaming: streaming)
            return
        }

        // What the handler said about its own response.
        var kinds: ResponseHeaderKind = []
        var declared = -1
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            let kind = HTTPResponseWriter.classify(name)
            kinds.formUnion(kind)
            if kind == .contentLength, let n = value.integer { declared = n }
        }

        let suppress = c.pointee.flags.contains(.suppressBody)
        let forbids = HTTPResponseWriter.statusForbidsBody(status)
        // The length the response states, or -1 for none.
        var length: Int
        // The bytes that go out, and how many the stated length is still owed
        // once they have.
        var sending = forbids ? 0 : count
        var short = 0
        if forbids {
            // A 304 keeps the length of the representation it stands for, when
            // the handler gave one; a 204 and a 1xx never have one.
            length = status == 304 ? declared : -1
        } else if streaming {
            // Nobody knows the length of a body that has not been written.
            length = declared
        } else if declared >= 0 {
            length = declared
            if count > declared {
                sending = declared
            } else if count < declared && !suppress {
                short = declared - count
            }
        } else {
            length = count
        }
        // A HEAD response states the GET's length and sends none of it.
        if suppress { sending = 0 }
        let misframed = !streaming && !forbids && declared >= 0 && declared != count && !suppress
        // What a streamed body is held to as it is written, -1 for no limit.
        // Counted in the application's bytes, before any compression.
        let open = streaming && !forbids && !suppress
        if open { c.pointee.responseRemaining = declared }

        // --cache-size: the copy is of the response as the application made
        // it, and is compressed afresh for each client it is served to.
        if c.pointee.capture.active {
            captureResponseHead(slot, status: status)
            if !open {
                if sending > 0, let body { c.pointee.capture.append(body, sending) }
                cacheCaptureFinish(slot, complete: short == 0 && !misframed)
            }
        }

        // --compress. A buffered body is compressed whole and states its
        // compressed length; a streamed one is compressed as it is written.
        var encoded = ByteBuffer()
        defer { encoded.destroy() }
        if config.compress {
            switch chooseCoding(slot, status: status, count: count, declared: declared,
                                streaming: open, forbids: forbids, suppress: suppress, misframed: misframed) {
            case .identity:
                break
            case let coding where open:
                if c.pointee.encoder.start(coding) {
                    announceCoding(slot, coding)
                    length = -1
                }
            case let coding:
                var encoder = ResponseEncoder()
                if encoder.start(coding), let source = body,
                   encoder.encode(source, sending, flush: false, into: &encoded, chunked: false),
                   encoder.finish(into: &encoded, chunked: false) {
                    announceCoding(slot, coding)
                    body = UnsafePointer(encoded.readPointer)
                    count = encoded.readableBytes
                    sending = count
                    length = count
                } else {
                    encoder.destroy()
                    encoded.clear()
                }
            }
        }

        if c.pointee.isH3Stream {
            respondH3(slot, status: status, body, sending, length: length, short: short, kinds: kinds,
                      open: open)
            return
        }
        if c.pointee.isStream {
            respondH2(slot, status: status, body, sending, length: length, short: short, kinds: kinds,
                      open: open)
            return
        }

        logAccess(slot, status: status, bodyToCome: open)
        dates.refresh()
        c.pointee.flags.insert(.responseStarted)
        // A body that disagrees with its own Content-Length leaves the
        // connection with no reliable framing, so it is the last response on
        // it: nothing pipelined behind it is read as a request.
        if misframed { c.pointee.flags.remove(.keepAlive) }
        let out = UnsafeMutablePointer(mutating: c).pointer(to: \.write)!
        HTTPResponseWriter.writeStatusLine(&out.pointee, status: status)
        if !kinds.contains(.date) { HTTPResponseWriter.writeDate(&out.pointee, dates) }
        if !kinds.contains(.server) { out.pointee.write("Server: garuda\r\n") }
        writeServerHeaders(slot, &out.pointee, skipping: kinds)
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            let kind = HTTPResponseWriter.classify(name)
            // The server frames the message and manages the connection.
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            _ = HTTPResponseWriter.writeHeader(&out.pointee, name: name, value: value)
        }
        if length >= 0 {
            HTTPResponseWriter.writeContentLength(&out.pointee, length)
        } else if open {
            // An HTTP/1.0 client has no chunked framing, so the end of the
            // body is the end of the connection.
            if c.pointee.head.httpMinor >= 1 {
                HTTPResponseWriter.writeChunkedEncoding(&out.pointee)
                c.pointee.flags.insert(.chunkedResponse)
            } else {
                c.pointee.flags.remove(.keepAlive)
            }
        }
        HTTPResponseWriter.writeConnection(&out.pointee, keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&out.pointee)
        if sending > 0, let body {
            // A large body still in the handler's array -- not compressed
            // into another buffer on the way -- is written from it.
            if sending >= Worker.heldBodyMinimum, let array = answeringFrom,
               array.withUnsafeBufferPointer({ $0.baseAddress == body }) {
                c.pointee.heldBody = array
                c.pointee.heldBodyOffset = 0
                c.pointee.heldBodyEnd = sending
            } else {
                out.pointee.write(body, sending)
            }
        }
        if open {
            // Still the handler's: the head goes now, and the body as it is
            // written.
            c.pointee.flags.insert(.streamingResponse)
            c.pointee.eventKeepAliveMs = 0
            _ = flush(slot)
            return
        }
        c.pointee.state = .writing
        _ = flush(slot)
    }

    mutating func respondH2(_ slot: Int, status: Int, _ body: UnsafePointer<UInt8>?, _ sending: Int,
                            length: Int, short: Int, kinds: ResponseHeaderKind, open: Bool) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h2 = table[parent].pointee.h2 else {
            closeConnection(slot)
            return
        }
        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        h2.encoder.encodeStatus(status, into: &block)
        if length >= 0 {
            var digits = ByteBuffer()
            defer { digits.destroy() }
            digits.writeDecimal(length)
            encodeStatic(h2, "content-length", UnsafePointer(digits.readPointer),
                         digits.readableBytes, into: &block)
        }
        if !kinds.contains(.date) {
            encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !kinds.contains(.server) { encodeStatic(h2, "server", "garuda", into: &block) }
        encodeServerHeaders(slot, h2, into: &block, skipping: kinds)
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            let kind = HTTPResponseWriter.classify(name)
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            h2.encoder.encode(name: name.base, nameLength: name.count,
                              value: value.count > 0 ? value.base : emptyH2Byte,
                              valueLength: value.count, into: &block)
        }
        let endStream = sending == 0 && short == 0 && !open
        writeHeaderBlock(slot, h2, block: &block, endStream: endStream)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: status, bodyToCome: open)
        if open {
            c.pointee.flags.insert(.streamingResponse)
            c.pointee.eventKeepAliveMs = 0
            _ = flush(parent)
            return
        }
        if endStream {
            c.pointee.flags.insert(.responseComplete)
            _ = flush(parent)
            closeStream(slot, resetWith: nil)
            return
        }
        if sending > 0, let body { c.pointee.write.write(body, sending) }
        // What the stated length is still owed: the stream flush resets a
        // stream that ends with any of it outstanding.
        c.pointee.responseRemaining = short > 0 ? short : -1
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    mutating func respondH3(_ slot: Int, status: Int, _ body: UnsafePointer<UInt8>?, _ sending: Int,
                            length: Int, short: Int, kinds: ResponseHeaderKind, open: Bool) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(status, into: &block)
        if length >= 0 {
            var digits = ByteBuffer()
            defer { digits.destroy() }
            digits.writeDecimal(length)
            encodeStaticH3(h3, "content-length", UnsafePointer(digits.readPointer),
                           digits.readableBytes, into: &block)
        }
        if !kinds.contains(.date) {
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !kinds.contains(.server) { encodeStaticH3(h3, "server", "garuda", into: &block) }
        encodeServerHeadersH3(slot, h3, into: &block, skipping: kinds)
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            let kind = HTTPResponseWriter.classify(name)
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            h3.encoder.encode(name: name.base, nameLength: name.count,
                              value: value.count > 0 ? value.base : emptyH3Byte,
                              valueLength: value.count, into: &block)
        }
        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: status, bodyToCome: open)
        if open {
            c.pointee.flags.insert(.streamingResponse)
            c.pointee.eventKeepAliveMs = 0
            flushQUIC(parent)
            return
        }
        if sending == 0 && short == 0 {
            c.pointee.flags.insert(.responseComplete)
            c.pointee.flags.insert(.endStreamSent)
            h3.quic.send(c.pointee.qstreamID, emptyH3Byte, 0, fin: true)
            flushQUIC(parent)
            closeH3Stream(slot)
            return
        }
        if sending > 0, let body { c.pointee.write.write(body, sending) }
        c.pointee.responseRemaining = short > 0 ? short : -1
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    // MARK: - What a request reads

    /// "https" or "http", as `Request.scheme` describes.
    mutating func requestScheme(_ slot: Int) -> StaticString {
        let c = table[slot]
        if !config.trust.isEmpty {
            ensureHeaders(slot)
            if let https = forwardedInfo(slot, base: c.pointee.headBase()).https {
                return https ? "https" : "http"
            }
        }
        if c.pointee.isStream { return c.pointee.h2Scheme ? "https" : "http" }
        if c.pointee.isSecure { return "https" }
        return strcmp(config.scheme, "https") == 0 ? "https" : "http"
    }

    /// The client's address and port, as `Request.remoteAddress` describes.
    mutating func requestClient(_ slot: Int) -> (address: ByteSpan, port: Int) {
        let c = table[slot]
        if !config.trust.isEmpty {
            ensureHeaders(slot)
            let info = forwardedInfo(slot, base: c.pointee.headBase())
            if let client = info.client { return (client, info.clientPort) }
        }
        // A stream's peer is its connection's.
        let owner = c.pointee.isStream && c.pointee.remoteAddr.readableBytes == 0
            ? table[Int(c.pointee.parentSlot)] : c
        guard owner.pointee.remoteAddr.readableBytes > 0 else {
            return (ByteSpan(c.pointee.headBase(), 0), 0)
        }
        return (owner.pointee.remoteAddr.readableSpan, Int(owner.pointee.remotePort))
    }

    mutating func requestHeader(_ slot: Int, _ name: UnsafePointer<UInt8>, _ length: Int) -> ByteSpan? {
        ensureHeaders(slot)
        let c = table[slot]
        let base = c.pointee.headBase()
        let count = c.pointee.head.headerCount
        var i = 0
        while i < count {
            let h = headers[i]
            i &+= 1
            guard Int(h.name.length) == length else { continue }
            let p = base + Int(h.name.offset)
            var k = 0
            while k < length && asciiLower(p[k]) == asciiLower(name[k]) { k &+= 1 }
            if k == length { return h.value.span(in: base) }
        }
        return nil
    }

    mutating func forEachRequestHeader(_ slot: Int,
                                       _ body: (ByteSpan, ByteSpan) throws -> Void) rethrows {
        ensureHeaders(slot)
        let c = table[slot]
        let base = c.pointee.headBase()
        let count = c.pointee.head.headerCount
        var i = 0
        while i < count {
            // The handler may read a header by name in here, which parses
            // nothing: the table is already this request's.
            let h = headers[i]
            i &+= 1
            try body(h.name.span(in: base), h.value.span(in: base))
        }
    }
}
