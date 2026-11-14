import AppKit
import SwiftUI

/// Settings › Agents: lets AI agents on this Mac use the saved servers through
/// `GlassFTP --mcp` (see `MCPServer`).
struct AgentsSettingsTab: View {
    @Environment(AppState.self) private var app

    @State private var message: String?

    var body: some View {
        @Bindable var store = app.settings
        let agents = store.settings.agents

        SettingsForm {
            store.settings.agents = .init()
        } content: {
            Section {
                Toggle("Let AI agents use GlassFTP", isOn: $store.settings.agents.enabled)
            } footer: {
                SettingsFooter("GlassFTP works as an MCP server: an agent on this Mac — Claude Desktop, Claude Code, Cursor and others — starts it in the background and browses or transfers files on the servers ticked below. Passwords and keys stay in the Keychain; the agent never sees them. Turning this off takes effect on the agent's next request.")
            }

            Section {
                if app.connections.connections.isEmpty {
                    Text("No saved servers yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.connections.connections) { connection in
                    Toggle(isOn: isShared(connection.id, in: store)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.displayName)
                            Text(connection.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                SettingsFooter("Only ticked servers are visible to agents, and servers added later stay hidden until ticked. A server must have been opened once in this window so its host key is trusted — agents cannot accept a new key — and a password server needs its password saved.")
            }
            .disabled(!agents.enabled)

            Section {
                Picker("Agents may", selection: $store.settings.agents.access) {
                    ForEach(AppSettings.Agents.Access.allCases) { access in
                        Text(access.label).tag(access)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Permissions")
            } footer: {
                SettingsFooter("Browsing includes reading text files and downloading to this Mac. Deleting cannot be undone, so it is allowed separately. Agents load their list of tools when they start: restart the agent after changing this.")
            }
            .disabled(!agents.enabled)

            Section {
                LabeledContent("Command") {
                    Text(Self.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Add to Claude Desktop", action: addToClaudeDesktop)
                    Spacer()
                    Button("Copy Claude Code Command") {
                        copy(Self.claudeCodeCommand, "Copied. Paste it in Terminal.")
                    }
                    Button("Copy JSON") {
                        copy(Self.jsonConfiguration, "Copied. Paste it in the agent's MCP settings.")
                    }
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connect an Agent")
            } footer: {
                SettingsFooter("Claude Desktop: add GlassFTP, then quit and reopen Claude. Claude Code: run the copied command in Terminal. Other agents: paste the JSON into their MCP server settings. Keep GlassFTP in Applications: the agent starts it from this path.")
            }
            .disabled(!agents.enabled)
        }
    }

    private func isShared(_ id: UUID, in store: SettingsStore) -> Binding<Bool> {
        Binding(
            get: { store.settings.agents.allowedConnectionIDs.contains(id) },
            set: { shared in
                if shared {
                    store.settings.agents.allowedConnectionIDs.insert(id)
                } else {
                    store.settings.agents.allowedConnectionIDs.remove(id)
                }
            }
        )
    }

    // MARK: - Agent configuration

    private static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    private static var commandLine: String {
        "\(shellQuoted(executablePath)) --mcp"
    }

    private static var claudeCodeCommand: String {
        "claude mcp add --scope user glassftp -- \(commandLine)"
    }

    private static var serverEntry: [String: Any] {
        ["command": executablePath, "args": ["--mcp"]]
    }

    private static var jsonConfiguration: String {
        let object: [String: Any] = ["mcpServers": ["glassftp": serverEntry]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { " '\"\\$`!&;|<>()*?[]#~".contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func copy(_ text: String, _ confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = confirmation
    }

    /// Adds a `glassftp` entry to Claude Desktop's configuration, keeping
    /// every other server and setting already in the file.
    private func addToClaudeDesktop() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let file = folder.appendingPathComponent("claude_desktop_config.json")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            message = "Claude Desktop does not seem to be installed. Open it once, then try again — or copy the JSON."
            return
        }

        var configuration: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Rewriting a file we cannot parse would lose whatever is in it.
                message = "claude_desktop_config.json could not be read, so it was left alone. Copy the JSON and add it by hand."
                return
            }
            configuration = existing
        }

        var servers = configuration["mcpServers"] as? [String: Any] ?? [:]
        servers["glassftp"] = Self.serverEntry
        configuration["mcpServers"] = servers

        do {
            let data = try JSONSerialization.data(
                withJSONObject: configuration,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: file, options: .atomic)
            message = "Added. Quit and reopen Claude Desktop to use GlassFTP."
        } catch {
            message = "Could not update Claude Desktop: \(error.localizedDescription)"
        }
    }
}
