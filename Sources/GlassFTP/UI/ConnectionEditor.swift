import AppKit
import SwiftUI

/// Add / edit a saved connection.
struct ConnectionEditor: View {
    /// The Keychain-held values the editor shows and may change.
    struct Secrets {
        var password = ""
        var passphrase = ""
        var proxyPassword = ""
    }

    /// What the editor hands back: `nil` for a secret means "leave the stored
    /// one alone", so saving without touching a field never erases it.
    struct EditedSecrets {
        var password: String?
        var passphrase: String?
        var proxyPassword: String?
    }

    @State private var connection: Connection
    @State private var secrets: Secrets
    @State private var edited: Set<WritableKeyPath<Secrets, String>> = []

    private let isNew: Bool
    private let onSave: (Connection, EditedSecrets) -> Void
    private let onCancel: () -> Void

    init(
        connection: Connection,
        isNew: Bool,
        existingSecrets: Secrets,
        onSave: @escaping (Connection, EditedSecrets) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _connection = State(initialValue: connection)
        _secrets = State(initialValue: existingSecrets)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Form {
                serverSection
                authenticationSection
                pathSection
                proxySection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add" : "Save") {
                    onSave(normalized(), EditedSecrets(
                        password: value(\.password),
                        passphrase: value(\.passphrase),
                        proxyPassword: value(\.proxyPassword)
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!connection.isComplete)
            }
            .padding(20)
        }
        .frame(width: 480, height: 640)
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            TextField("Name", text: $connection.name, prompt: Text(connection.subtitle.isEmpty ? "My Server" : connection.subtitle))
            Picker("Protocol", selection: $connection.kind) {
                ForEach(Connection.ProtocolKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: connection.kind) { _, kind in
                connection.port = kind.defaultPort
            }
            TextField("Server", text: $connection.host, prompt: Text("example.com"))
                .textContentType(.URL)
            TextField("Port", value: $connection.port, format: .number.grouping(.never))
        }
    }

    private var authenticationSection: some View {
        Section {
            TextField("Username", text: $connection.username)
                .textContentType(.username)
            Picker("Authenticate with", selection: $connection.authMethod) {
                ForEach(Connection.AuthMethod.allCases, id: \.self) { method in
                    Text(method.label).tag(method)
                }
            }
            .pickerStyle(.segmented)

            switch connection.authMethod {
            case .password:
                SecureField("Password", text: secret(\.password))
                    .textContentType(.password)
            case .privateKey:
                LabeledContent("Key File") {
                    HStack {
                        Text(connection.privateKeyPath.isEmpty ? "None" : connection.privateKeyPath)
                            .foregroundStyle(connection.privateKeyPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…", action: chooseKey)
                    }
                }
                SecureField("Passphrase", text: secret(\.passphrase), prompt: Text("None"))
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text(connection.authMethod == .password
                 ? "The password is stored in your login Keychain, not in the connection file."
                 : "ed25519 and RSA keys in OpenSSH format, ECDSA keys in PEM. The passphrase is stored in your login Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pathSection: some View {
        Section {
            TextField("Remote Path", text: $connection.initialPath, prompt: Text("Server default"))
        } footer: {
            Text("Leave empty to open the account's home directory. When set, browsing is rooted there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var proxySection: some View {
        Section {
            Picker("Proxy", selection: proxyChoice) {
                Text("Use default from Settings").tag(ProxyChoice.useDefault)
                Text("Connect directly").tag(ProxyChoice.direct)
                Text("Custom").tag(ProxyChoice.custom)
            }

            if case .custom = connection.proxy {
                Picker("Type", selection: customProxy.kind) {
                    Text(ProxySettings.Kind.socks5.label).tag(ProxySettings.Kind.socks5)
                    Text(ProxySettings.Kind.httpConnect.label).tag(ProxySettings.Kind.httpConnect)
                }
                TextField("Proxy Host", text: customProxy.host, prompt: Text("proxy.example.com"))
                TextField("Proxy Port", value: customProxy.port, format: .number.grouping(.never))
                TextField("Proxy Username", text: customProxy.username, prompt: Text("Optional"))
                SecureField("Proxy Password", text: secret(\.proxyPassword), prompt: Text("Optional"))
            }
        } header: {
            Text("Proxy")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Connection" : "Edit Connection")
                    .font(.headline)
                Text(connection.subtitle.isEmpty ? "SFTP over SSH" : connection.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - Bindings

    private enum ProxyChoice: Hashable {
        case useDefault
        case direct
        case custom
    }

    private var proxyChoice: Binding<ProxyChoice> {
        Binding {
            switch connection.proxy {
            case .useDefault: return .useDefault
            case .direct: return .direct
            case .custom: return .custom
            }
        } set: { choice in
            switch choice {
            case .useDefault: connection.proxy = .useDefault
            case .direct: connection.proxy = .direct
            case .custom:
                if case .custom = connection.proxy { return }
                connection.proxy = .custom(ProxySettings(kind: .socks5, port: ProxySettings.Kind.socks5.defaultPort))
            }
        }
    }

    /// The custom proxy's fields, read and written through the enum payload.
    private var customProxy: Binding<ProxySettings> {
        Binding {
            if case .custom(let settings) = connection.proxy { return settings }
            return ProxySettings(kind: .socks5)
        } set: { connection.proxy = .custom($0) }
    }

    /// A binding that remembers the field was touched.
    private func secret(_ keyPath: WritableKeyPath<Secrets, String>) -> Binding<String> {
        Binding {
            secrets[keyPath: keyPath]
        } set: {
            secrets[keyPath: keyPath] = $0
            edited.insert(keyPath)
        }
    }

    private func value(_ keyPath: WritableKeyPath<Secrets, String>) -> String? {
        edited.contains(keyPath) ? secrets[keyPath: keyPath] : nil
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Private Key"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Stored with ~ so the connection file stays valid across a renamed
        // home folder or a migrated Mac.
        let home = NSHomeDirectory()
        connection.privateKeyPath = url.path.hasPrefix(home + "/")
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }

    /// Trim the fields people paste with stray spaces, and accept a pasted
    /// `user@host` in the server field.
    private func normalized() -> Connection {
        var result = connection
        result.host = result.host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = result.username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.initialPath = result.initialPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if let at = result.host.firstIndex(of: "@") {
            let user = String(result.host[..<at])
            let host = String(result.host[result.host.index(after: at)...])
            if !host.isEmpty {
                result.host = host
                if result.username.isEmpty { result.username = user }
            }
        }
        if case .custom(var proxy) = result.proxy {
            proxy.host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            proxy.username = proxy.username.trimmingCharacters(in: .whitespacesAndNewlines)
            result.proxy = .custom(proxy)
        }
        return result
    }
}
