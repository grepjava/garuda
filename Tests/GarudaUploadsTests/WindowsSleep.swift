//===----------------------------------------------------------------------===//
// usleep, which ucrt has not: on Windows only, under the POSIX name, so the
// Linux and macOS paths call libc as before.
//===----------------------------------------------------------------------===//

#if os(Windows)
import WinSDK

/// Sleeps this thread for at least `microseconds`, in Sleep's milliseconds.
@discardableResult
func usleep(_ microseconds: UInt32) -> Int32 {
    Sleep(DWORD((UInt64(microseconds) + 999) / 1000))
    return 0
}
#endif
