import Foundation

/// A saved server, as shown in the sidebar.
///
/// Note what is *not* here: the password. It lives in the Keychain, keyed by
/// `id`, so this struct can be written to disk as plain JSON.
struct Connection: Identifiable, Codable, Hashable, Sendable {
    enum ProtocolKind: String, Codable, Sendable, CaseIterable {
        case sftp

        var displayName: String {
            switch self {
            case .sftp: return "SFTP"
            }
        }

        var defaultPort: Int {
            switch self {
            case .sftp: return 22
            }
        }
    }

    enum AuthMethod: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey

        var label: String {
            switch self {
            case .password: return "Password"
            case .privateKey: return "Private Key"
            }
        }
    }

    var id: UUID
    var name: String
    var kind: ProtocolKind
    var host: String
    var port: Int
    var username: String
    /// Directory to open on connect. Empty means the server's default (home).
    var initialPath: String
    var authMethod: AuthMethod
    /// Path to an OpenSSH or PEM private key; used with `.privateKey`. Its
    /// passphrase, if any, is in the Keychain.
    var privateKeyPath: String
    var proxy: ProxyOverride

    init(
        id: UUID = UUID(),
        name: String = "",
        kind: ProtocolKind = .sftp,
        host: String = "",
        port: Int = 22,
        username: String = "",
        initialPath: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String = "",
        proxy: ProxyOverride = .useDefault
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.initialPath = initialPath
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.proxy = proxy
    }

    /// Written out so that `connections.json` files from before a field existed
    /// still load. The synthesized decoder throws on any missing key, and the
    /// store would then quietly come up empty — every saved server gone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.value(.name, default: "")
        kind = container.value(.kind, default: .sftp)
        host = container.value(.host, default: "")
        port = container.value(.port, default: 22)
        username = container.value(.username, default: "")
        initialPath = container.value(.initialPath, default: "")
        authMethod = container.value(.authMethod, default: .password)
        privateKeyPath = container.value(.privateKeyPath, default: "")
        proxy = container.value(.proxy, default: .useDefault)
    }

    /// Name to show when the user left the label blank.
    var displayName: String {
        if !name.isEmpty { return name }
        if host.isEmpty { return "New Connection" }
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    var subtitle: String {
        let hostPart = port == kind.defaultPort ? host : "\(host):\(port)"
        return username.isEmpty ? hostPart : "\(username)@\(hostPart)"
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
            && (authMethod == .password || !privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
