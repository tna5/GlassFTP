import Foundation

/// A local file accessed by absolute offset.
///
/// Pipelined transfers land chunks out of order, so `FileHandle.seek` + `write`
/// is unusable: the seek and the write are two steps against one shared file
/// offset, and concurrent workers would interleave them. `pwrite`/`pread` take
/// the offset as an argument and are safe from several threads at once.
final class ChunkedFile: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Creates (or truncates) a file and reserves its final size up front.
    ///
    /// Pre-allocating keeps a fifty-gigabyte download from growing the file
    /// thousands of times and fragmenting it across the disk.
    static func create(at url: URL, size: Int64) throws -> ChunkedFile {
        // Qualified: the type has its own `open`, which would shadow this.
        let descriptor = Darwin.open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw errnoError("create \(url.lastPathComponent)") }

        if size > 0, ftruncate(descriptor, off_t(size)) != 0 {
            let error = errnoError("allocate \(url.lastPathComponent)")
            Darwin.close(descriptor)
            throw error
        }
        return ChunkedFile(descriptor: descriptor)
    }

    /// Opens an existing partial download to continue it, discarding anything
    /// past `length` — the tail that may hold holes left by chunks that were
    /// still in flight when it stopped.
    static func openForResume(at url: URL, truncatingTo length: Int64) throws -> ChunkedFile {
        let descriptor = Darwin.open(url.path, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw errnoError("open \(url.lastPathComponent)") }

        if ftruncate(descriptor, off_t(max(length, 0))) != 0 {
            let error = errnoError("truncate \(url.lastPathComponent)")
            Darwin.close(descriptor)
            throw error
        }
        return ChunkedFile(descriptor: descriptor)
    }

    static func openForReading(at url: URL) throws -> ChunkedFile {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw errnoError("open \(url.lastPathComponent)") }
        return ChunkedFile(descriptor: descriptor)
    }

    func write(_ data: Data, at offset: Int64) throws {
        var written = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // pwrite may be short; loop until the whole chunk has landed.
            while written < raw.count {
                let result = pwrite(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written,
                    off_t(offset) + off_t(written)
                )
                guard result > 0 else { throw Self.errnoError("write") }
                written += result
            }
        }
    }

    /// Reads up to `count` bytes at `offset`. A short result means end of file.
    func read(count: Int, at offset: Int64) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0

        while filled < count {
            let result = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pread(
                    descriptor,
                    base.advanced(by: filled),
                    count - filled,
                    off_t(offset) + off_t(filled)
                )
            }
            if result == 0 { break }
            guard result > 0 else { throw Self.errnoError("read") }
            filled += result
        }
        return Data(buffer.prefix(filled))
    }

    func size() throws -> Int64 {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.errnoError("stat") }
        return Int64(info.st_size)
    }

    func close() {
        Darwin.close(descriptor)
    }

    private static func errnoError(_ action: String) -> ProviderError {
        .operationFailed("Could not \(action): \(String(cString: strerror(errno)))")
    }

    private func errnoError(_ action: String) -> ProviderError {
        Self.errnoError(action)
    }
}

/// A thread-safe cursor handing out chunk offsets to pipeline workers.
final class ChunkCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int64 = 0
    private var transferred: Int64 = 0

    private let total: Int64
    private let chunkSize: Int

    /// `start` skips the part of the file a resumed transfer already has; it
    /// counts as transferred so progress picks up where it left off.
    init(total: Int64, chunkSize: Int, start: Int64 = 0) {
        self.total = total
        self.chunkSize = max(chunkSize, 1)
        self.next = min(max(start, 0), total)
        self.transferred = self.next
    }

    /// The next range to transfer, or `nil` when the file is covered.
    func claim() -> (offset: Int64, length: Int)? {
        lock.lock()
        defer { lock.unlock() }

        guard next < total else { return nil }
        let offset = next
        let length = Int(Swift.min(Int64(chunkSize), total - offset))
        next += Int64(length)
        return (offset, length)
    }

    /// Records progress and returns the running total.
    func advance(by bytes: Int) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        transferred += Int64(bytes)
        return transferred
    }
}
