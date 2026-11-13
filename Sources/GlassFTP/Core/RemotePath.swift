import Foundation

/// POSIX path helpers for remote paths.
///
/// Deliberately not using `URL` or `NSString.pathComponents`: remote paths are
/// always POSIX regardless of the local platform, and `URL` would percent-encode
/// characters that are perfectly legal in an SFTP path.
enum RemotePath {
    static let root = "/"

    static func join(_ base: String, _ component: String) -> String {
        if component.hasPrefix("/") { return normalize(component) }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return normalize("\(trimmed)/\(component)")
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root else { return root }
        guard let slash = normalized.lastIndex(of: "/") else { return root }
        return slash == normalized.startIndex ? root : String(normalized[..<slash])
    }

    static func lastComponent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root else { return root }
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    /// Collapses repeated slashes and drops a trailing slash. Does not resolve
    /// `.` or `..` — the server does that, and guessing locally would be wrong
    /// in the presence of symlinks.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return root }
        let isAbsolute = path.hasPrefix("/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let joined = parts.joined(separator: "/")
        if joined.isEmpty { return isAbsolute ? root : "." }
        return isAbsolute ? "/\(joined)" : joined
    }

    /// Breadcrumb segments: display name paired with the absolute path to
    /// navigate to when clicked.
    static func breadcrumbs(for path: String) -> [(name: String, path: String)] {
        breadcrumbs(for: path, relativeTo: root)
    }

    /// Breadcrumbs that stop at `base` instead of at `/`.
    ///
    /// A connection with a remote path set is, as far as the user is concerned,
    /// rooted there — showing the folders above it invites navigating into a
    /// tree they did not ask for. If `path` happens to fall outside `base`
    /// (a shortcut pointing elsewhere, say), the full crumbs are used, because
    /// a truncated trail there would be a lie.
    static func breadcrumbs(for path: String, relativeTo base: String) -> [(name: String, path: String)] {
        let normalized = normalize(path)
        let baseline = normalize(base)

        guard baseline != root, isDescendant(normalized, of: baseline) else {
            var result: [(String, String)] = [("/", root)]
            guard normalized != root else { return result }

            var accumulated = ""
            for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
                accumulated += "/\(part)"
                result.append((String(part), accumulated))
            }
            return result
        }

        var result: [(String, String)] = [(lastComponent(of: baseline), baseline)]
        guard normalized != baseline else { return result }

        let remainder = normalized.dropFirst(baseline.count)
        var accumulated = baseline
        for part in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated += "/\(part)"
            result.append((String(part), accumulated))
        }
        return result
    }

    /// True when `path` is `base` itself or sits underneath it.
    static func isDescendant(_ path: String, of base: String) -> Bool {
        let normalized = normalize(path)
        let baseline = normalize(base)
        if baseline == root { return true }
        if normalized == baseline { return true }
        // The separator matters: "/datalake2" must not count as being inside
        // "/datalake".
        return normalized.hasPrefix(baseline + "/")
    }

    /// Turns what someone typed into an absolute path: `~` and `~/…` against
    /// the home directory, anything not starting with `/` against `current`.
    ///
    /// `.` and `..` are left in place for the server's realpath to resolve —
    /// collapsing them here would be wrong across symlinks. `nil` for blank
    /// input.
    static func resolve(_ input: String, from current: String, home: String?) -> String? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }

        if typed == "~" { return normalize(home ?? root) }
        if typed.hasPrefix("~/") {
            return join(home ?? root, String(typed.dropFirst(2)))
        }
        if typed.hasPrefix("/") { return normalize(typed) }
        return join(current, typed)
    }

    /// Splits typed text into the folder to list and the partial name being
    /// typed, for completion: `/var/lo` → (`/var`, `lo`), `/var/` → (`/var`, ``).
    static func completionParts(of input: String, from current: String, home: String?) -> (folder: String, prefix: String)? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty || typed == "~" { return nil }

        if typed.hasSuffix("/") {
            guard let folder = resolve(typed, from: current, home: home) else { return nil }
            return (folder, "")
        }
        guard let slash = typed.lastIndex(of: "/") else {
            return (normalize(current), typed)
        }
        let head = String(typed[...slash])
        let prefix = String(typed[typed.index(after: slash)...])
        guard let folder = resolve(head, from: current, home: home) else { return nil }
        return (folder, prefix)
    }
}
