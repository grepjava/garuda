//===----------------------------------------------------------------------===//
// Where uploads are kept while they are in progress.
//
// Shards are separate processes, and a client that resumes after a dropped
// connection is as likely to reach a different shard as the same one, so
// nothing about an upload lives in a shard's memory. `FileUploadStore` keeps
// each one as files in a directory:
//
//   <id>.data   the bytes received so far; its size is the offset
//   <id>.info   the declared length, whether it is complete, when it was
//               created, and the metadata sent with it
//   <id>.done   what the completed upload was answered with, kept after the
//               handler has taken the bytes away, so a client whose
//               connection died before the answer arrived can ask again
//
// The offset is the data file's size rather than a number written beside it,
// so a shard that crashes part-way through an append leaves an upload whose
// offset is exactly what reached the disk. Only one request appends to an
// upload at a time, across processes and threads: `acquire` takes an
// exclusive flock on the data file and fails at once if another request
// holds it.
//
// The files are read and written through VegaFS -- on the worker's ring, or
// on the blocking pool -- so a slow disk holds up the upload waiting on it
// and no other request. The one exception is `remember`, which writes a few
// hundred bytes from inside a response hook that cannot wait (ResumableUploads.swift).
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#endif

import Garuda
import Synchronization
import Vega
import VegaCrypto
import VegaFS

/// What is known about one upload.
public struct UploadInfo: Codable, Sendable, Equatable {
    public var id: String
    /// Bytes received and stored.
    public var offset: Int
    /// The total the client declared with `Upload-Length`, once it has.
    public var length: Int?
    /// The client sent the last of it, and the upload is whole.
    public var complete: Bool
    /// Seconds since the epoch.
    public var createdAt: Int
    /// `Content-Type` and `Content-Disposition` from the request that created
    /// it, when it sent them.
    public var contentType: String?
    public var contentDisposition: String?
    /// The `Repr-Digest` the client declared for the whole upload, as the
    /// field's text. Checked once the last byte is in (ResumableUploads.swift).
    public var reprDigest: String?
    /// What the application's `onCreate` recorded about the request that
    /// created this upload, kept for the request that completes it -- which is
    /// a different request, and may be in a different shard. Written by the
    /// server and never by a client, which is what makes it somewhere to keep
    /// whose upload this is. Nil for an upload created without the hook.
    public var metadata: [String: String]?
}

/// What a completed upload was answered with, kept so it can be given again.
public struct UploadAnswer: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    /// The `Location` it answered with, when it had one: a redirect replayed
    /// without it is a status that says nothing.
    public var location: String?
    public var body: [UInt8]
    /// When the upload it answers was created, so the answer can be expired
    /// along with the upload it belongs to, even once that upload is gone.
    public var createdAt: Int
}

public enum UploadStoreError: Error, Equatable {
    /// A system call failed, with its errno.
    case system(String, Int32)
    case notFound
}

/// An upload held for appending. Release it when the request is done; it is
/// released when it goes, too.
public final class UploadHandle: @unchecked Sendable {
    public let id: String
    let store: FileUploadStore
    /// The data file, opened to append, with the lock on it.
    private let file: File
    private var held = true
    /// Bytes stored so far, including this handle's appends.
    public private(set) var offset: Int

    #if os(Windows)
    /// The data file opened again, to read and write, which holds the lock
    /// and truncates: LockFileEx and setting the end of a file take a handle
    /// that may write the whole file, and one opened to append may not.
    private let lock: File

    init(id: String, store: FileUploadStore, file: consuming File, lock: consuming File, offset: Int) {
        self.id = id
        self.store = store
        self.file = file
        self.lock = lock
        self.offset = offset
    }

    private var lockDescriptor: Int32 { lock.descriptor }
    #else
    init(id: String, store: FileUploadStore, file: consuming File, offset: Int) {
        self.id = id
        self.store = store
        self.file = file
        self.offset = offset
    }

