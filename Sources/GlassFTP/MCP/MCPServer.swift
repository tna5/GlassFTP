import Foundation
import Logging

/// `GlassFTP --mcp`: the app as a Model Context Protocol server.
///
/// An agent on this Mac (Claude Desktop, Claude Code, Cursor…) starts the
/// binary with `--mcp` and talks JSON-RPC to it over stdin/stdout, one message
/// per line. No window opens: the process only reads the saved connections, the
/// Keychain and `known_hosts`, exactly as the app would, and answers tool calls
/// with `SFTPProvider`.
///
/// Everything is gated by Settings › Agents, which is re-read on every call so
/// switching it off takes effect without restarting the agent.
enum MCPServer {
    /// Newest first. An unknown version from the client gets the newest one,
    /// as the specification asks.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Serves until the agent closes stdin, then exits.
    @MainActor
    static func run() -> Never {
        // Stdout belongs to the protocol: a single stray line — a `print`, a
        // log from Citadel — would be read as a malformed message and end the
        // session. Keep a private copy of the real stdout for messages and
        // point file descriptor 1 at stderr for everything else.
        let protocolDescriptor = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        // The agent going away mid-write must not kill us with SIGPIPE before
        // the connections are closed.
        signal(SIGPIPE, SIG_IGN)

        let session = MCPSession(output: MCPOutput(fileDescriptor: protocolDescriptor))

        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard !line.allSatisfy(\.isWhitespace) else { continue }
                let data = Data(line.utf8)
                // The main queue keeps messages in arrival order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { session.receive(data) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Generic arguments spelled out: with `exit` returning
                    // `Never`, the closure otherwise matches both the
                    // throwing and the non-throwing `Task.init`.
                    Task<Void, Never> {
                        await session.shutdown()
                        exit(0)
                    }
                }
            }
        }

        dispatchMain()
    }
}

/// Writes one JSON-RPC message per line.
final class MCPOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let write: (Data) -> Void

    init(write: @escaping (Data) -> Void) {
        self.write = write
    }

    convenience init(fileDescriptor: Int32) {
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        self.init { data in try? handle.write(contentsOf: data) }
    }

    func send(_ message: [String: Any]) {
        // Not pretty-printed: a message must not contain a newline.
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }
}

/// Throttled `notifications/progress` for one long tool call.
final class MCPProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    private let token: Any
    private let output: MCPOutput

    init(token: Any, output: MCPOutput) {
        self.token = token
        self.output = output
    }

    func report(_ done: Int64, _ total: Int64) {
        lock.lock()
        let now = Date()
        let due = done >= total || now.timeIntervalSince(lastSent) >= 0.25
        if due { lastSent = now }
        lock.unlock()
        guard due else { return }

        output.send([
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": ["progressToken": token, "progress": done, "total": total]
        ])
    }
}

/// One agent's conversation: JSON-RPC framing and dispatch.
@MainActor
final class MCPSession {
    private let output: MCPOutput
    private let tools = MCPTools()
    /// Tool calls in flight, by request id, so the agent can cancel them.
    private var running: [String: Task<Void, Never>] = [:]

    init(output: MCPOutput) {
        self.output = output
    }

    func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            sendError(id: NSNull(), code: -32700, message: "Parse error")
            return
        }
        // Batches left the specification in 2025-06-18; older clients may
        // still send them.
        if let batch = object as? [[String: Any]] {
            batch.forEach(handle)
        } else if let message = object as? [String: Any] {
            handle(message)
        } else {
            sendError(id: NSNull(), code: -32600, message: "Invalid request")
        }
    }

    func shutdown() async {
        running.values.forEach { $0.cancel() }
        await tools.disconnectAll()
    }

    private func handle(_ message: [String: Any]) {
        // No method means a response; this server never sends requests.
        guard let method = message["method"] as? String else { return }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(to: id, initializeResult(params))
        case "ping":
            reply(to: id, [:])
        case "tools/list":
            reply(to: id, ["tools": MCPTools.listedTools()])
        case "tools/call":
            call(id: id, params)
        case "notifications/cancelled":
            if let requestID = params["requestId"] {
                running.removeValue(forKey: Self.key(requestID))?.cancel()
            }
        default:
            // Other notifications (`initialized` included) need no answer.
            guard !method.hasPrefix("notifications/"), let id else { return }
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { MCPServer.protocolVersions.contains($0) ? $0 : nil }
            ?? MCPServer.protocolVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "glassftp", "title": "GlassFTP", "version": MCPServer.version],
            "instructions": """
            GlassFTP gives access to the SFTP servers its user has shared with agents. \
            Call list_servers first and pass a server's name or id to the other tools. \
            Relative remote paths start from the server's start folder. \
            Local paths must be absolute paths on this Mac.
            """
        ]
    }

    private func call(id: Any?, _ params: [String: Any]) {
        guard let id else { return }
        guard let name = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "Missing tool name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        var progress: ProgressHandler?
        if let token = (params["_meta"] as? [String: Any])?["progressToken"] {
            let reporter = MCPProgress(token: token, output: output)
            progress = { done, total in reporter.report(done, total) }
        }

        let key = Self.key(id)
        running[key] = Task {
            let result = await tools.call(name, arguments: arguments, progress: progress)
            running[key] = nil
            // A cancelled request gets no response.
            guard !Task.isCancelled else { return }
            reply(to: id, result)
        }
    }

    private func reply(to id: Any?, _ result: [String: Any]) {
        guard let id else { return }
        output.send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any, code: Int, message: String) {
        output.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Request ids are strings or numbers.
    private static func key(_ id: Any) -> String { "\(id)" }
}
