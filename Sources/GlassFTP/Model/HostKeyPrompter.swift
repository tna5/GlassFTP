import Foundation
import Observation

/// Bridges the host-key decision from the SSH event loop to a SwiftUI sheet.
///
/// `TOFUHostKeyValidator` needs an answer from a non-isolated context; the user
/// gives it from the main actor. This holds the suspended continuation in
/// between.
@MainActor
@Observable
final class HostKeyPrompter {
    private(set) var pending: HostKeyChallenge?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// A closure suitable for handing to `SFTPProvider`.
    nonisolated func confirmationHandler() -> @Sendable (HostKeyChallenge) async -> Bool {
        { [weak self] challenge in
            guard let self else { return false }
            return await self.ask(challenge)
        }
    }

    private func ask(_ challenge: HostKeyChallenge) async -> Bool {
        // Only one connection attempt is in flight at a time, but if a stale
        // prompt somehow survives, deny it rather than leaking the continuation.
        if let continuation {
            continuation.resume(returning: false)
            self.continuation = nil
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = challenge
        }
    }

    func respond(accepted: Bool) {
        pending = nil
        continuation?.resume(returning: accepted)
        continuation = nil
    }
}
