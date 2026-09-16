//===----------------------------------------------------------------------===//
// Connections this worker makes, rather than accepts.
//
// The HTTP client and every database driver go through here, so that none of
// them opens a socket of its own: one poller, one thread, one place where a
// descriptor's readiness becomes a resumed handler.
//
// These do not live in the connection table. A pooled outbound connection is
// idle for minutes at a time, and `Worker.quiescent` is `table.liveCount == 0`
// -- a draining worker holding one there would never look finished, and would
// exit on the grace deadline logging "connections still in flight" every time.
// So they have a slab of their own, and a drain closes them rather than
// waiting for them.
//
// Names are not resolved here. `getaddrinfo` blocks, and blocking the worker
// is the one thing this layer exists to avoid, so a connect takes an address
// and naming is a layer above.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore

/// Why an outbound connection did not come up, or did not stay up.
public enum OutboundError: Error, Equatable {
    /// The address was not an IP literal, or the socket could not be made.
    case address
    /// The connection was refused, unreachable, or reset. Carries errno.
    case failed(Int32)
    /// It did not come up inside the time allowed.
    case timedOut
    /// The request that wanted it ended, or the worker is shutting down.
    case cancelled
    /// This worker already has as many outbound connections as it may.
    case exhausted
}

enum OutboundState: UInt8 {
    case free
    /// `connect` has been started and the socket is not yet writable.
    case connecting
    /// Up, and the handler that asked for it owns it.
    case open
    /// Up, owned by nobody, and kept for the next caller wanting the same
    /// place. Watched for readability while it waits: an idle connection that
    /// has something to say is a peer hanging up, and handing that to the next
    /// caller is the oldest bug in connection pooling.
    case idle
}

/// Where a connection goes, and so which pooled ones may be reused for it.
/// A unix socket is its path with port 0; nothing else can collide with that,
/// since a path is not a host.
struct OutboundKey: Hashable {
    var host: String
    var port: UInt16
}

/// One connection this worker made.
struct OutboundConnection {
    var fd: Int32 = -1
    var nextFree: Int32 = -1
    /// Bumped on allocate, so an event for a recycled index is recognised as
    /// stale exactly the way a connection slot's generation does it.
    var generation: UInt32 = 0
    var state: OutboundState = .free
    /// The task waiting for this connection to come up, resumed with the
    /// outcome. Nil once it has been resumed.
    var waiter: UnsafeContinuation<OutboundError?, Never>? = nil
    /// The op bounding the wait, or -1.
    var timerOp: Int32 = -1
    var timerOpGeneration: UInt32 = 0
    var interest: UInt32 = 0
    /// Whether the descriptor is in the poller at all. A connect that
    /// completes immediately -- the usual case on loopback -- is never added,
    /// so a later wait has to add it rather than modify it.
    var registered = false
    /// Where this connection goes, so a later caller wanting the same place
    /// can be given it back. Nil while the record is free.
    var key: OutboundKey? = nil
    /// The next idle connection to the same place, or -1. Singly linked: the
    /// lists are short, so removing from the middle walks from the head.
    var nextIdle: Int32 = -1
    /// When it went idle, for the sweep that closes ones nobody came back for.
    var idleSince: UInt64 = 0
}

