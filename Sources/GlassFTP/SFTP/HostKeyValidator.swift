import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// What the UI is asked to decide when a host key is not yet pinned.
struct HostKeyChallenge: Sendable, Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
}

/// Trust-on-first-use host key validation, mirroring OpenSSH's behaviour.
///
/// NIOSSH calls us on an event loop and expects a promise, so the user prompt —
/// which is inherently async and main-actor-bound — is bridged through a
/// detached task that fulfills the promise once the user has decided.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store: KnownHostsStore
    private let confirm: @Sendable (HostKeyChallenge) async -> Bool

    /// Why we rejected, if we did. NIOSSH collapses every validation failure
    /// into one opaque channel error, so we record the real reason here and
    /// `SFTPProvider` reads it back to show something actionable.
    private let recordedFailure = NIOLockedValueBox<ProviderError?>(nil)

    var failure: ProviderError? { recordedFailure.withLockedValue { $0 } }

    init(
        host: String,
        port: Int,
        store: KnownHostsStore = KnownHostsStore(),
        confirm: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) {
        self.host = host
        self.port = port
        self.store = store
        self.confirm = confirm
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch store.match(host: host, port: port, key: hostKey) {
        case .trusted:
            validationCompletePromise.succeed(())

        case .mismatch(let pinned):
            // Never offer to override this. A pinned host presenting a
            // different key of the same type is exactly the shape of an
            // interception, and the fix belongs in known_hosts, not in a dialog.
            let error = ProviderError.hostKeyChanged(
                expected: pinned.sha256Fingerprint,
                received: hostKey.sha256Fingerprint
            )
            recordedFailure.withLockedValue { $0 = error }
            validationCompletePromise.fail(error)

        case .unknown:
            let challenge = HostKeyChallenge(
                host: host,
                port: port,
                algorithm: hostKey.algorithmName,
                fingerprint: hostKey.sha256Fingerprint
            )
            let store = self.store
            let host = self.host
            let port = self.port
            let confirm = self.confirm
            let recordedFailure = self.recordedFailure

            Task.detached {
                guard await confirm(challenge) else {
                    recordedFailure.withLockedValue { $0 = .hostKeyRejected }
                    validationCompletePromise.fail(ProviderError.hostKeyRejected)
                    return
                }
                do {
                    try store.append(host: host, port: port, key: hostKey)
                } catch {
                    // Pinning failed (read-only home, bad permissions). The
                    // user accepted this key, so let the connection through and
                    // simply ask again next time rather than failing outright.
                }
                validationCompletePromise.succeed(())
            }
        }
    }
}
