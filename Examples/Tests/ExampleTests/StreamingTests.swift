#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Testing
import Garuda
import GarudaTesting
@testable import StreamingExample

@Suite("Streaming example")
struct StreamingExampleTests {
    private func directory() -> String {
        makeScratchDirectory("garuda-streaming")
    }

    @Test func aCountdownIsEventsAndThenTheEnd() throws {
        let client = streamingApp(uploadDirectory: scratchRoot, tick: .milliseconds(1)).test
        let response = try client.get("/countdown?from=3")
        #expect(response.status == .ok)
        #expect(response.header("content-type")?.hasPrefix("text/event-stream") == true)
        #expect(response.text == """
            event: tick
            id: 3
            data: 3

            event: tick
            id: 2
            data: 2

            event: tick
            id: 1
            data: 1

            event: done
            data: liftoff


            """)
    }

    @Test func anExportIsEveryRow() throws {
        let client = streamingApp(uploadDirectory: scratchRoot).test
        #expect(try client.get("/export.csv?rows=3").text == "id,square,label\n0,0,row 0\n1,1,row 1\n2,4,row 2\n")
        // Past one batch: every row, in order, none repeated.
        let lines = try client.get("/export.csv?rows=20000").text.split(separator: "\n")
        #expect(lines.count == 20_001)
        #expect(lines.last == "19999,399960001,row 19999")
    }

    @Test func anUploadIsWrittenAndRenamed() throws {
        let dir = directory()
        defer { rmdir(dir) }
        // Small, because the test client's connection buffers 1 MiB: a body
        // past that is still being written when the 413 closes it.
        let client = streamingApp(uploadDirectory: dir, maxUploadBytes: 400_000).test
        let bytes = (0..<300_000).map { UInt8($0 % 251) }
        let put = try client.put("/uploads/data.bin", body: bytes)
        #expect(put.status == .created)
        struct Info: Decodable { let name: String; let bytes: Int }
        #expect(try put.json(Info.self).bytes == 300_000)
        #expect(try client.get("/uploads/data.bin").json(Info.self).bytes == 300_000)

        // Read back from disk: the same bytes.
        let back = fileBytes(dir + "/data.bin")
        #expect(back == bytes)
        unlink(dir + "/data.bin")

        let hidden = Result { try client.put("/uploads/..hidden", body: [1]) }
        #expect((try? hidden.get())?.status == .badRequest, "\(hidden)")
        let missing = Result { try client.get("/uploads/missing") }
        #expect((try? missing.get())?.status == .notFound, "\(missing)")
        // Over the limit: refused, and nothing left behind under either name.
        let big = Result { try client.put("/uploads/big", body: [UInt8](repeating: 0, count: 500_000)) }
        #expect((try? big.get())?.status == .contentTooLarge, "\(big)")
        #expect(!fileExists(dir + "/big"))
        #expect(!fileExists(dir + "/big.partial"))
    }
}