    private var lockDescriptor: Int32 { file.descriptor }
    #endif

    deinit { release() }

    /// Appends `buffer`'s bytes at the end of what is stored.
    public func append(_ buffer: borrowing IOBuffer) async throws {
        precondition(held, "append to a released upload")
        do {
            try await file.write(buffer)
        } catch {
            throw UploadStoreError.system("write", error.code)
        }
        offset &+= buffer.count
    }

    /// Appends `bytes` at the end of what is stored.
    public func append(_ bytes: [UInt8]) async throws {
        var buffer = IOBuffer(capacity: max(1, bytes.count))
        _ = bytes.withUnsafeBytes { buffer.append($0) }
        try await append(buffer)
    }

    /// Drops everything past `offset`, for a request whose bytes turned out
    /// not to be what its digest said. What was stored before this request
    /// began is untouched, so the upload stays resumable from there.
    public func truncate(to offset: Int) async throws {
        precondition(held, "truncate of a released upload")
        precondition(offset <= self.offset, "truncate can only drop bytes")
        do {
            #if os(Windows)
            try await lock.setLength(offset)
            #else
            try await file.setLength(offset)
            #endif
        } catch {
            throw UploadStoreError.system("ftruncate", error.code)
        }
        self.offset = offset
    }

    /// Lets another request append. The file itself closes when the handle
    /// goes; the lock is what others wait on.
    public func release() {
        if held {
            held = false
            unlockUpload(lockDescriptor)
        }
    }
}

public final class FileUploadStore: Sendable {
    public let directory: String
    /// Seconds since the epoch, which ages every upload and answer. Tests
    /// set their own, before the store is used: sleeping past a second on
    /// the wall clock fails whenever WSL steps that clock back.
    let clockSource = Mutex<@Sendable () -> Int>({ secondsSinceEpoch() })
    /// Names the files written aside before they are renamed into place, so
    /// two tasks of a process never write the same one.
    private let written = Atomic<UInt64>(0)

    var clock: @Sendable () -> Int {
        get { clockSource.withLock { $0 } }
        set { clockSource.withLock { $0 = newValue } }
    }

    func now() -> Int { clockSource.withLock { $0 }() }

    /// Uses `directory`, creating it if it does not exist. Made where the
    /// application is, before anything is served, so it waits on nothing.
    public init(directory: String) throws {
        var trimmed = directory
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.directory = trimmed
        #if os(Windows)
        let made = _mkdir(trimmed)
        #else
        let made = mkdir(trimmed, 0o700)
        #endif
        if made != 0 && errno != EEXIST {
            throw UploadStoreError.system("mkdir", errno)
        }
    }

    /// Where an upload's bytes are, for reading once it is complete.
    public func dataPath(_ id: String) -> String { "\(directory)/\(id).data" }
    func infoPath(_ id: String) -> String { "\(directory)/\(id).info" }
    func donePath(_ id: String) -> String { "\(directory)/\(id).done" }

    /// Starts an upload with nothing in it.
    public func create(length: Int?, contentType: String?, contentDisposition: String?,
                       reprDigest: String? = nil,
                       metadata: [String: String] = [:]) async throws -> UploadInfo {
        let hex = Array("0123456789abcdef".utf8)
        var id = [UInt8]()
        id.reserveCapacity(32)
        // From the system's generator: a client guessing another's upload
        // would have to beat it.
        for byte in SecureRandom.bytes(16) {
            id.append(hex[Int(byte >> 4)])
            id.append(hex[Int(byte & 15)])
        }
        let name = String(decoding: id, as: UTF8.self)
        do {
            let file = try await File.open(dataPath(name), options: File.Options(write: true, createNew: true,
                                                                                 permissions: 0o600))
            try file.close()
        } catch {
            throw UploadStoreError.system("open", error.code)
        }
        let info = UploadInfo(id: name, offset: 0, length: length, complete: false,
                              createdAt: now(), contentType: contentType,
                              contentDisposition: contentDisposition, reprDigest: reprDigest,
                              metadata: metadata.isEmpty ? nil : metadata)
        try await save(info)
        return info
    }

