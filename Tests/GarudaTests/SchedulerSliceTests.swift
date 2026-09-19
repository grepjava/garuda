import Testing
import CAvian
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Garuda

// How a worker asks the kernel for shorter time slices (--sched-slice), and
// the flag that says how short.

@Suite("Scheduler slice", .serialized)
struct SchedulerSliceTests {
    private func parsed(_ arguments: [String]) -> GarudaCLI.Parsed {
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 2)
        for (i, argument) in (["garuda"] + arguments).enumerated() { argv[i] = strdup(argument) }
        argv[arguments.count + 1] = nil
        return GarudaCLI.parse(argc: arguments.count + 1, argv: argv)
    }

    private func slice(_ arguments: [String]) -> Int? {
        if case .run(let config) = parsed(arguments) { return config.schedulerSliceMicroseconds }
        return nil
    }

    @Test func theFlagTakesZeroOrAMicrosecondCountTheKernelAccepts() {
        #expect(slice([]) == 300)
        #expect(slice(["--sched-slice", "0"]) == 0)
        #expect(slice(["--sched-slice", "100"]) == 100)
        #expect(slice(["--sched-slice", "100000"]) == 100_000)
        for refused in ["50", "100001", "-1"] {
            if case .exit(let status) = parsed(["--sched-slice", refused]) {
                #expect(status == 2)
            } else {
                Issue.record("--sched-slice \(refused) was accepted")
            }
        }
    }

    @Test func aWorkerAsksForItsSlice() {
        // The runner's thread, put back as it was afterwards.
        let before = av_sched_slice()
        defer { if before >= 0 { _ = av_sched_set_slice(UInt64(before)) } }
        GarudaRuntime.requestSchedulerSlice(250)
        let asked = av_sched_slice()
        #if os(Linux)
        // As asked where the kernel has custom slices, 0 where it ignores them.
        #expect(asked == 250_000 || asked == 0)
        // 0 leaves the thread as it is.
        GarudaRuntime.requestSchedulerSlice(0)
        #expect(av_sched_slice() == asked)
        #else
        #expect(asked == -1)
        #endif
    }
}
