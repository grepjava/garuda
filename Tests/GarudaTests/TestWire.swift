import CAvian
@testable import Garuda

/// One connection to a test client's worker, driven directly.
///
/// `TestClient.get` opens a connection, turns until the whole response has
/// arrived, and closes it. That is the wrong shape whenever a test has to do
/// something *while* a handler is parked -- wake it, answer it from the other
/// side, or look at the worker mid-request -- and closing the connection frees
/// everything the request held, which hides whatever the test was checking.
///
/// Kept in one place because three suites now need it.
final class TestWire {
    let client: TestClient
    let fd: Int32
    let slot: Int
    let generation: UInt32
    private let capacity = 16384
    private let buffer: UnsafeMutablePointer<UInt8>
    private var got = 0
    private var closed = false

    init(_ client: TestClient) throws {
        self.client = client
        let opened = try client.connect()
        fd = opened.client
        slot = opened.slot
        generation = opened.generation
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = av_close(fd)
    }

    func send(_ request: String) {
        var request = request
        request.withUTF8 { _ = av_write(fd, $0.baseAddress!, $0.count) }
    }

    /// Bytes waiting now, without turning the worker.
    @discardableResult
    func pending() -> Int {
        while got < capacity {
            let n = av_read(fd, buffer + got, capacity - got)
            if n <= 0 { break }
            got += n
        }
        return got
    }

    /// Everything that has arrived and not been taken, as text, left where
    /// it is: for a response with no length to wait for, such as a stream.
    func arrived() -> String {
        pending()
        return String(decoding: UnsafeBufferPointer(start: buffer, count: got), as: UTF8.self)
    }

    /// Turns until `ready` is true, or the turns run out. Returns whether it
    /// became true, so a test can assert on it rather than hoping.
    @discardableResult
    func turn(until ready: () -> Bool, turns: Int = 500) -> Bool {
        for _ in 0..<turns {
            if ready() { return true }
            client.turn()
        }
        return ready()
    }

    /// Turns until one whole response has arrived, then takes it out of the
    /// buffer and returns it.
    func receive(turns: Int = 5_000) -> String? {
        for _ in 0..<turns {
            client.turn()
            pending()
            guard let total = completeLength(), total == got else { continue }
            let text = String(decoding: UnsafeBufferPointer(start: buffer, count: got), as: UTF8.self)
            got = 0
            return text
        }
        return nil
    }

    /// The status of the next whole response.
    func receiveStatus(turns: Int = 5_000) -> Int? {
        guard let text = receive(turns: turns) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        return Int(parts[1])
    }

    /// The length of the response at the start of the buffer once all of it is
    /// there. Every response in these tests states a Content-Length.
    private func completeLength() -> Int? {
        var end = 0
        while end + 3 < got {
            if buffer[end] == 13 && buffer[end + 1] == 10
                && buffer[end + 2] == 13 && buffer[end + 3] == 10 { break }
            end += 1
        }
        guard end + 3 < got else { return nil }
        let name: StaticString = "\r\ncontent-length: "
        var i = 0
        while i < end {
            var matched = 0
            while matched < name.utf8CodeUnitCount && i + matched < end
                    && (buffer[i + matched] | (matched >= 2 ? 0x20 : 0)) == name.utf8Start[matched] {
                matched += 1
            }
            if matched == name.utf8CodeUnitCount {
                var length = 0
                var d = i + matched
                while d < end && buffer[d] >= 48 && buffer[d] <= 57 {
                    length = length * 10 + Int(buffer[d] - 48)
                    d += 1
                }
                let total = end + 4 + length
                return total <= got ? total : nil
            }
            i += 1
        }
        return nil
    }
}
