//===----------------------------------------------------------------------===//
// Readiness poller.
//
// A thin, allocation-free wrapper over the C epoll/kqueue shim. The event array
// is owned by the poller and reused for the life of the worker, so a poll cycle
// costs exactly one syscall and zero allocations.
//===----------------------------------------------------------------------===//

import CPeregrine

public struct PollMask: OptionSet, Sendable {
    public let rawValue: UInt32
    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read  = PollMask(rawValue: 0x1)
    public static let write = PollMask(rawValue: 0x2)
    public static let error = PollMask(rawValue: 0x4)
    public static let hangup = PollMask(rawValue: 0x8)

    @inlinable public var wantsRead: Bool { rawValue & 0x1 != 0 }
    @inlinable public var wantsWrite: Bool { rawValue & 0x2 != 0 }
    @inlinable public var isFailed: Bool { rawValue & 0xC != 0 }
}

public struct Poller {
    public let fd: Int32
    @usableFromInline let events: UnsafeMutablePointer<pg_event>
    @usableFromInline let maxEvents: Int32

    public init?(maxEvents: Int = 256) {
        let f = pg_poll_create()
        if f < 0 { return nil }
        self.fd = f
        self.maxEvents = Int32(maxEvents)
        self.events = UnsafeMutablePointer<pg_event>.allocate(capacity: maxEvents)
    }

    @inlinable
    @discardableResult
    public func add(_ target: Int32, _ mask: PollMask, token: UInt64) -> Bool {
        pg_poll_add(fd, target, mask.rawValue, token) == 0
    }

    @inlinable
    @discardableResult
    public func modify(_ target: Int32, _ mask: PollMask, token: UInt64) -> Bool {
        pg_poll_mod(fd, target, mask.rawValue, token) == 0
    }

    @inlinable
    @discardableResult
    public func remove(_ target: Int32, last: PollMask = [.read, .write]) -> Bool {
        pg_poll_del(fd, target, last.rawValue) == 0
    }

    /// Blocks for at most `timeoutMillis` (-1 = forever, 0 = poll). Returns the
    /// number of ready events, or -1 on a hard failure. EINTR yields 0.
    @inlinable
    public func wait(timeoutMillis: Int32) -> Int {
        Int(pg_poll_wait(fd, events, maxEvents, timeoutMillis))
    }

    @inlinable
    public func event(_ i: Int) -> (token: UInt64, mask: PollMask) {
        let e = events[i]
        return (e.token, PollMask(rawValue: e.mask))
    }

    public func destroy() {
        events.deallocate()
        _ = pg_close(fd)
    }
}
