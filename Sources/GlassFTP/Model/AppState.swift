import Foundation
import Observation

/// Top-level app state: saved connections and shortcuts, the live session, and
/// the transfer queue that outlives any single session.
@MainActor
@Observable
final class AppState {
    let settings = SettingsStore()
    let connections = ConnectionStore()
    let shortcuts = ShortcutStore()
    let transfers = TransferManager()
    let hostKeyPrompter = HostKeyPrompter()

    /// The live session, or `nil` when nothing is connected.
    var session: BrowserModel?
    var sidebarSelection: SidebarItem?

    /// Sheet routing. One optional per sheet keeps the presentation logic in
    /// the views trivial.
    var editingConnection: Connection?
    var isEditingNewConnection = false
    var passwordPrompt: PasswordRequest?
    var inspectorEntry: RemoteEntry?
    /// The file shown in the space-bar preview, if any.
    var previewEntry: RemoteEntry?
    var renamingShortcut: Shortcut?
    var isShowingTransfers = false
    var isSearchPresented = false
    var isGoToFolderPresented = false
    /// Puts the path bar into its text-field mode (⌘L).
    var isEditingPath = false

    var connectionError: String?

    /// A connection waiting on a password, plus where to go once it arrives.
    struct PasswordRequest: Identifiable {
        let connection: Connection
        let destination: String?
        var id: UUID { connection.id }
    }

    init() {
        shortcuts.removeOrphans(validConnectionIDs: Set(connections.connections.map(\.id)))
        transfers.options = settings.settings.transfers
    }

    /// Pushes changed settings to everything holding a snapshot.
    func applySettings() {
        let current = settings.settings
        transfers.options = current.transfers
        if let session {
            session.settings = current
            let pool = session.transferPool
            Task { await pool.setMaxIdle(current.transfers.clampedConcurrency + 1) }
        }
    }

    /// "Reconnect to last server on launch".
    func reconnectIfWanted() {
        guard settings.settings.general.reconnectOnLaunch, session == nil,
              let id = settings.lastConnectionID,
              connections.connections.contains(where: { $0.id == id })
        else { return }
        sidebarSelection = .connection(id)
    }

    var isConnected: Bool {
        session?.status == .connected
    }

    func isConnected(to connection: Connection) -> Bool {
        isConnected && session?.connection.id == connection.id
    }

    // MARK: - Sidebar routing

    func handleSidebarSelection(_ item: SidebarItem?) async {
        switch item {
        case .connection(let id):
            guard let connection = connections.connections.first(where: { $0.id == id }) else { return }
            guard session?.connection.id != id else { return }
            await connect(to: connection)

        case .shortcut(let id):
            guard let shortcut = shortcuts.shortcuts.first(where: { $0.id == id }),
                  let connection = connections.connections.first(where: { $0.id == shortcut.connectionID })
            else { return }
            await open(shortcut, on: connection)

        case nil:
            break
        }
    }

    private func open(_ shortcut: Shortcut, on connection: Connection) async {
        if let session, session.connection.id == connection.id, session.status == .connected {
            // Already on the right server — just jump.
            await session.navigate(to: shortcut.path)
            return
        }
        await connect(to: connection, destination: shortcut.path)
    }

    // MARK: - Connecting

    func connect(to connection: Connection, destination: String? = nil) async {
        guard connection.authMethod == .password else {
            await connect(to: connection, password: "", destination: destination)
            return
        }
        guard let password = connections.password(for: connection), !password.isEmpty else {
            // No stored password — ask for it rather than failing with a
            // confusing "authentication failed".
            passwordPrompt = PasswordRequest(connection: connection, destination: destination)
            return
        }
        await connect(to: connection, password: password, destination: destination)
    }

    func connect(to connection: Connection, password: String, destination: String? = nil) async {
        if let existing = session {
            await existing.disconnect()
        }

        let model = BrowserModel(
            connection: connection,
            configuration: configuration(for: connection, password: password),
            settings: settings.settings,
            hostKeyConfirmation: hostKeyPrompter.confirmationHandler()
        )
        session = model
        connectionError = nil

        await model.connect(startingAt: destination)

        if case .failed(let message) = model.status {
            connectionError = message
            session = nil
            // Clear the sidebar selection too, otherwise selecting the same
            // row again is a no-op and the user cannot retry.
            sidebarSelection = nil
        } else if model.status == .connected {
            settings.lastConnectionID = connection.id
        }
    }

    /// Everything the provider needs, with secrets pulled from the Keychain.
    func configuration(for connection: Connection, password: String) -> SFTPProvider.Configuration {
        let auth: SFTPProvider.Configuration.Auth
        switch connection.authMethod {
        case .password:
            auth = .password(password)
        case .privateKey:
            auth = .privateKey(path: connection.privateKeyPath, passphrase: connections.passphrase(for: connection))
        }

        let current = settings.settings
        let proxy = ProxyResolver.resolve(
            global: current.proxy,
            override: connection.proxy,
            targetHost: connection.host,
            password: { [connections] isGlobal in
                isGlobal
                    ? KeychainStore.secret(account: ProxySettings.globalKeychainAccount)
                    : connections.proxyPassword(for: connection)
            },
            systemSettings: ProxyResolver.currentSystemSettings
        )

        return SFTPProvider.Configuration(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            auth: auth,
            proxy: proxy,
            connectTimeoutSeconds: current.connection.connectTimeoutSeconds,
            tuning: current.advanced.tuning
        )
    }

    func disconnect() async {
        guard let session else { return }
        await session.disconnect()
        self.session = nil
        sidebarSelection = nil
    }

    // MARK: - Shortcuts

    /// Bookmarks a folder on the current server.
    func addShortcut(for path: String) {
        guard let session else { return }
        shortcuts.add(connectionID: session.connection.id, path: path)
    }

    func canAddShortcut(for path: String) -> Bool {
        guard let session else { return false }
        return !shortcuts.contains(connectionID: session.connection.id, path: path)
    }

    func delete(_ connection: Connection) async {
        if isConnected(to: connection) { await disconnect() }
        connections.delete(connection)
        shortcuts.removeOrphans(validConnectionIDs: Set(connections.connections.map(\.id)))
    }
}