    /// The upload's state, with the offset read from the disk, or nil for an
    /// id that is not one of this store's.
    public func info(_ id: String) async throws -> UploadInfo? {
        guard FileUploadStore.isValidID(id) else { return nil }
        guard let bytes = try await readFile(infoPath(id)) else { return nil }
        guard var info = try? JSONCoder.decode(UploadInfo.self, from: bytes) else { return nil }
        do {
            info.offset = try await FileSystem.metadata(dataPath(id)).size
        } catch {
            return nil
        }
        return info
    }

    /// Takes the upload for appending, or nil while another request has it.
    public func acquire(_ id: String) async throws -> UploadHandle? {
        guard FileUploadStore.isValidID(id) else { throw UploadStoreError.notFound }
        let file: File
        do {
            file = try await File.open(dataPath(id), options: File.Options(append: true))
        } catch {
            if error.code == ENOENT { throw UploadStoreError.notFound }
            throw UploadStoreError.system("open", error.code)
        }
        #if os(Windows)
        let lock: File
        do {
            lock = try await File.open(dataPath(id), options: File.Options(read: true, write: true))
        } catch {
            throw UploadStoreError.system("open", error.code)
        }
        let locked = lock.descriptor
        #else
        let locked = file.descriptor
        #endif
        // Never waits: a request holding it may be in another process, and
        // the caller decides how long to wait for it.
        guard try lockUpload(locked) else { return nil }
        let size: Int
        do {
            size = try file.metadataNow().size
        } catch {
            unlockUpload(locked)
            throw UploadStoreError.system("fstat", error.code)
        }
        #if os(Windows)
        return UploadHandle(id: id, store: self, file: file, lock: lock, offset: size)
        #else
        return UploadHandle(id: id, store: self, file: file, offset: size)
        #endif
    }

    /// Records the declared length, or that the upload is whole.
    public func update(_ id: String, length: Int?, complete: Bool) async throws {
        guard var info = try await info(id) else { throw UploadStoreError.notFound }
        info.length = length
        info.complete = complete
        try await save(info)
    }

    /// Removes an upload and its bytes, keeping the answer it was given: the
    /// handler moving a finished upload's bytes somewhere else should not
    /// take away what a client is still owed.
    public func delete(_ id: String) async throws {
        guard FileUploadStore.isValidID(id) else { throw UploadStoreError.notFound }
        var gone = false
        do {
            try await FileSystem.removeFile(infoPath(id))
        } catch {
            gone = error.code == ENOENT
        }
        try? await FileSystem.removeFile(dataPath(id))
        if gone { throw UploadStoreError.notFound }
    }

    /// Removes an upload and everything remembered about it, including its
    /// answer: what a client asking for it to be gone means, and what expiry
    /// does.
    public func forget(_ id: String) async throws {
        do {
            try await delete(id)
        } catch {
            try? await FileSystem.removeFile(donePath(id))
            throw error
        }
        try? await FileSystem.removeFile(donePath(id))
    }

    // MARK: - The answer a completed upload was given

    /// The first line of a remembered answer, naming the layout of the rest.
    /// An answer Garuda 1 wrote before there was a version line begins with
    /// its status, which is three digits, so the two never read as each other.
    private static let answerVersion = "2"