/// Fixed-capacity slab, threaded free list, exactly like `ConnectionTable`.
/// Fixed because an unbounded number of outbound sockets is how a worker runs
/// out of descriptors serving requests that are each behaving reasonably.
struct OutboundTable {
    private var slots: UnsafeMutablePointer<OutboundConnection>
    let capacity: Int
    private var firstFree: Int32
    private(set) var liveCount: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0 && capacity < (1 << 24), "outbound table out of range")
        self.capacity = capacity
        slots = UnsafeMutablePointer<OutboundConnection>.allocate(capacity: capacity)
        slots.initialize(repeating: OutboundConnection(), count: capacity)
        var i = 0
        while i < capacity {
            slots[i].nextFree = Int32(i + 1 < capacity ? i + 1 : -1)
            i += 1
        }
        firstFree = 0
    }

    subscript(index: Int) -> UnsafeMutablePointer<OutboundConnection> { slots + index }

    mutating func allocate() -> Int {
        let index = Int(firstFree)
        if index < 0 { return -1 }
        firstFree = slots[index].nextFree
        slots[index].nextFree = -1
        slots[index].generation &+= 1
        liveCount += 1
        return index
    }

    mutating func release(_ index: Int) {
        slots[index].nextFree = firstFree
        slots[index].state = .free
        slots[index].fd = -1
        slots[index].waiter = nil
        slots[index].timerOp = -1
        slots[index].interest = 0
        // Cleared with the rest: a recycled record that still believed its
        // descriptor was in the poller would modify an entry that is not
        // there, and never add the one that is.
        slots[index].registered = false
        slots[index].key = nil
        slots[index].nextIdle = -1
        slots[index].idleSince = 0
        firstFree = Int32(index)
        liveCount -= 1
    }

    func destroy() {
        slots.deallocate()
    }
}

extension Worker {
    /// The outbound table, made on the first connection this worker makes. A
    /// server that never calls out pays nothing for this.
    mutating func outboundTableOrMake() -> Int {
        if outbound == nil { outbound = OutboundTable(capacity: outboundLimit) }
        return outbound!.allocate()
    }

    /// Starts a connection to `host` (an IP literal) and `port`, and returns
    /// the index of the record following it. The caller waits on `awaitOpen`.
    mutating func beginConnect(host: String, port: UInt16) -> Result<Int, OutboundError> {
        var inProgress: Int32 = 0
        let fd = host.withCString { pg_connect_tcp($0, port, &inProgress) }
        return finishBegin(fd: fd, inProgress: inProgress != 0,
                           key: OutboundKey(host: host, port: port))
    }

    /// The same for a unix socket.
    mutating func beginConnect(path: String) -> Result<Int, OutboundError> {
        var inProgress: Int32 = 0
        let fd = path.withCString { pg_connect_unix($0, &inProgress) }
        return finishBegin(fd: fd, inProgress: inProgress != 0,
                           key: OutboundKey(host: path, port: 0))
    }

    private mutating func finishBegin(fd: Int32, inProgress: Bool,
                                      key: OutboundKey) -> Result<Int, OutboundError> {
        guard fd >= 0 else {
            // EINVAL is the numeric-host parse refusing a name; anything else
            // is a socket that could not be made or a connection refused
            // outright, which loopback does synchronously.
            let err = pg_errno()
            return .failure(err == EINVAL ? .address : .failed(err))
        }
        let index = outboundTableOrMake()
        guard index >= 0 else {
            _ = pg_close(fd)
            return .failure(.exhausted)
        }
        outboundOpened &+= 1
        let o = outbound![index]
        o.pointee.fd = fd
        o.pointee.waiter = nil
        o.pointee.timerOp = -1
        o.pointee.interest = 0
        o.pointee.key = key
        o.pointee.nextIdle = -1
        o.pointee.state = inProgress ? .connecting : .open
        if inProgress {
            // Writability is how a non-blocking connect reports either
            // outcome; `pg_connect_error` then says which it was.
            let token = PollToken.outbound(index: index, generation: o.pointee.generation)
            guard poller.add(fd, .write, token: token) else {
                closeOutbound(index)
                return .failure(.failed(pg_errno()))
            }
            o.pointee.registered = true
            o.pointee.interest = PollMask.write.rawValue
        }
        return .success(index)
    }

