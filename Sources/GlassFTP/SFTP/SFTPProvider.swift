import Citadel
import Foundation
import Logging
import NIOCore

/// SFTP implementation of `FileProvider`.
///
/// Being an actor is load-bearing: Citadel's `SSHClient`/`SFTPClient` are tied
/// to an event loop and are not safe to drive from several tasks at once. All
/// Citadel types stay inside this actor — only value types leave it.
actor SFTPProvider: FileProvider {
    struct Configuration: Sendable {
        enum Auth: Sendable {
            case password(String)
            case privateKey(path: String, passphrase: String?)
        }

        var host: String
        var port: Int
        var username: String
        var auth: Auth
        /// Dialled instead of the host when set; see `ProxyConnector`.
        var proxy: ProxyEndpoint?
        var connectTimeoutSeconds = 30
        var tuning = Tuning()
    }

    /// Transfer shape, from Settings › Advanced.
    ///
    /// Throughput on one connection is capped at (bytes in flight) ÷ (round
    /// trip), so everything here is about keeping enough bytes in flight
    /// without breaking a server's limits.
    struct Tuning: Equatable, Sendable {
        /// Bytes asked for per read request. OpenSSH's sftp-server answers
        /// reads of up to 255 KB (`SFTP_MAX_READ_LENGTH`); a server that caps
        /// lower answers short, and the download adopts what it answers with
        /// (see `performDownload`).
        var readSize = 261_120
        var readsInFlight = 16

        /// Bytes per write request. Citadel cuts every write into 32,000-byte
        /// requests sent one after another, so anything that is not a
        /// multiple of that costs an extra round trip for the remainder.
        var writeSize = 32_000
        /// 64 × 32,000 ≈ 2 MB, OpenSSH's channel window: more in flight would
        /// only queue behind it.
        var writesInFlight = 64

        /// The SSH channel window we grant the server, i.e. how much it may
        /// send before waiting for us to acknowledge. NIOSSH ties it to the
        /// maximum packet size, which defaults to 128 KB — at 50 ms round trip
        /// that alone caps a download at 2.6 MB/s. 16 MB is NIOSSH's ceiling.
        var receiveWindow = 1 << 24

        /// Upper bound on what one file may have in flight in either
        /// direction. It also bounds where out-of-order chunks can leave holes
        /// in a partial file, which is what resuming backs off by
        /// (`TransferPlanner.resumeSafetyMargin`).
        static let maximumBytesInFlight = 8 << 20

        /// The values GlassFTP used before, kept for the benchmark.
        static let legacy = Tuning(
            readSize: 32_768,
            readsInFlight: 16,
            writeSize: 32_768,
            writesInFlight: 16,
            receiveWindow: 1 << 17
        )

        /// Concurrent requests for `chunk`-sized pieces, within the budget.
        static func depth(_ wanted: Int, chunk: Int) -> Int {
            min(max(wanted, 1), max(maximumBytesInFlight / max(chunk, 1), 1))
        }
    }

    let configuration: Configuration
    private let confirmHostKey: @Sendable (HostKeyChallenge) async -> Bool
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private let logger: Logger

    init(
        configuration: Configuration,
        confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) {
        self.configuration = configuration
        self.confirmHostKey = confirmHostKey
        var logger = Logger(label: "com.glassftp.sftp")
        // Citadel logs every request at .info, which floods the console.
        logger.logLevel = .warning
        self.logger = logger
    }

    // MARK: - Connection

    var isConnected: Bool { sftp?.isActive == true }

    func connect() async throws {
        guard client == nil else { return }

        let validator = TOFUHostKeyValidator(
            host: configuration.host,
            port: configuration.port,
            confirm: confirmHostKey
        )

        let authentication: SSHAuthenticationMethod
        switch configuration.auth {
        case .password(let password):
            authentication = .passwordBased(username: configuration.username, password: password)
        case .privateKey(let path, let passphrase):
            authentication = try PrivateKeyLoader.authenticationMethod(
                username: configuration.username,
                keyPath: path,
                passphrase: passphrase
            )
        }

        var settings = SSHClientSettings(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: { authentication },
            hostKeyValidator: .custom(validator)
        )
        // The receive window equals the maximum packet size in NIOSSH, which
        // accepts 32 KB to 16 MB.
        settings.protocolOptions = [
            .maximumPacketSize(min(max(configuration.tuning.receiveWindow, 32_768), 1 << 24))
        ]
        let timeout = TimeAmount.seconds(Int64(max(configuration.connectTimeoutSeconds, 1)))
        settings.connectTimeout = timeout

        let connected: SSHClient
        do {
            if let proxy = configuration.proxy {
                let channel = try await ProxyConnector.connect(
                    through: proxy,
                    to: configuration.host,
                    port: configuration.port,
                    timeout: timeout
                )
                do {
                    connected = try await SSHClient.connect(on: channel, settings: settings)
                } catch {
                    try? await channel.close()
                    throw error
                }
            } else {
                connected = try await SSHClient.connect(to: settings)
            }
        } catch {
            // A host key rejection surfaces here as a generic channel error, so
            // prefer the reason the validator recorded.
            throw validator.failure ?? Self.translate(error)
        }

        do {
            sftp = try await connected.openSFTP(logger: logger)
        } catch {
            try? await connected.close()
            throw Self.translate(error)
        }
        client = connected
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    private func session() throws -> SFTPClient {
        guard let sftp, sftp.isActive else { throw ProviderError.notConnected }
        return sftp
    }

    // MARK: - Browsing

    func list(_ path: String) async throws -> [RemoteEntry] {
        let sftp = try session()
        let directory = RemotePath.normalize(path)

        let listing: [SFTPMessage.Name]
        do {
            listing = try await sftp.listDirectory(atPath: directory)
        } catch {
            throw Self.translate(error, path: directory)
        }

        // Each `Name` response carries a batch of entries; the server splits a
        // directory across as many responses as it likes.
        return listing
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                Self.entry(from: component, in: directory)
            }
    }

    /// Stats one path, following symlinks. `nil` when nothing is there, which
    /// is the common answer when checking an upload's destination.
    func attributes(at path: String) async throws -> RemoteEntry? {
        let sftp = try session()
        let attributes: SFTPFileAttributes
        do {
            attributes = try await sftp.getAttributes(at: path)
        } catch {
            let translated = Self.translate(error, path: path)
            if case .noSuchFile = translated { return nil }
            throw translated
        }
        let mode = attributes.permissions
        return RemoteEntry(
            name: RemotePath.lastComponent(of: path),
            path: RemotePath.normalize(path),
            kind: mode.map { $0 & 0xF000 == 0x4000 ? .directory : .file } ?? .file,
            size: Int64(attributes.size ?? 0),
            modifiedAt: attributes.accessModificationTime?.modificationTime,
            permissions: mode.map { UInt16($0 & 0o7777) }
        )
    }

    func setModificationTime(_ date: Date, at path: String) async throws {
        let sftp = try session()
        var attributes = SFTPFileAttributes()
        attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
        do {
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    func realPath(_ path: String) async throws -> String {
        let sftp = try session()
        do {
            return try await sftp.getRealPath(atPath: path)
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    // MARK: - Mutations

    func makeDirectory(at path: String) async throws {
        let sftp = try session()
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    func remove(_ entry: RemoteEntry) async throws {
        let sftp = try session()
        do {
            // rmdir and remove are distinct operations in the protocol; sending
            // the wrong one fails even when the path is correct.
            if entry.kind == .directory {
                try await sftp.rmdir(at: entry.path)
            } else {
                try await sftp.remove(at: entry.path)
            }
        } catch {
            throw Self.translate(error, path: entry.path)
        }
    }

    func rename(from source: String, to destination: String) async throws {
        let sftp = try session()
        do {
            try await sftp.rename(at: source, to: destination)
        } catch {
            throw Self.translate(error, path: source)
        }
    }

    func setPermissions(_ mode: UInt16, at path: String) async throws {
        let sftp = try session()
        do {
            // Read first so we preserve the file-type bits: writing bare
            // permission bits would clear the type and confuse some servers.
            let current = try await sftp.getAttributes(at: path)
            let typeBits = (current.permissions ?? 0) & 0xF000
            var attributes = SFTPFileAttributes()
            attributes.permissions = typeBits | UInt32(mode & 0o7777)
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    // MARK: - Mapping

    private static func entry(from component: SFTPPathComponent, in directory: String) -> RemoteEntry {
        let mode = component.attributes.permissions
        let kind = self.kind(mode: mode, longname: component.longname)

        return RemoteEntry(
            name: component.filename,
            path: RemotePath.join(directory, component.filename),
            kind: kind,
            size: Int64(component.attributes.size ?? 0),
            modifiedAt: component.attributes.accessModificationTime?.modificationTime,
            permissions: mode.map { UInt16($0 & 0o7777) }
        )
    }

    private static func kind(mode: UInt32?, longname: String) -> RemoteEntry.Kind {
        if let mode, mode & 0xF000 != 0 {
            switch mode & 0xF000 {
            case 0x4000: return .directory
            case 0xA000: return .symlink
            default: return .file
            }
        }
        // Servers may omit permissions from a listing. `longname` is an `ls -l`
        // line, whose first character is the type.
        switch longname.first {
        case "d": return .directory
        case "l": return .symlink
        default: return .file
        }
    }

    /// Turns Citadel/NIO errors into `ProviderError`, which is what the UI
    /// knows how to present.
    static func translate(_ error: Error, path: String? = nil) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return .cancelled }

        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .permissionDenied:
                return .permissionDenied(path: path ?? status.message)
            case .noSuchFile:
                return .noSuchFile(path: path ?? status.message)
            case .failure where status.message.localizedCaseInsensitiveContains("exists"):
                return .alreadyExists(path: path ?? status.message)
            case .eof:
                return .operationFailed("Unexpected end of file.")
            default:
                let detail = status.message.isEmpty
                    ? String(describing: status.errorCode)
                    : status.message
                return .operationFailed(detail)
            }
        }

        let description = String(describing: error)
        if description.contains("authenticationFailed") || description.contains("allAuthenticationOptionsFailed") {
            return .authenticationFailed
        }
        return .connectionFailed(description)
    }

    // MARK: - Transfers
    //
    // Implemented in SFTPTransfers.swift, which needs the private chunk size
    // and session accessor above.

    func download(
        from remotePath: String,
        to localURL: URL,
        resumingAt offset: Int64,
        keepPartial: Bool,
        progress: @escaping ProgressHandler
    ) async throws {
        try await performDownload(
            from: remotePath,
            to: localURL,
            resumingAt: offset,
            keepPartial: keepPartial,
            progress: progress
        )
    }

    func upload(
        from localURL: URL,
        to remotePath: String,
        resumingAt offset: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        try await performUpload(from: localURL, to: remotePath, resumingAt: offset, progress: progress)
    }

    /// Reads at most `maxBytes` from a file, for previewing.
    ///
    /// Bounded on purpose: a preview must never start streaming a multi-gigabyte
    /// file into memory because someone tapped the space bar.
    func read(_ path: String, maxBytes: Int) async throws -> Data {
        let sftp = try session()

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: .read)
        } catch {
            throw Self.translate(error, path: path)
        }
        defer { Task { try? await file.close() } }

        var data = Data()
        var offset: UInt64 = 0
        do {
            while data.count < maxBytes {
                try Task.checkCancellation()

                let wanted = min(configuration.tuning.readSize, maxBytes - data.count)
                var buffer = try await file.read(from: offset, length: UInt32(wanted))
                let readable = buffer.readableBytes
                guard readable > 0, let bytes = buffer.readBytes(length: readable) else { break }

                data.append(contentsOf: bytes)
                offset += UInt64(readable)
            }
        } catch {
            throw Self.translate(error, path: path)
        }
        return data
    }

    fileprivate func openSession() throws -> SFTPClient { try session() }
}

// MARK: - Transfer implementations

extension SFTPProvider {
    /// Downloads a file, optionally continuing from `offset`.
    ///
    /// No pre-allocation: after a crash, a pre-allocated file has its final
    /// size and nothing on disk says how much of it is real. Without it, the
    /// size is the highest offset written, and resuming backs off by
    /// `TransferPlanner.resumeSafetyMargin` to cover the chunks that were
    /// still in flight below it.
    func performDownload(
        from remotePath: String,
        to localURL: URL,
        resumingAt offset: Int64,
        keepPartial: Bool,
        progress: @escaping ProgressHandler
    ) async throws {
        let sftp = try openSession()
        let tuning = configuration.tuning

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: .read)
        } catch {
            throw Self.translate(error, path: remotePath)
        }
        defer { Task { try? await file.close() } }

        let total = Int64((try? await file.readAttributes().size) ?? 0)

        // Without a size we cannot partition the file, so fall back to walking
        // it sequentially.
        guard total > 0 else {
            try await sequentialDownload(file, from: remotePath, to: localURL, chunkSize: tuning.readSize, progress: progress)
            return
        }

        let start = min(max(offset, 0), total)
        let destination = start > 0
            ? try ChunkedFile.openForResume(at: localURL, truncatingTo: start)
            : try ChunkedFile.create(at: localURL, size: 0)

        do {
            // One read first, to learn how much this server answers per
            // request: asking for more than it gives would turn every chunk
            // into a full one plus a sequential top-up.
            var chunk = tuning.readSize
            var next = start
            if start < total {
                let wanted = Int(min(Int64(chunk), total - start))
                let probe = try await file.read(from: UInt64(start), length: UInt32(wanted))
                let answered = probe.readableBytes
                try destination.write(probe, at: start)
                next += Int64(answered)
                progress(next, total)
                if answered > 0, answered < wanted {
                    // Keep it a multiple of 4 KB so later reads stay aligned.
                    chunk = max(answered / 4_096 * 4_096, 4_096)
                }
                if answered == 0 { next = total }
            }

            let cursor = ChunkCursor(total: total, chunkSize: chunk, start: next)
            let depth = Tuning.depth(tuning.readsInFlight * tuning.readSize / chunk, chunk: chunk)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<depth {
                    group.addTask {
                        while let piece = cursor.claim() {
                            try Task.checkCancellation()

                            let received = try await Self.readFully(
                                file,
                                offset: piece.offset,
                                length: piece.length,
                                into: destination
                            )
                            guard received > 0 else { break }
                            progress(cursor.advance(by: received), total)
                        }
                    }
                }
                try await group.waitForAll()
            }
            destination.close()
        } catch {
            destination.close()
            if !keepPartial {
                try? FileManager.default.removeItem(at: localURL)
            }
            throw Self.translate(error, path: remotePath)
        }
    }

    func performUpload(
        from localURL: URL,
        to remotePath: String,
        resumingAt offset: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        let sftp = try openSession()
        let tuning = configuration.tuning

        let source = try ChunkedFile.openForReading(at: localURL)
        defer { source.close() }
        let total = try source.size()
        let start = min(max(offset, 0), total)

        let file: SFTPFile
        do {
            // Resuming must not truncate: the head of the file is what is
            // being kept.
            file = try await sftp.openFile(
                filePath: remotePath,
                flags: start > 0 ? [.write, .create] : [.write, .create, .truncate]
            )
        } catch {
            throw Self.translate(error, path: remotePath)
        }

        let chunk = max(tuning.writeSize, 1)
        let cursor = ChunkCursor(total: total, chunkSize: chunk, start: start)
        let depth = Tuning.depth(tuning.writesInFlight, chunk: chunk)
        let allocator = ByteBufferAllocator()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<depth {
                    group.addTask {
                        while let piece = cursor.claim() {
                            try Task.checkCancellation()

                            let buffer = try source.readBuffer(count: piece.length, at: piece.offset, allocator: allocator)
                            let sent = buffer.readableBytes
                            guard sent > 0 else { break }

                            try await file.write(buffer, at: UInt64(piece.offset))
                            progress(cursor.advance(by: sent), total)
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw Self.translate(error, path: remotePath)
        }
    }

    /// Fills one chunk, looping until it is complete or the file ends.
    ///
    /// A server is allowed to return fewer bytes than asked for without being
    /// at end of file. With workers writing at fixed offsets, accepting a short
    /// read would punch a hole in the middle of the downloaded file — the kind
    /// of corruption that produces a file of exactly the right size.
    ///
    /// Each answer goes straight to its place in the file, without being
    /// gathered into one buffer first. Returns the bytes received; fewer than
    /// `length` only at end of file.
    private static func readFully(
        _ file: SFTPFile,
        offset: Int64,
        length: Int,
        into destination: ChunkedFile
    ) async throws -> Int {
        var received = 0
        while received < length {
            let buffer = try await file.read(
                from: UInt64(offset) + UInt64(received),
                length: UInt32(length - received)
            )
            let readable = buffer.readableBytes
            guard readable > 0 else { break }
            try destination.write(buffer, at: offset + Int64(received))
            received += readable
        }
        return received
    }

    /// Used when the server does not report a size, so the file cannot be split.
    private func sequentialDownload(
        _ file: SFTPFile,
        from remotePath: String,
        to localURL: URL,
        chunkSize: Int,
        progress: @escaping ProgressHandler
    ) async throws {
        let destination = try ChunkedFile.create(at: localURL, size: 0)
        var offset: Int64 = 0

        do {
            while true {
                try Task.checkCancellation()

                let buffer = try await file.read(
                    from: UInt64(offset),
                    length: UInt32(chunkSize)
                )
                let readable = buffer.readableBytes
                guard readable > 0 else { break }

                try destination.write(buffer, at: offset)
                offset += Int64(readable)
                progress(offset, 0)
            }
            destination.close()
        } catch {
            destination.close()
            try? FileManager.default.removeItem(at: localURL)
            throw Self.translate(error, path: remotePath)
        }
    }
}
