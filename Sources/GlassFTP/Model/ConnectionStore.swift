import Foundation
import Observation

/// Saved connections, persisted as JSON in Application Support.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("GlassFTP", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    // MARK: - Mutations

    func add(_ connection: Connection, password: String) {
        connections.append(connection)
        persistPassword(password, for: connection.id)
        save()
    }

    func update(_ connection: Connection, password: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        // A nil password means "leave the stored one alone" — the editor sends
        // that when the user did not touch the password field.
        if let password {
            persistPassword(password, for: connection.id)
        }
        save()
    }

    func delete(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        KeychainStore.delete(for: connection.id)
        KeychainStore.delete(account: KeychainStore.passphraseAccount(for: connection.id))
        KeychainStore.delete(account: KeychainStore.proxyAccount(for: connection.id))
        save()
    }

    func password(for connection: Connection) -> String? {
        KeychainStore.password(for: connection.id)
    }

    func passphrase(for connection: Connection) -> String? {
        KeychainStore.secret(account: KeychainStore.passphraseAccount(for: connection.id))
    }

    func setPassphrase(_ passphrase: String, for connection: Connection) {
        KeychainStore.store(passphrase, account: KeychainStore.passphraseAccount(for: connection.id))
    }

    func proxyPassword(for connection: Connection) -> String? {
        KeychainStore.secret(account: KeychainStore.proxyAccount(for: connection.id))
    }

    func setProxyPassword(_ password: String, for connection: Connection) {
        KeychainStore.store(password, account: KeychainStore.proxyAccount(for: connection.id))
    }

    private func persistPassword(_ password: String, for id: UUID) {
        if password.isEmpty {
            KeychainStore.delete(for: id)
            return
        }
        do {
            try KeychainStore.save(password: password, for: id)
        } catch {
            // Losing the password is recoverable — the user is prompted at
            // connect time — so don't take the whole save down with it.
            NSLog("GlassFTP: could not store password in Keychain: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        connections = (try? decoder.decode([Connection].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(connections).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("GlassFTP: could not save connections: \(error.localizedDescription)")
        }
    }
}
