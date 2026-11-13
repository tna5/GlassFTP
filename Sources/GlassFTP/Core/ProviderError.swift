import Foundation

/// Protocol-agnostic error surfaced to the UI.
///
/// Providers translate their own failures into these cases so that views never
/// have to know which protocol produced the error.
enum ProviderError: LocalizedError {
    case notConnected
    case authenticationFailed
    case connectionFailed(String)
    case proxyFailed(String)
    case hostKeyRejected
    case hostKeyChanged(expected: String, received: String)
    case permissionDenied(path: String)
    case noSuchFile(path: String)
    case alreadyExists(path: String)
    case operationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected."
        case .authenticationFailed:
            return "Authentication failed."
        case .connectionFailed(let detail):
            return "Could not connect: \(detail)"
        case .proxyFailed(let detail):
            return "Proxy error: \(detail)"
        case .hostKeyRejected:
            return "The host key was not accepted."
        case .hostKeyChanged:
            return "The host key has changed."
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .noSuchFile(let path):
            return "No such file or directory: \(path)"
        case .alreadyExists(let path):
            return "Already exists: \(path)"
        case .operationFailed(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .authenticationFailed:
            return "Check the username and the password or key for this connection."
        case .proxyFailed:
            return "Check the proxy in Settings › Proxy, or set this connection to connect directly."
        case .hostKeyChanged(let expected, let received):
            return """
            The server presented a key that does not match the one pinned in \
            ~/.ssh/known_hosts.

            Pinned:   \(expected)
            Received: \(received)

            This can mean the server was reinstalled — or that the connection is \
            being intercepted. Remove the old line from ~/.ssh/known_hosts only if \
            you can confirm the change through a trusted channel.
            """
        case .permissionDenied:
            return "The account you are signed in as does not have access to this path."
        default:
            return nil
        }
    }
}
