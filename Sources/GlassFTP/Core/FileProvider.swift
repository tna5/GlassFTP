import Foundation

/// Byte-count progress callback: (transferred, total).
typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

/// The abstraction every transfer protocol implements.
///
/// SFTP is the only conformer today; FTP/WebDAV/S3 would slot in here without
/// the UI layer changing. Declared as an `Actor` protocol because every
/// realistic implementation wraps a stateful, non-`Sendable` connection that
/// must serialize its requests.
protocol FileProvider: Actor {
    func connect() async throws
    func disconnect() async

    func list(_ path: String) async throws -> [RemoteEntry]
    func realPath(_ path: String) async throws -> String

    func makeDirectory(at path: String) async throws
    func remove(_ entry: RemoteEntry) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ mode: UInt16, at path: String) async throws

    // Escaping: the pipelined implementations hand the callback to task-group
    // children that outlive the call frame.
    //
    // `offset` resumes an interrupted transfer: the destination's first
    // `offset` bytes are kept and only the rest is sent.
    func download(
        from remotePath: String,
        to localURL: URL,
        resumingAt offset: Int64,
        keepPartial: Bool,
        progress: @escaping ProgressHandler
    ) async throws
    func upload(
        from localURL: URL,
        to remotePath: String,
        resumingAt offset: Int64,
        progress: @escaping ProgressHandler
    ) async throws
}
