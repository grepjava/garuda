//===----------------------------------------------------------------------===//
// --reload: the supervisor restarting on a rebuilt executable.
//
// Workers are forked from the supervisor, so they run the code the supervisor
// was started with, and a rebuild would never reach them. So the supervisor
// execs the new file in place of itself: the same pid, arguments and working
// directory. Its listening sockets stay open across the exec, their
// descriptors passed in the environment, so the SO_REUSEPORT group never loses
// a member and no connection waiting in an accept queue is dropped.
//
// The workers it had forked are still its children after the exec. The new
// image adopts them and replaces them one slot at a time, exactly as a SIGHUP
// does, so each finishes what it was serving while a worker forked from the
// new code takes its slot.
//
// Supervisor code, written for clarity.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CAvian
import AvianCore

struct Reexec {
    static let variable = "GARUDA_REEXEC"

    /// The supervisor's listening socket for each worker slot.
    var listeners: [Int32]
    /// The worker in each slot, or 0 for an empty one.
    var workers: [pid_t]

    /// The record the previous image left, removed from the environment so
    /// that nothing started from here inherits it.
    static func take() -> Reexec? {
        guard let raw = av_getenv(variable) else { return nil }
        let text = String(cString: raw)
        unsetenv(variable)
        let halves = text.split(separator: ";", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        var listeners: [Int32] = []
        var workers: [pid_t] = []
        for field in halves[0].split(separator: ",") {
            guard let fd = Int32(field) else { return nil }
            listeners.append(fd)
        }
        for field in halves[1].split(separator: ",") {
            guard let pid = pid_t(field) else { return nil }
            workers.append(pid)
        }
        if listeners.isEmpty || workers.isEmpty { return nil }
        return Reexec(listeners: listeners, workers: workers)
    }

    func encoded() -> String {
        listeners.map { String($0) }.joined(separator: ",")
            + ";" + workers.map { String($0) }.joined(separator: ",")
    }

    /// Whether this image can take the sockets and workers over as they are.
    func fits(workers count: Int, listeners listenerCount: Int) -> Bool {
        workers.count == count && listeners.count == listenerCount
    }

    /// For sockets and workers this image will not adopt: the workers are
    /// stopped and waited for, and the sockets closed, rather than left behind
    /// with no supervisor.
    func release() {
        for pid in workers where pid > 0 { _ = av_kill(pid, SIGQUIT) }
        var status: Int32 = 0
        for pid in workers where pid > 0 { _ = av_waitpid(pid, &status, 0) }
        var closed: [Int32] = []
        for fd in listeners where fd >= 0 && !closed.contains(fd) {
            _ = av_close(fd)
            closed.append(fd)
        }
    }
}