    /// Remembers what the completed upload was answered with, so a client
    /// whose connection died before the answer reached it can ask again.
    ///
    /// The file is the version line; the status, when the upload was created
    /// and the content type; the `Location`; and then the body as it was. A
    /// header value cannot hold a newline and the numbers come first on their
    /// line, so there is nothing to escape and nothing to parse wrongly.
    ///
    /// Written on the calling thread: the one caller is a response hook,
    /// which runs as the answer is sent and cannot wait, and the answer has to
    /// be on the disk by then, for a client that asks again at once.
    public func remember(_ id: String, status: Int, contentType: String?,
                         location: String? = nil, body: [UInt8], createdAt: Int) throws {
        guard FileUploadStore.isValidID(id) else { throw UploadStoreError.notFound }
        var bytes = Array("""
            \(FileUploadStore.answerVersion)
            \(status) \(createdAt) \(contentType ?? "")
            \(location ?? "")
            """.utf8)
        bytes.append(UInt8(ascii: "\n"))
        bytes += body
        let temporary = asideName(donePath(id))
        #if os(Windows)
        try writeReplacing(donePath(id), through: temporary, bytes)
        #else
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 { throw UploadStoreError.system("open", errno) }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0 {
                if errno == EINTR { continue }
                let e = errno
                _ = close(fd)
                _ = unlink(temporary)
                throw UploadStoreError.system("write", e)
            }
            done += n
        }
        _ = close(fd)
        if rename(temporary, donePath(id)) != 0 {
            let e = errno
            _ = unlink(temporary)
            throw UploadStoreError.system("rename", e)
        }
        #endif
    }

    /// The answer a completed upload was given, or nil for an upload that has
    /// none: one still going, or one whose answer has expired.
    public func answer(_ id: String) async throws -> UploadAnswer? {
        guard FileUploadStore.isValidID(id) else { return nil }
        guard let bytes = try await readFile(donePath(id)) else { return nil }
        var rest = bytes[...]
        // An answer Garuda 1 wrote before there was a version line has no
        // `Location` and no line to say so; the rest of it reads the same.
        guard let first = FileUploadStore.line(&rest) else { return nil }
        guard first == FileUploadStore.answerVersion else {
            return FileUploadStore.answer(head: first, location: nil, body: Array(rest))
        }
        guard let head = FileUploadStore.line(&rest),
              let location = FileUploadStore.line(&rest) else { return nil }
        return FileUploadStore.answer(head: head, location: location.isEmpty ? nil : location,
                                      body: Array(rest))
    }

    /// The bytes up to the next newline, taking them and it off `bytes`.
    private static func line(_ bytes: inout ArraySlice<UInt8>) -> String? {
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        defer { bytes = bytes[(newline + 1)...] }
        return String(decoding: bytes[..<newline], as: UTF8.self)
    }

    /// One remembered answer, from the line that holds its numbers.
    private static func answer(head: String, location: String?,
                               body: [UInt8]) -> UploadAnswer? {
        let fields = head.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let status = Int(fields[0]),
              let createdAt = Int(fields[1]) else { return nil }
        let type = String(fields[2])
        return UploadAnswer(status: status, contentType: type.isEmpty ? nil : type,
                            location: location, body: body, createdAt: createdAt)
    }

    /// Removes every upload created more than `seconds` ago. Returns how
    /// many went.
    @discardableResult
    public func removeExpired(olderThan seconds: Int) async -> Int {
        guard let entries = try? await FileSystem.contentsOfDirectory(directory) else { return 0 }
        var ids: [String] = []
        var answers: [String] = []
        for entry in entries {
            if entry.name.hasSuffix(".info") { ids.append(String(entry.name.dropLast(5))) }
            // An upload whose handler removed its bytes leaves only the
            // answer, which expires by its own age.
            if entry.name.hasSuffix(".done") { answers.append(String(entry.name.dropLast(5))) }
        }
        let cutoff = now() - seconds
        var removed = 0
        for id in ids {
            guard let info = try? await info(id), info.createdAt < cutoff else { continue }
            if (try? await forget(id)) != nil { removed += 1 }
        }
        // A set: an array asked once per answer made this quadratic.
        let live = Set(ids)
        for id in answers where !live.contains(id) {
            guard let answer = try? await answer(id), answer.createdAt < cutoff else { continue }
            try? await FileSystem.removeFile(donePath(id))
        }
        return removed
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// A name beside `path` for a file written aside, this process's and
    /// this write's alone.
    private func asideName(_ path: String) -> String {
        "\(path).\(getpid()).\(written.add(1, ordering: .relaxed).newValue).tmp"
    }

    /// Written aside and renamed over, so a reader never sees half of it.
    private func save(_ info: UploadInfo) async throws {
        let bytes = try JSONCoder.encode(info)
        var buffer = IOBuffer(capacity: bytes.count)
        _ = bytes.withUnsafeBytes { buffer.append($0) }
        let path = infoPath(info.id)
        let temporary = asideName(path)
        do {
            let file = try await File.open(temporary, options: File.Options(write: true, truncate: true, create: true,
                                                                             permissions: 0o600))
            try await file.write(buffer)
            try file.close()
            try await FileSystem.rename(temporary, to: path)
        } catch {
            try? await FileSystem.removeFile(temporary)
            throw UploadStoreError.system("write", error.code)
        }
    }

    /// A file's bytes, or nil when there is no such file.
    private func readFile(_ path: String) async throws -> [UInt8]? {
        do {
            return try await FileSystem.read(path)
        } catch {
            if error.code == ENOENT { return nil }
            throw UploadStoreError.system("read", error.code)
        }
    }
}

