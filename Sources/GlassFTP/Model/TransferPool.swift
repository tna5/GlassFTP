import Foundation

/// The SSH connections a session's transfers run over, separate from the one
/// that browses.
///
/// One connection per file in flight is what makes many small files fast: each
/// file costs several round trips to open, stat and close no matter how fast
/// the link is, and those only overlap across connections. Keeping transfers
/// off the browsing connection also means a 50 GB download never queues behind
/// — or in front of — the listing of the folder the user just clicked.
///
/// Connections are opened lazily, reused, and dropped after an error. The
/// number in use is bounded by the transfer workers, not here.
actor TransferPool {
    private let makeProvider: @Sendable () -> SFTPProvider
    private var idle: [SFTPProvider] = []
    private var maxIdle: Int
    /// Set once the session that owns the pool disconnects. Transfers already
    /// queued finish; connections are closed as they come back.
    private var isRetired = false

    init(maxIdle: Int, makeProvider: @escaping @Sendable () -> SFTPProvider) {
        self.maxIdle = maxIdle
        self.makeProvider = makeProvider
    }

    /// An open connection, reusing an idle one when possible.
    func checkout() async throws -> SFTPProvider {
        while let provider = idle.popLast() {
            if await provider.isConnected { return provider }
            await provider.disconnect()
        }
        let provider = makeProvider()
        try await provider.connect()
        return provider
    }

    /// Returns a connection. A connection that just failed is closed rather
    /// than reused: whatever went wrong may have left it unusable, and a fresh
    /// one costs a handshake, not a failed file.
    func checkin(_ provider: SFTPProvider, healthy: Bool = true) async {
        guard healthy, !isRetired, idle.count < maxIdle else {
            await provider.disconnect()
            return
        }
        idle.append(provider)
    }

    func setMaxIdle(_ count: Int) async {
        maxIdle = max(count, 0)
        while idle.count > maxIdle, let provider = idle.popLast() {
            await provider.disconnect()
        }
    }

    func retire() async {
        isRetired = true
        let closing = idle
        idle = []
        for provider in closing {
            await provider.disconnect()
        }
    }
}