    /// Asks the poller for `mask` on this connection, adding the descriptor
    /// the first time and modifying it afterwards.
    mutating func setOutboundInterest(_ index: Int, _ mask: PollMask) {
        guard let table = outbound else { return }
        let o = table[index]
        guard o.pointee.fd >= 0, o.pointee.interest != mask.rawValue else { return }
        let token = PollToken.outbound(index: index, generation: o.pointee.generation)
        if o.pointee.registered {
            _ = poller.modify(o.pointee.fd, mask, token: token)
        } else {
            guard poller.add(o.pointee.fd, mask, token: token) else { return }
            o.pointee.registered = true
        }
        o.pointee.interest = mask.rawValue
    }

    // MARK: - The pool

    /// Takes a live idle connection to `key`, or -1. Connections the peer has
    /// since closed are dropped here rather than handed on: the caller would
    /// find out by writing into a socket that is already gone.
    mutating func takeIdle(_ key: OutboundKey) -> Int {
        guard outbound != nil else { return -1 }
        while let head = outboundIdle[key], head >= 0 {
            let index = Int(head)
            let o = outbound![index]
            let next = o.pointee.nextIdle
            if next >= 0 { outboundIdle[key] = next } else { outboundIdle.removeValue(forKey: key) }
            o.pointee.nextIdle = -1
            guard o.pointee.state == .idle else { continue }
            // Nothing should be readable on an idle connection. If something
            // is, the far end has spoken or hung up, and either way it is not
            // a connection to hand to somebody expecting a fresh exchange.
            //
            // Anything but 0 means discard. 1 is readable; -1 is the hangup,
            // which is the common case here and which testing `> 0` let
            // straight through -- the guard read as working while the event
            // path quietly did all of the catching.
            if pg_poll_single(o.pointee.fd, 0, 0) != 0 {
                closeOutbound(index)
                continue
            }
            o.pointee.state = .open
            disarmOutboundTimer(index)
            setOutboundInterest(index, [])
            return index
        }
        return -1
    }

    /// Hands a connection back for the next caller. It is watched while it
    /// waits, so a peer that closes is noticed then rather than by the
    /// unlucky caller who takes it next.
    mutating func returnToPool(_ index: Int) {
        guard outbound != nil, index >= 0, index < outbound!.capacity else { return }
        let o = outbound![index]
        guard o.pointee.state == .open, let key = o.pointee.key else {
            closeOutbound(index)
            return
        }
        guard o.pointee.waiter == nil else {
            // Something is still waiting on it; it is not idle at all.
            closeOutbound(index)
            return
        }
        if idleCount(for: key) >= outboundIdlePerKey {
            closeOutbound(index)
            return
        }
        o.pointee.state = .idle
        o.pointee.idleSince = pg_monotonic_ms()
        disarmOutboundTimer(index)
        setOutboundInterest(index, .read)
        o.pointee.nextIdle = outboundIdle[key] ?? -1
        outboundIdle[key] = Int32(index)
    }

    func idleCount(for key: OutboundKey) -> Int {
        guard let table = outbound else { return 0 }
        var n = 0
        var at = outboundIdle[key] ?? -1
        while at >= 0, n <= outboundIdlePerKey {
            n += 1
            at = table[Int(at)].pointee.nextIdle
        }
        return n
    }

    /// Unlinks `index` from its key's idle list, wherever it sits in it.
    mutating func unlinkIdle(_ index: Int) {
        guard let table = outbound, let key = table[index].pointee.key else { return }
        guard var at = outboundIdle[key], at >= 0 else { return }
        if at == Int32(index) {
            let next = table[index].pointee.nextIdle
            if next >= 0 { outboundIdle[key] = next } else { outboundIdle.removeValue(forKey: key) }
            table[index].pointee.nextIdle = -1
            return
        }
        while at >= 0 {
            let current = table[Int(at)]
            let next = current.pointee.nextIdle
            if next == Int32(index) {
                current.pointee.nextIdle = table[index].pointee.nextIdle
                table[index].pointee.nextIdle = -1
                return
            }
            at = next
        }
    }

