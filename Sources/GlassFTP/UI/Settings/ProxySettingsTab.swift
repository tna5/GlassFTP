import NIOCore
import SwiftUI

struct ProxySettingsTab: View {
    @Environment(AppState.self) private var app

    @State private var password = KeychainStore.secret(account: ProxySettings.globalKeychainAccount) ?? ""
    @State private var testTarget: UUID?
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var store = app.settings
        let proxy = store.settings.proxy

        SettingsForm {
            store.settings.proxy = .init()
            password = ""
            KeychainStore.delete(account: ProxySettings.globalKeychainAccount)
        } content: {
            Section {
                Picker("Proxy", selection: $store.settings.proxy.kind) {
                    ForEach(ProxySettings.Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .onChange(of: proxy.kind) { old, new in
                    // Follow the conventional port unless one was typed.
                    if new.isManual, store.settings.proxy.port == old.defaultPort || store.settings.proxy.port == 0 {
                        store.settings.proxy.port = new.defaultPort
                    }
                    testState = .idle
                }

                if proxy.kind.isManual {
                    TextField("Host", text: $store.settings.proxy.host, prompt: Text("proxy.example.com"))
                    TextField("Port", value: $store.settings.proxy.port, format: .number.grouping(.never))
                    TextField("Username", text: $store.settings.proxy.username, prompt: Text("Optional"))
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                        .onChange(of: password) { _, value in
                            KeychainStore.store(value, account: ProxySettings.globalKeychainAccount)
                        }
                } else if proxy.kind == .system {
                    LabeledContent("Currently") {
                        Text(systemSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Default Proxy")
            } footer: {
                SettingsFooter(footer(for: proxy.kind))
            }

            if proxy.kind != .off {
                testSection
            }
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Picker("Through to", selection: $testTarget) {
                Text("Choose a server").tag(UUID?.none)
                ForEach(app.connections.connections) { connection in
                    Text(connection.displayName).tag(UUID?.some(connection.id))
                }
            }
            HStack {
                testResult
                Spacer()
                Button("Test Proxy") { Task { await runTest() } }
                    .disabled(testTarget == nil || testState == .running)
            }
        } header: {
            Text("Test")
        } footer: {
            SettingsFooter("Opens a tunnel through the proxy to the chosen server's SSH port and closes it again. Nothing is sent to the server itself.")
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func runTest() async {
        guard let id = testTarget,
              let connection = app.connections.connections.first(where: { $0.id == id })
        else { return }

        let settings = app.settings.settings
        // Test the default proxy, whatever the connection's own override.
        guard let endpoint = ProxyResolver.resolve(
            global: settings.proxy,
            override: .useDefault,
            targetHost: connection.host,
            password: { _ in password },
            systemSettings: ProxyResolver.currentSystemSettings
        ) else {
            testState = .failed(settings.proxy.kind == .system
                ? "The system has no SOCKS or HTTPS proxy for this host."
                : "Enter the proxy's host and port.")
            return
        }

        testState = .running
        do {
            let channel = try await ProxyConnector.connect(
                through: endpoint,
                to: connection.host,
                port: connection.port,
                timeout: .seconds(Int64(settings.connection.connectTimeoutSeconds))
            )
            try? await channel.close()
            testState = .succeeded("Reached \(connection.host) through \(endpoint.summary)")
        } catch {
            testState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Text

    private var systemSummary: String {
        guard let dictionary = ProxyResolver.currentSystemSettings(),
              let endpoint = ProxyResolver.system(from: dictionary, targetHost: "")
        else { return "No SOCKS or HTTPS proxy configured" }
        return endpoint.summary
    }

    private func footer(for kind: ProxySettings.Kind) -> String {
        switch kind {
        case .off:
            return "Connections go straight to the server. A connection can still use its own proxy, set in its editor."
        case .system:
            return "Follows System Settings › Network › Proxies, preferring SOCKS over HTTPS, and honours its bypass list."
        case .socks5:
            return "The server's name is resolved by the proxy, so hosts that only exist behind it work. An SSH tunnel made with “ssh -D 1080 host” is a SOCKS5 proxy at 127.0.0.1:1080."
        case .httpConnect:
            return "The proxy must allow CONNECT to the server's SSH port; many only allow port 443. The password is stored in your Keychain."
        }
    }
}
