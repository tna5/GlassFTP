import Foundation

/// Thrown by a tool; the message goes back to the agent as the tool's result,
/// so it says what to do next rather than only what went wrong.
struct MCPToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The tools `GlassFTP --mcp` offers, and the SFTP sessions behind them.
///
/// One `SFTPProvider` per server, opened on first use and kept for the rest of
/// the agent's session. Host keys are never accepted here: there is nobody to
/// ask, so only servers already pinned in `known_hosts` connect.
@MainActor
final class MCPTools {
    enum Need {
        case read
        case write
        case delete
    }

    struct Definition {
        let name: String
        let title: String
        let description: String
        let need: Need
        /// Can overwrite or remove something that cannot be got back.
        var destructive = false
        var idempotent = false
        let properties: [String: [String: Any]]
        let required: [String]

        var json: [String: Any] {
            [
                "name": name,
                "title": title,
                "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false
                ],
                "annotations": [
                    "title": title,
                    "readOnlyHint": need == .read,
                    "destructiveHint": destructive,
                    "idempotentHint": idempotent,
                    "openWorldHint": true
                ]
            ]
        }
    }

    // MARK: - Catalogue

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static let server = string("Server name or id, as returned by list_servers.")
    private static let remotePath = "Remote path. Relative paths start from the server's start folder; ~ is the home folder."
    private static let overwrite = boolean("Replace the destination if it already exists. Defaults to false.")

    static var all: [Definition] {
        [
            Definition(
                name: "list_servers",
                title: "List servers",
                description: "Lists the SFTP servers the user has shared with agents in GlassFTP, with their name, host, user and start folder. Call this first.",
                need: .read,
                idempotent: true,
                properties: [:],
                required: []
            ),
            Definition(
                name: "list_directory",
                title: "List folder",
                description: "Lists a remote folder: name, type, size, modification date and permissions of each entry, folders first.",
                need: .read,
                idempotent: true,
                properties: [
                    "server": server,
                    "path": string(remotePath + " Defaults to the start folder."),
                    "show_hidden": boolean("Include dotfiles. Defaults to true."),
                    "limit": integer("Most entries to return, 1 to 10000. Defaults to 1000.")
                ],
                required: ["server"]
            ),
            Definition(
                name: "get_info",
                title: "Get info",
                description: "Type, size, modification date and permissions of one remote file or folder. Symbolic links are followed.",
                need: .read,
                idempotent: true,
                properties: ["server": server, "path": string(remotePath)],
                required: ["server", "path"]
            ),
            Definition(
                name: "read_text_file",
                title: "Read text file",
                description: "Returns the contents of a remote text file (UTF-8). Binary files are refused: use download_file for those.",
                need: .read,
                idempotent: true,
                properties: [
                    "server": server,
                    "path": string(remotePath),
                    "max_bytes": integer("Most bytes to read, up to 4194304. Defaults to 262144; longer files are cut and say so.")
                ],
                required: ["server", "path"]
            ),
            Definition(
                name: "download_file",
                title: "Download file",
                description: "Copies one remote file to this Mac. Folders are not downloaded recursively.",
                need: .read,
                properties: [
                    "server": server,
                    "remote_path": string(remotePath),
                    "local_path": string("Absolute local path (~ allowed). An existing folder receives the file under its remote name."),
                    "overwrite": overwrite
                ],
                required: ["server", "remote_path", "local_path"]
            ),
            Definition(
                name: "upload_file",
                title: "Upload file",
                description: "Copies one local file to the server. Folders are not uploaded recursively.",
                need: .write,
                destructive: true,
                properties: [
                    "server": server,
                    "local_path": string("Absolute local path of the file to send (~ allowed)."),
                    "remote_path": string(remotePath + " An existing folder receives the file under its local name."),
                    "overwrite": overwrite
                ],
                required: ["server", "local_path", "remote_path"]
            ),
            Definition(
                name: "write_text_file",
                title: "Write text file",
                description: "Creates or replaces a remote file with the given UTF-8 text.",
                need: .write,
                destructive: true,
                properties: [
                    "server": server,
                    "path": string(remotePath),
                    "content": string("The complete new contents of the file."),
                    "overwrite": overwrite
                ],
                required: ["server", "path", "content"]
            ),
            Definition(
                name: "create_directory",
                title: "New folder",
                description: "Creates a remote folder.",
                need: .write,
                idempotent: true,
                properties: [
                    "server": server,
                    "path": string(remotePath),
                    "recursive": boolean("Also create missing parent folders, like mkdir -p. Defaults to false.")
                ],
                required: ["server", "path"]
            ),
            Definition(
                name: "move",
                title: "Rename or move",
                description: "Renames or moves a remote file or folder on the server; nothing is re-transferred. Never replaces an existing item.",
                need: .write,
                properties: [
                    "server": server,
                    "from": string(remotePath),
                    "to": string(remotePath + " An existing folder receives the item under its current name.")
                ],
                required: ["server", "from", "to"]
            ),
            Definition(
                name: "set_permissions",
                title: "Change permissions",
                description: "chmod: sets the permission bits of a remote file or folder.",
                need: .write,
                idempotent: true,
                properties: [
                    "server": server,
                    "path": string(remotePath),
                    "mode": string("Octal mode, for example \"644\" or \"0755\".")
                ],
                required: ["server", "path", "mode"]
            ),
            Definition(
                name: "delete",
                title: "Delete",
                description: "Deletes a remote file, symbolic link or empty folder. It cannot be undone.",
                need: .delete,
                destructive: true,
                properties: ["server": server, "path": string(remotePath)],
                required: ["server", "path"]
            )
        ]
    }

    static func allows(_ need: Need, _ access: AppSettings.Agents.Access) -> Bool {
        switch need {
        case .read: return true
        case .write: return access.canWrite
        case .delete: return access.canDelete
        }
    }

    static func definitions(for access: AppSettings.Agents.Access) -> [[String: Any]] {
        all.filter { allows($0.need, access) }.map(\.json)
    }

    /// What `tools/list` shows: the tools the current access level permits.
    /// When agents are switched off the read tools are still listed, so a call
    /// comes back with "turn it on in Settings" instead of the tools vanishing.
    static func listedTools() -> [[String: Any]] {
        definitions(for: currentSettings().agents.access)
    }

    // MARK: - Settings

    /// Read fresh on every call: the window may have changed them since the
    /// agent started this process.
    private static func currentSettings() -> AppSettings {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return SettingsStore().settings
    }

    private static func enabledAgents() throws -> AppSettings.Agents {
        let agents = currentSettings().agents
        guard agents.enabled else {
            throw MCPToolError("Agent access is turned off. The user can turn it on in GlassFTP › Settings › Agents.")
        }
        return agents
    }

    // MARK: - Calling

    func call(_ name: String, arguments: [String: Any], progress: ProgressHandler?) async -> [String: Any] {
        do {
            guard let definition = Self.all.first(where: { $0.name == name }) else {
                throw MCPToolError("Unknown tool: \(name).")
            }
            let agents = try Self.enabledAgents()
            guard Self.allows(definition.need, agents.access) else {
                throw MCPToolError("“\(definition.title)” is not allowed: in GlassFTP › Settings › Agents, agents may “\(agents.access.label.lowercased())”.")
            }
            let text = try await run(name, Arguments(values: arguments), agents: agents, progress: progress)
            return ["content": [["type": "text", "text": text]]]
        } catch {
            return ["content": [["type": "text", "text": Self.describe(error)]], "isError": true]
        }
    }

    private func run(
        _ name: String,
        _ args: Arguments,
        agents: AppSettings.Agents,
        progress: ProgressHandler?
    ) async throws -> String {
        if name == "list_servers" { return try listServers(agents) }

        let connection = try server(named: args.string("server"), agents)
        let provider = try await provider(for: connection)
        let (base, home) = try await locations(of: connection, on: provider)
        func path(_ key: String) throws -> String {
            let typed = try args.string(key)
            return RemotePath.resolve(typed, from: base, home: home) ?? base
        }
        let report = progress ?? { _, _ in }

        switch name {
        case "list_directory":
            let target = args.optionalString("path").map { RemotePath.resolve($0, from: base, home: home) ?? base } ?? base
            var entries = try await provider.list(target)
            if !args.bool("show_hidden", default: true) {
                entries.removeAll(where: \.isHidden)
            }
            entries.sort { ($0.isDirectory ? 0 : 1, $0.sortKey) < ($1.isDirectory ? 0 : 1, $1.sortKey) }
            let limit = min(max(args.int("limit") ?? 1000, 1), 10_000)
            var result: [String: Any] = [
                "path": target,
                "count": entries.count,
                "entries": entries.prefix(limit).map(Self.describe(entry:))
            ]
            if entries.count > limit {
                result["truncated"] = "Showing the first \(limit) of \(entries.count) entries; pass a larger limit to see more."
            }
            return try Self.json(result)

        case "get_info":
            let target = try path("path")
            guard let entry = try await provider.attributes(at: target) else {
                throw ProviderError.noSuchFile(path: target)
            }
            return try Self.json(Self.describe(entry: entry))

        case "read_text_file":
            let target = try path("path")
            if let entry = try await provider.attributes(at: target), entry.isDirectory {
                throw MCPToolError("\(target) is a folder. Use list_directory to see what is inside.")
            }
            let limit = min(max(args.int("max_bytes") ?? 262_144, 1), 4_194_304)
            // One byte over the limit tells a file of exactly `limit` bytes
            // from a longer one.
            let data = try await provider.read(target, maxBytes: limit + 1)
            let truncated = data.count > limit
            let body = truncated ? data.prefix(limit) : data
            guard !body.contains(0), let text = Self.decodeText(body, truncated: truncated) else {
                throw MCPToolError("\(target) does not look like a text file. Use download_file to copy it to this Mac instead.")
            }
            return truncated
                ? text + "\n\n[GlassFTP: cut after \(limit) bytes; pass a larger max_bytes to read more.]"
                : text

        case "download_file":
            let remote = try path("remote_path")
            guard let entry = try await provider.attributes(at: remote) else {
                throw ProviderError.noSuchFile(path: remote)
            }
            guard !entry.isDirectory else {
                throw MCPToolError("\(remote) is a folder. Only single files are downloaded: list it and download the files you need.")
            }
            var local = try Self.localURL(args.string("local_path"))
            if Self.isLocalDirectory(local) {
                local.appendPathComponent(entry.name)
            }
            if FileManager.default.fileExists(atPath: local.path) {
                guard !Self.isLocalDirectory(local) else {
                    throw MCPToolError("\(local.path) is a folder.")
                }
                guard args.bool("overwrite", default: false) else {
                    throw MCPToolError("\(local.path) already exists. Pass overwrite: true to replace it.")
                }
            }
            guard Self.isLocalDirectory(local.deletingLastPathComponent()) else {
                throw MCPToolError("The folder \(local.deletingLastPathComponent().path) does not exist on this Mac.")
            }
            try await provider.download(from: remote, to: local, resumingAt: 0, keepPartial: false, progress: report)
            return "Downloaded \(remote) to \(local.path) (\(Self.size(entry.size)))."

        case "upload_file":
            let local = try Self.localURL(args.string("local_path"))
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw MCPToolError("\(local.path) does not exist on this Mac.")
            }
            guard !Self.isLocalDirectory(local) else {
                throw MCPToolError("\(local.path) is a folder. Only single files are uploaded: create the folder with create_directory and upload the files one by one.")
            }
            var remote = try path("remote_path")
            if let existing = try await provider.attributes(at: remote), existing.isDirectory {
                remote = RemotePath.join(remote, local.lastPathComponent)
            }
            try await checkDestination(remote, on: provider, overwrite: args.bool("overwrite", default: false))
            try await provider.upload(from: local, to: remote, resumingAt: 0, progress: report)
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? Int64
            return "Uploaded \(local.path) to \(remote)\(size.map { " (\(Self.size($0)))" } ?? "")."

        case "write_text_file":
            let target = try path("path")
            guard let content = args.values["content"] as? String else {
                throw MCPToolError("Missing “content”.")
            }
            try await checkDestination(target, on: provider, overwrite: args.bool("overwrite", default: false))
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("glassftp-mcp-\(UUID().uuidString)")
            try Data(content.utf8).write(to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await provider.upload(from: staging, to: target, resumingAt: 0, progress: report)
            return "Wrote \(Self.size(Int64(content.utf8.count))) to \(target)."

        case "create_directory":
            let target = try path("path")
            if args.bool("recursive", default: false) {
                var current = RemotePath.root
                for part in target.split(separator: "/") {
                    current = RemotePath.join(current, String(part))
                    if let existing = try await provider.attributes(at: current) {
                        guard existing.isDirectory else {
                            throw MCPToolError("\(current) exists and is not a folder.")
                        }
                        continue
                    }
                    try await provider.makeDirectory(at: current)
                }
            } else {
                try await provider.makeDirectory(at: target)
            }
            return "Created \(target)."

        case "move":
            let source = try path("from")
            var destination = try path("to")
            if let existing = try await provider.attributes(at: destination), existing.isDirectory {
                destination = RemotePath.join(destination, RemotePath.lastComponent(of: source))
            }
            if try await provider.attributes(at: destination) != nil {
                throw MCPToolError("\(destination) already exists. Move or delete it first.")
            }
            try await provider.rename(from: source, to: destination)
            return "Moved \(source) to \(destination)."

        case "set_permissions":
            let target = try path("path")
            let typed = try args.string("mode").trimmingCharacters(in: .whitespaces)
            guard let mode = UInt16(typed, radix: 8), mode <= 0o7777 else {
                throw MCPToolError("“\(typed)” is not an octal mode such as 644 or 0755.")
            }
            try await provider.setPermissions(mode, at: target)
            return "Set the permissions of \(target) to \(String(mode, radix: 8))."

        case "delete":
            let typed = try path("path")
            let itemName = RemotePath.lastComponent(of: typed)
            guard typed != RemotePath.root, itemName != ".", itemName != ".." else {
                throw MCPToolError("Refusing to delete \(typed).")
            }
            // Resolve the parent, not the item: realpath on a symbolic link
            // would answer with its target, and the target would be deleted.
            let parent = try await provider.realPath(RemotePath.parent(of: typed))
            guard let entry = try await provider.list(parent).first(where: { $0.name == itemName }) else {
                throw ProviderError.noSuchFile(path: typed)
            }
            do {
                try await provider.remove(entry)
            } catch let error where entry.isDirectory {
                throw MCPToolError("\(Self.describe(error)) Only empty folders can be deleted: delete what is inside first.")
            }
            return "Deleted \(entry.path)."

        default:
            throw MCPToolError("Unknown tool: \(name).")
        }
    }

    // MARK: - Servers

    private static func sharedConnections(_ agents: AppSettings.Agents) -> [Connection] {
        ConnectionStore().connections.filter { agents.allowedConnectionIDs.contains($0.id) }
    }

    private func listServers(_ agents: AppSettings.Agents) throws -> String {
        let shared = Self.sharedConnections(agents)
        guard !shared.isEmpty else {
            return "No server is shared with agents yet. The user can tick the servers agents may use in GlassFTP › Settings › Agents."
        }
        let servers: [[String: Any]] = shared.map { connection in
            [
                "id": connection.id.uuidString,
                "name": connection.displayName,
                "host": connection.host,
                "port": connection.port,
                "username": connection.username,
                "start_folder": connection.initialPath.isEmpty ? "~" : connection.initialPath
            ]
        }
        return try Self.json(["servers": servers, "agents_may": agents.access.label])
    }

    /// By id, then by name, then by host — whichever is unambiguous.
    private func server(named wanted: String, _ agents: AppSettings.Agents) throws -> Connection {
        let shared = Self.sharedConnections(agents)
        let typed = wanted.trimmingCharacters(in: .whitespaces)

        if let id = UUID(uuidString: typed), let match = shared.first(where: { $0.id == id }) {
            return match
        }
        for matches in [
            shared.filter { $0.displayName.caseInsensitiveCompare(typed) == .orderedSame },
            shared.filter { $0.host.caseInsensitiveCompare(typed) == .orderedSame }
        ] {
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw MCPToolError("Several servers match “\(typed)”. Pass the id from list_servers instead.")
            }
        }
        throw MCPToolError("No server named “\(typed)” is shared with agents. Call list_servers to see the ones that are.")
    }

    // MARK: - Sessions

    private var providers: [UUID: Task<SFTPProvider, Error>] = [:]
    private var homes: [UUID: String] = [:]

    private func provider(for connection: Connection) async throws -> SFTPProvider {
        if let pending = providers[connection.id] {
            if let provider = try? await pending.value {
                if await provider.isConnected { return provider }
                await provider.disconnect()
            }
            // Another call may have reconnected while this one waited.
            if providers[connection.id] == pending {
                providers[connection.id] = nil
            }
        }
        if let pending = providers[connection.id] {
            return try await pending.value
        }

        let configuration = try configuration(for: connection)
        let task = Task { () async throws -> SFTPProvider in
            // Nobody is there to compare a fingerprint, so an unknown host key
            // is refused; see `describe(_:)` for what the agent is told.
            let provider = SFTPProvider(configuration: configuration, confirmHostKey: { _ in false })
            try await provider.connect()
            return provider
        }
        providers[connection.id] = task
        do {
            return try await task.value
        } catch {
            if providers[connection.id] == task {
                providers[connection.id] = nil
            }
            throw error
        }
    }

    private func configuration(for connection: Connection) throws -> SFTPProvider.Configuration {
        let store = ConnectionStore()
        var password = ""
        if connection.authMethod == .password {
            guard let saved = store.password(for: connection), !saved.isEmpty else {
                throw MCPToolError("No password is saved for \(connection.displayName). The user can save it in GlassFTP (Edit Connection), or switch the server to key authentication.")
            }
            password = saved
        }
        return AppState.configuration(
            for: connection,
            password: password,
            settings: Self.currentSettings(),
            connections: store
        )
    }

    /// The start folder relative paths resolve against, and the home folder
    /// `~` stands for.
    private func locations(of connection: Connection, on provider: SFTPProvider) async throws -> (base: String, home: String) {
        let home: String
        if let cached = homes[connection.id] {
            home = cached
        } else {
            home = try await provider.realPath(".")
            homes[connection.id] = home
        }
        let start = connection.initialPath.trimmingCharacters(in: .whitespaces)
        let base = start.isEmpty ? home : (RemotePath.resolve(start, from: home, home: home) ?? home)
        return (base, home)
    }

    private func checkDestination(_ path: String, on provider: SFTPProvider, overwrite: Bool) async throws {
        guard let existing = try await provider.attributes(at: path) else { return }
        if existing.isDirectory {
            throw MCPToolError("\(path) is a folder.")
        }
        if !overwrite {
            throw MCPToolError("\(path) already exists. Pass overwrite: true to replace it.")
        }
    }

    func disconnectAll() async {
        let open = providers.values
        providers.removeAll()
        for task in open {
            if let provider = try? await task.value {
                await provider.disconnect()
            }
        }
    }

    // MARK: - Formatting

    static func describe(_ error: Error) -> String {
        if let error = error as? MCPToolError { return error.message }
        if let error = error as? ProviderError {
            if case .hostKeyRejected = error {
                return "GlassFTP does not trust this server's host key yet, and agents cannot accept a new key. The user must open the server once in the GlassFTP window and accept its key."
            }
            return [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        return error.localizedDescription
    }

    private static func describe(entry: RemoteEntry) -> [String: Any] {
        var result: [String: Any] = [
            "name": entry.name,
            "path": entry.path,
            "type": { () -> String in
                switch entry.kind {
                case .file: return "file"
                case .directory: return "directory"
                case .symlink: return "symlink"
                }
            }()
        ]
        if entry.kind != .directory { result["size"] = entry.size }
        if let modified = entry.modifiedAt { result["modified"] = modified.ISO8601Format() }
        if let permissions = entry.permissions { result["permissions"] = String(permissions, radix: 8) }
        return result
    }

    private static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// A cut can land inside a multi-byte character; drop up to three
    /// trailing bytes before deciding the file is not text.
    static func decodeText(_ data: Data, truncated: Bool) -> String? {
        for dropped in 0...(truncated ? 3 : 0) {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        return nil
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func localURL(_ typed: String) throws -> URL {
        let expanded = (typed.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw MCPToolError("Local paths must be absolute, such as ~/Downloads/file.txt or /Users/me/file.txt.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func isLocalDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Typed access to a tool call's arguments.
struct Arguments {
    let values: [String: Any]

    func string(_ key: String) throws -> String {
        guard let value = optionalString(key) else {
            throw MCPToolError("Missing “\(key)”.")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = values[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        values[key] as? Bool ?? fallback
    }

    func int(_ key: String) -> Int? {
        values[key] as? Int
    }
}