    /// Closes idle connections nobody came back for. Called once a second
    /// from the worker's sweep.
    mutating func sweepIdleOutbound(now: UInt64) {
        guard let table = outbound, !outboundIdle.isEmpty else { return }
        var i = 0
        while i < table.capacity {
            let o = table[i]
            if o.pointee.state == .idle, now &- o.pointee.idleSince >= outboundIdleMillis {
                closeOutbound(i)
            }
            i += 1
        }
    }

    /// Whether the record at `index` is still the connection `generation`
    /// named. Every resumption checks this: the index is reused.
    func outboundHolds(_ index: Int, generation: UInt32) -> Bool {
        guard let table = outbound, index >= 0, index < table.capacity else { return false }
        let o = table[index]
        return o.pointee.state != .free && o.pointee.generation == generation
    }

    /// The connection came up, failed, or ran out of time. Resumes whoever is
    /// waiting, once.
    mutating func settleOutbound(_ index: Int, _ error: OutboundError?) {
        guard let table = outbound, index >= 0, index < table.capacity else { return }
        let o = table[index]
        guard let waiter = o.pointee.waiter.take() else { return }
        if error == nil {
            o.pointee.state = .open
            // Nothing is wanted from the socket until the owner asks again,
            // so stop being told it is ready.
            setOutboundInterest(index, [])
        }
        disarmOutboundTimer(index)
        waiter.resume(returning: error)
    }

    /// A readiness event for an outbound connection.
    ///
    /// The generation comes back exactly: bit 62 shifted down 24 lands at bit
    /// 38, which truncating to `UInt32` drops, so no masking is needed.
    mutating func handleOutboundEvent(_ token: UInt64, _ mask: PollMask) {
        guard let table = outbound else { return }
        let index = PollToken.slot(token)
        let generation = PollToken.generation(token)
        guard index >= 0, index < table.capacity else { return }
        let o = table[index]
        guard o.pointee.state != .free, o.pointee.generation == generation else { return }
        switch o.pointee.state {
        case .free:
            return
        case .connecting:
            // A non-blocking connect reports both outcomes the same way, by
            // becoming writable; SO_ERROR is what says which happened.
            let err = pg_connect_error(o.pointee.fd)
            if err != 0 { settleOutbound(index, .failed(err)); return }
            if mask.isFailed { settleOutbound(index, .failed(pg_errno())); return }
            settleOutbound(index, nil)
        case .open:
            // Readable or writable as asked. A hangup still settles the wait:
            // the reader wants to see the end of the stream, not hang on it.
            settleOutbound(index, nil)
        case .idle:
            // Nobody asked this connection for anything, so whatever it has
            // to say is the far end going away. Drop it now, while no caller
            // is depending on it.
            unlinkIdle(index)
            closeOutbound(index)
        }
    }

    /// Closes the connection at `index` and gives its record back. A waiter
    /// still on it is told the connection is gone rather than left hanging.
    mutating func closeOutbound(_ index: Int) {
        guard outbound != nil, index >= 0, index < outbound!.capacity else { return }
        let o = outbound![index]
        guard o.pointee.state != .free else { return }
        // Out of the pool before anything else: a record on the free list that
        // is still in an idle list would be handed to the next caller.
        if o.pointee.state == .idle { unlinkIdle(index) }
        let waiter = o.pointee.waiter.take()
        disarmOutboundTimer(index)
        if o.pointee.fd >= 0 {
            if o.pointee.interest != 0 { _ = poller.remove(o.pointee.fd) }
            _ = pg_close(o.pointee.fd)
        }
        // Mutated through the stored table rather than a copy written back: a
        // copy would lose anything the calls above changed.
        outbound!.release(index)
        // Resumed after the record is back on the free list, so a task that
        // wakes and connects again cannot be handed this record half torn down.
        waiter?.resume(returning: .cancelled)
    }

