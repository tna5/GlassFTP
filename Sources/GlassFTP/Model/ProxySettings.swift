import CFNetwork
import Foundation

/// A proxy as configured by the user. The password is not here — it lives in
/// the Keychain, like connection passwords.
struct ProxySettings: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case off
        /// Whatever System Settings › Network › Proxies says, SOCKS first.
        case system
        case socks5
        case httpConnect

        var label: String {
            switch self {
            case .off: return "None"
            case .system: return "Use system settings"
            case .socks5: return "SOCKS5"
            case .httpConnect: return "HTTP CONNECT"
            }
        }

        var defaultPort: Int {
            switch self {
            case .httpConnect: return 8080
            default: return 1080
            }
        }

        /// Whether host, port and credentials apply.
        var isManual: Bool { self == .socks5 || self == .httpConnect }
    }

    var kind = Kind.off
    var host = ""
    var port = 1080
    var username = ""

    init(kind: Kind = .off, host: String = "", port: Int = 1080, username: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        kind = container.value(.kind, default: defaults.kind)
        host = container.value(.host, default: defaults.host)
        port = container.value(.port, default: defaults.port)
        username = container.value(.username, default: defaults.username)
    }

    static let globalKeychainAccount = "proxy.global"
}

/// How one connection relates to the global proxy.
enum ProxyOverride: Codable, Hashable, Sendable {
    case useDefault
    /// Connect directly even when a global proxy is set.
    case direct
    case custom(ProxySettings)
}

/// A proxy resolved down to something that can be dialled.
struct ProxyEndpoint: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case socks5
        case httpConnect
    }

    var kind: Kind
    var host: String
    var port: Int
    var username: String = ""
    var password: String = ""

    var hasCredentials: Bool { !username.isEmpty }

    var summary: String {
        let name = kind == .socks5 ? "SOCKS5" : "HTTP"
        return "\(name) \(host):\(port)"
    }
}

enum ProxyResolver {
    /// Picks the proxy a connection to `targetHost` should go through, if any.
    ///
    /// Pure apart from the closures, so the precedence rules can be tested
    /// without a Keychain or a system proxy configuration.
    static func resolve(
        global: ProxySettings,
        override: ProxyOverride,
        targetHost: String,
        password: (_ isGlobal: Bool) -> String?,
        systemSettings: () -> [String: Any]?
    ) -> ProxyEndpoint? {
        let settings: ProxySettings
        let isGlobal: Bool
        switch override {
        case .direct:
            return nil
        case .useDefault:
            settings = global
            isGlobal = true
        case .custom(let custom):
            settings = custom
            isGlobal = false
        }

        switch settings.kind {
        case .off:
            return nil
        case .system:
            guard let dictionary = systemSettings() else { return nil }
            return system(from: dictionary, targetHost: targetHost)
        case .socks5, .httpConnect:
            let host = settings.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, (1...65535).contains(settings.port) else { return nil }
            return ProxyEndpoint(
                kind: settings.kind == .socks5 ? .socks5 : .httpConnect,
                host: host,
                port: settings.port,
                username: settings.username,
                password: settings.username.isEmpty ? "" : (password(isGlobal) ?? "")
            )
        }
    }

    /// Reads a `CFNetworkCopySystemProxySettings` dictionary.
    ///
    /// SOCKS wins over HTTPS: it carries any TCP stream as-is, whereas many
    /// HTTP proxies refuse CONNECT to anything but port 443.
    static func system(from settings: [String: Any], targetHost: String) -> ProxyEndpoint? {
        if isExcepted(targetHost, by: settings["ExceptionsList"] as? [String] ?? []) { return nil }

        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue ?? false }

        if enabled("SOCKSEnable"), let host = settings["SOCKSProxy"] as? String, !host.isEmpty {
            let port = (settings["SOCKSPort"] as? NSNumber)?.intValue ?? 1080
            return ProxyEndpoint(kind: .socks5, host: host, port: port)
        }
        if enabled("HTTPSEnable"), let host = settings["HTTPSProxy"] as? String, !host.isEmpty {
            let port = (settings["HTTPSPort"] as? NSNumber)?.intValue ?? 8080
            return ProxyEndpoint(kind: .httpConnect, host: host, port: port)
        }
        return nil
    }

    /// System Settings' "Bypass proxy settings for these hosts": exact names
    /// and `*.example.com` suffix patterns.
    static func isExcepted(_ host: String, by exceptions: [String]) -> Bool {
        let host = host.lowercased()
        return exceptions.contains { raw in
            let pattern = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))
                return host.hasSuffix(suffix) || host == String(suffix.dropFirst())
            }
            return host == pattern
        }
    }

    static func currentSystemSettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }
}
