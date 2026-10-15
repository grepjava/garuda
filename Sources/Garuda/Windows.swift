//===----------------------------------------------------------------------===//
// The few POSIX calls Garuda makes that Windows names differently. Each is
// defined only on Windows, under the POSIX name, so the Linux and macOS
// paths call libc directly as before.
//===----------------------------------------------------------------------===//

#if os(Windows)
import WinSDK

/// Gives up the rest of this thread's time slice, as POSIX's does.
@discardableResult @inline(__always)
func sched_yield() -> Int32 {
    _ = SwitchToThread()
    return 0
}
#endif