    /// Bounds the connect at `index`. A connection that never comes up is the
    /// ordinary failure of an outbound call, not an exceptional one.
    mutating func armConnectTimeout(_ index: Int, milliseconds: UInt64) {
        guard let table = outbound else { return }
        let o = table[index]
        let deadline = pg_monotonic_us() &+ 1 &+ max(1, milliseconds) &* 1000
        guard let (op, generation) = asyncOps.allocate(
            slot: index, requestId: 0, kind: .outbound, deadlineUs: deadline) else { return }
        timerHeap.push(
            TimerHeap.Entry(deadlineUs: deadline, opIndex: Int32(op), opGeneration: generation),
            into: &asyncOps)
        o.pointee.timerOp = Int32(op)
        o.pointee.timerOpGeneration = generation
    }

    /// Closes every outbound connection. A drain does not wait for these: the
    /// requests that wanted them are already being unwound.
    mutating func closeAllOutbound() {
        guard let table = outbound else { return }
        var i = 0
        while i < table.capacity {
            if table[i].pointee.state != .free { closeOutbound(i) }
            i += 1
        }
        outboundIdle.removeAll()
    }

    /// Parks the caller until this connection is ready for `mask`, or the
    /// time runs out. One wait at a time per connection: a request and its
    /// response take turns, which is what every protocol here does.
    mutating func beginOutboundWait(_ index: Int, _ mask: PollMask,
                                    milliseconds: UInt64) -> OutboundError? {
        guard let table = outbound, index >= 0, index < table.capacity else { return .cancelled }
        let o = table[index]
        guard o.pointee.state != .free else { return .cancelled }
        guard o.pointee.waiter == nil else { return .failed(EBUSY) }
        setOutboundInterest(index, mask)
        armConnectTimeout(index, milliseconds: milliseconds)
        return nil
    }

    mutating func disarmOutboundTimer(_ index: Int) {
        guard let table = outbound else { return }
        let o = table[index]
        let op = Int(o.pointee.timerOp)
        let generation = o.pointee.timerOpGeneration
        o.pointee.timerOp = -1
        o.pointee.timerOpGeneration = 0
        guard op >= 0, op < asyncOps.capacity else { return }
        let record = asyncOps[op]
        guard record.pointee.generation == generation else { return }
        timerHeap.remove(opIndex: op, from: &asyncOps)
        asyncOps.free(op)
    }
}

// MARK: - What a caller holds

/// A connection this worker made, for as long as the caller keeps it.
///
/// Internal: the HTTP client and the database drivers are what this exists
/// for, and their use is what should settle any public shape. A handle is a
/// value, not a reference, so it is checked against the record's generation on
/// every call rather than trusted.
struct OutboundSocket {
    let worker: UnsafeMutablePointer<Worker>
    let index: Int
    let generation: UInt32

    /// False once the connection has been closed, by this caller or by the
    /// worker shutting down.
    var isOpen: Bool { worker.pointee.outboundHolds(index, generation: generation) }

    private var record: UnsafeMutablePointer<OutboundConnection>? {
        guard isOpen, let table = worker.pointee.outbound else { return nil }
        return table[index]
    }

    /// Writes what it can without blocking. Returns how much went, which may
    /// be 0 when the socket is full -- then wait for `writable` and go again.
    func write(_ bytes: UnsafeRawBufferPointer) throws(OutboundError) -> Int {
        guard let o = record else { throw .cancelled }
        let n = pg_write(o.pointee.fd, bytes.baseAddress, bytes.count)
        if n >= 0 { return n }
        let err = pg_errno()
        if pg_err_is_again(err) != 0 || pg_err_is_intr(err) != 0 { return 0 }
        throw .failed(err)
    }

