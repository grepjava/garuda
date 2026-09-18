//===----------------------------------------------------------------------===//
// Where uploads are kept while they are in progress.
//
// Workers are separate processes, and a client that resumes after a dropped
// connection is as likely to reach a different worker as the same one, so
// nothing about an upload lives in a worker's memory. `FileUploadStore` keeps
// each one as two files in a directory:
//
//   <id>.data   the bytes received so far; its size is the offset
//   <id>.info   the declared length, whether it is complete, when it was
//               created, and the metadata sent with it
//
// The offset is the data file's size rather than a number written beside it,
// so a worker that crashes part-way through an append leaves an upload whose
// offset is exactly what reached the disk. Only one request appends to an
// upload at a time, across processes: `acquire` takes an exclusive flock on
// the data file and fails at once if another request holds it.
//
// Writes are ordinary blocking system calls on the worker's thread. For a
// local disk that is the same trade as serving a static file; a store on
// slower storage should be given its own.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda

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
}

public enum UploadStoreError: Error, Equatable {
    /// A system call failed, with its errno.
    case system(String, Int32)
    case notFound
}

/// An upload held for appending. Release it when the request is done.
public final class UploadHandle {
    public let id: String
    let store: FileUploadStore
    private var fd: Int32
    /// Bytes stored so far, including this handle's appends.
    public private(set) var offset: Int

    init(id: String, store: FileUploadStore, fd: Int32, offset: Int) {
        self.id = id
        self.store = store
        self.fd = fd
        self.offset = offset
    }

    deinit { release() }

    /// Appends `bytes` at the end of what is stored.
    public func append(_ bytes: [UInt8]) throws {
        precondition(fd >= 0, "append to a released upload")
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + done, $0.count - done)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw UploadStoreError.system("write", errno)
            }
            done += n
        }
        offset += bytes.count
    }

    /// Drops everything past `offset`, for a request whose bytes turned out
    /// not to be what its digest said. What was stored before this request
    /// began is untouched, so the upload stays resumable from there.
    public func truncate(to offset: Int) throws {
        precondition(fd >= 0, "truncate of a released upload")
        precondition(offset <= self.offset, "truncate can only drop bytes")
        while ftruncate(fd, off_t(offset)) != 0 {
            if errno == EINTR { continue }
            throw UploadStoreError.system("ftruncate", errno)
        }
        self.offset = offset
    }

    /// Lets another request append.
    public func release() {
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            fd = -1
        }
    }
}

public final class FileUploadStore: @unchecked Sendable {
    public let directory: String

    /// Uses `directory`, creating it if it does not exist.
    public init(directory: String) throws {
        var trimmed = directory
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.directory = trimmed
        if mkdir(trimmed, 0o700) != 0 && errno != EEXIST {
            throw UploadStoreError.system("mkdir", errno)
        }
    }

    /// Where an upload's bytes are, for reading once it is complete.
    public func dataPath(_ id: String) -> String { "\(directory)/\(id).data" }
    func infoPath(_ id: String) -> String { "\(directory)/\(id).info" }

    /// Starts an upload with nothing in it.
    public func create(length: Int?, contentType: String?, contentDisposition: String?,
                       reprDigest: String? = nil) throws -> UploadInfo {
        var id = ""
        for byte in (0..<16).map({ _ in UInt8.random(in: 0...255) }) {
            let hex: [Character] = Array("0123456789abcdef")
            id.append(hex[Int(byte >> 4)])
            id.append(hex[Int(byte & 15)])
        }
        let fd = open(dataPath(id), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw UploadStoreError.system("open", errno) }
        _ = close(fd)
        let info = UploadInfo(id: id, offset: 0, length: length, complete: false,
                              createdAt: Int(time(nil)), contentType: contentType,
                              contentDisposition: contentDisposition, reprDigest: reprDigest)
        try save(info)
        return info
    }

    /// The upload's state, with the offset read from the disk, or nil for an
    /// id that is not one of this store's.
    public func info(_ id: String) throws -> UploadInfo? {
        guard FileUploadStore.isValidID(id) else { return nil }
        guard let bytes = try readFile(infoPath(id)) else { return nil }
        guard var info = try? JSONCoder.decode(UploadInfo.self, from: bytes) else { return nil }
        var st = stat()
        guard stat(dataPath(id), &st) == 0 else { return nil }
        info.offset = Int(st.st_size)
        return info
    }

    /// Takes the upload for appending, or nil while another request has it.
    public func acquire(_ id: String) throws -> UploadHandle? {
        guard FileUploadStore.isValidID(id) else { throw UploadStoreError.notFound }
        let fd = open(dataPath(id), O_WRONLY | O_APPEND)
        if fd < 0 {
            if errno == ENOENT { throw UploadStoreError.notFound }
            throw UploadStoreError.system("open", errno)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            _ = close(fd)
            if e == EWOULDBLOCK { return nil }
            throw UploadStoreError.system("flock", e)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno
            _ = close(fd)
            throw UploadStoreError.system("fstat", e)
        }
        return UploadHandle(id: id, store: self, fd: fd, offset: Int(st.st_size))
    }

    /// Records the declared length, or that the upload is whole.
    public func update(_ id: String, length: Int?, complete: Bool) throws {
        guard var info = try info(id) else { throw UploadStoreError.notFound }
        info.length = length
        info.complete = complete
        try save(info)
    }

    /// Removes an upload and its bytes.
    public func delete(_ id: String) throws {
        guard FileUploadStore.isValidID(id) else { throw UploadStoreError.notFound }
        let gone = unlink(infoPath(id)) != 0 && errno == ENOENT
        _ = unlink(dataPath(id))
        if gone { throw UploadStoreError.notFound }
    }

    /// Removes every upload created more than `seconds` ago. Returns how
    /// many went.
    @discardableResult
    public func removeExpired(olderThan seconds: Int) -> Int {
        guard let dir = opendir(directory) else { return 0 }
        var ids: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name.hasSuffix(".info") { ids.append(String(name.dropLast(5))) }
        }
        closedir(dir)
        let cutoff = Int(time(nil)) - seconds
        var removed = 0
        for id in ids {
            guard let info = try? info(id), info.createdAt < cutoff else { continue }
            if (try? delete(id)) != nil { removed += 1 }
        }
        return removed
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private func save(_ info: UploadInfo) throws {
        let bytes = try JSONCoder.encode(info)
        // Written aside and renamed over, so a reader never sees half of it.
        let temporary = infoPath(info.id) + ".\(getpid()).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 { throw UploadStoreError.system("open", errno) }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0 {
                if errno == EINTR { continue }
                let e = errno
                _ = close(fd)
                throw UploadStoreError.system("write", e)
            }
            done += n
        }
        _ = close(fd)
        if rename(temporary, infoPath(info.id)) != 0 { throw UploadStoreError.system("rename", errno) }
    }

    private func readFile(_ path: String) throws -> [UInt8]? {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw UploadStoreError.system("open", errno)
        }
        defer { _ = close(fd) }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw UploadStoreError.system("read", errno)
            }
            if n == 0 { break }
            out += chunk[0..<n]
        }
        return out
    }
}