// MARK: - The few calls each platform makes its own way

#if os(Windows)
/// The C library's errno, which ucrt keeps behind a function.
private var errno: Int32 { _errno().pointee }
#endif

/// Seconds since the epoch, from the wall clock.
private func secondsSinceEpoch() -> Int {
    #if os(Windows)
    Int(_time64(nil))
    #else
    Int(time(nil))
    #endif
}

/// Takes the exclusive lock on an upload's data file without waiting: false
/// while another request, in this process or another, holds it.
private func lockUpload(_ descriptor: Int32) throws -> Bool {
    #if os(Windows)
    // A byte far past any data, so the lock bars other lockers and never a
    // reader: Windows' locks are mandatory over the range they cover.
    var at = OVERLAPPED()
    at.Offset = 0xFFFF_FFFE
    at.OffsetHigh = 0x7FFF_FFFF
    let handle = HANDLE(bitPattern: Int(descriptor))
    if LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &at) {
        return true
    }
    let e = GetLastError()
    if e == DWORD(ERROR_LOCK_VIOLATION) || e == DWORD(ERROR_IO_PENDING) { return false }
    throw UploadStoreError.system("LockFileEx", Int32(bitPattern: e))
    #else
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let e = errno
        if e == EWOULDBLOCK { return false }
        throw UploadStoreError.system("flock", e)
    }
    return true
    #endif
}

/// Lets the next request take the upload.
private func unlockUpload(_ descriptor: Int32) {
    #if os(Windows)
    var at = OVERLAPPED()
    at.Offset = 0xFFFF_FFFE
    at.OffsetHigh = 0x7FFF_FFFF
    _ = UnlockFileEx(HANDLE(bitPattern: Int(descriptor)), 0, 1, 0, &at)
    #else
    _ = flock(descriptor, LOCK_UN)
    #endif
}

#if os(Windows)
/// `bytes` written to `temporary` and moved over `path`, so a reader sees
/// the old file or the new one: stdio, as ucrt's open is variadic, and
/// MoveFileExW, as its rename will not replace a file.
private func writeReplacing(_ path: String, through temporary: String, _ bytes: [UInt8]) throws {
    guard let file = fopen(temporary, "wb") else { throw UploadStoreError.system("open", errno) }
    let written = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, file) }
    let flushed = fclose(file) == 0
    if written != bytes.count || !flushed {
        let e = errno
        _ = remove(temporary)
        throw UploadStoreError.system("write", e)
    }
    let moved = temporary.withCString(encodedAs: UTF16.self) { from in
        path.withCString(encodedAs: UTF16.self) { to in
            MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
    }
    if !moved {
        let e = GetLastError()
        _ = remove(temporary)
        throw UploadStoreError.system("rename", Int32(bitPattern: e))
    }
}
#endif