    /// Reads what is there without blocking. 0 means nothing right now; the
    /// peer closing is reported as `failed(0)` so it cannot be mistaken for it.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws(OutboundError) -> Int {
        guard let o = record else { throw .cancelled }
        let n = pg_read(o.pointee.fd, buffer.baseAddress, buffer.count)
        if n > 0 { return n }
        if n == 0 { throw .failed(0) }
        let err = pg_errno()
        if pg_err_is_again(err) != 0 || pg_err_is_intr(err) != 0 { return 0 }
        throw .failed(err)
    }

    func readable(milliseconds: UInt64 = 10_000) async throws(OutboundError) {
        try await wait(.read, milliseconds: milliseconds)
    }

    func writable(milliseconds: UInt64 = 10_000) async throws(OutboundError) {
        try await wait(.write, milliseconds: milliseconds)
    }

    private func wait(_ mask: PollMask, milliseconds: UInt64) async throws(OutboundError) {
        guard isOpen else { throw .cancelled }
        let worker = self.worker
        let index = self.index
        if let refused = worker.pointee.beginOutboundWait(index, mask, milliseconds: milliseconds) {
            throw refused
        }
        // Stored inside the closure, which runs before the suspension is
        // complete, and the worker is one thread -- so no event can arrive
        // between arming the wait and being able to be woken from it.
        let outcome = await withUnsafeContinuation { (k: UnsafeContinuation<OutboundError?, Never>) in
            worker.pointee.outbound?[index].pointee.waiter = k
        }
        if let outcome { throw outcome }
    }

    /// Hands the connection back for the next caller wanting the same place,
    /// instead of closing it. Only for a connection left in a reusable state:
    /// a half-read response makes the next exchange read somebody else's
    /// bytes, so when in doubt, `close`.
    func release() {
        guard isOpen else { return }
        worker.pointee.returnToPool(index)
    }

    func close() {
        guard isOpen else { return }
        worker.pointee.closeOutbound(index)
    }
}

extension Worker {
    /// Opens a connection to an IP literal and port, waiting at most
    /// `milliseconds` for it to come up.
    static func connect(_ worker: UnsafeMutablePointer<Worker>, host: String, port: UInt16,
                        milliseconds: UInt64 = 10_000) async throws(OutboundError) -> OutboundSocket {
        try await open(worker, milliseconds: milliseconds,
                       key: OutboundKey(host: host, port: port)) {
            $0.pointee.beginConnect(host: host, port: port)
        }
    }

    /// The same for a unix socket.
    static func connect(_ worker: UnsafeMutablePointer<Worker>, path: String,
                        milliseconds: UInt64 = 10_000) async throws(OutboundError) -> OutboundSocket {
        try await open(worker, milliseconds: milliseconds,
                       key: OutboundKey(host: path, port: 0)) {
            $0.pointee.beginConnect(path: path)
        }
    }

    private static func open(
        _ worker: UnsafeMutablePointer<Worker>, milliseconds: UInt64,
        key: OutboundKey,
        _ begin: (UnsafeMutablePointer<Worker>) -> Result<Int, OutboundError>
    ) async throws(OutboundError) -> OutboundSocket {
        // Somewhere this worker has been before, still open and quiet.
        let pooled = worker.pointee.takeIdle(key)
        if pooled >= 0, let table = worker.pointee.outbound {
            return OutboundSocket(worker: worker, index: pooled,
                                  generation: table[pooled].pointee.generation)
        }
        let index: Int
        switch begin(worker) {
        case .failure(let error): throw error
        case .success(let i): index = i
        }
        guard let table = worker.pointee.outbound else { throw .cancelled }
        let generation = table[index].pointee.generation
        let socket = OutboundSocket(worker: worker, index: index, generation: generation)
        // Loopback usually connects within the call; there is nothing to wait
        // for and no reason to go round the poller for it.
        if table[index].pointee.state == .open { return socket }

        worker.pointee.armConnectTimeout(index, milliseconds: milliseconds)
        let outcome = await withUnsafeContinuation { (k: UnsafeContinuation<OutboundError?, Never>) in
            worker.pointee.outbound?[index].pointee.waiter = k
        }
        if let outcome {
            worker.pointee.closeOutbound(index)
            throw outcome
        }
        return socket
    }
}
