import Testing
import CAvian
@testable import Garuda

// An async handler runs on its worker's thread from its first line to its
// last: after a yield, a wait on the engine, a call to a plain async function
// and a task group alike. Anywhere else, what it touches of the worker is
// touched from two threads at once -- and it waits for a thread of the
// global pool, which a busy process may not have free.

nonisolated(unsafe) private var expectedWorker: UnsafeMutableRawPointer? = nil
nonisolated(unsafe) private var marks: [String] = []

private func mark(_ label: String) {
    let here = av_worker_current()
    marks.append("\(label) \(here != nil && here == expectedWorker ? "worker" : "elsewhere")")
}

private func plainAsync() async -> Int {
    await Task.yield()
    return 1
}

private func placesApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/raw") { _, response in
        mark("start")
        await Task.yield()
        mark("yield")
        try await response.sleep(milliseconds: 1)
        mark("sleep")
        _ = await plainAsync()
        mark("plain")
        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                mark("child")
                return 1
            }
            for await _ in group {}
        }
        mark("group")
        response.send("done")
    }
    app.get("/typed") { () async in
        mark("typed")
        await Task.yield()
        mark("typed-yield")
        return "done"
    }
    return app
}

@Suite("Handler threads", .serialized)
struct HandlerThreadTests {
    @Test func anAsyncHandlerStaysOnItsWorkersThread() throws {
        let client = placesApp().test
        expectedWorker = UnsafeMutableRawPointer(client.worker)
        for path in ["/raw", "/typed", "/raw"] {
            marks = []
            #expect(try client.get(path).text == "done")
            let away = marks.filter { $0.hasSuffix("elsewhere") }
            #expect(away.isEmpty, "\(path): \(marks.joined(separator: ", "))")
            #expect(!marks.isEmpty)
        }
    }
}
