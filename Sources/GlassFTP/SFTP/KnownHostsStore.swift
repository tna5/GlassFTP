import Crypto
import Foundation
import NIOSSH

/// Reads and appends entries in `~/.ssh/known_hosts`.
///
/// We deliberately share OpenSSH's file rather than keeping a private store:
/// a host you have already trusted in Terminal should not prompt again here,
/// and a host trusted here should not prompt again in Terminal.
struct KnownHostsStore: Sendable {
    enum Match {
        /// Host is unknown — first contact, prompt the user (TOFU).
        case unknown
        /// The presented key is one of the pinned keys for this host.
        case trusted
        /// The host is pinned with a *different* key of the same type.
        case mismatch(pinned: NIOSSHPublicKey)
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
    }

    // MARK: - Lookup

    func match(host: String, port: Int, key: NIOSSHPublicKey) -> Match {
        let pinned = pinnedKeys(host: host, port: port)
        guard !pinned.isEmpty else { return .unknown }
        if pinned.contains(key) { return .trusted }

        // Only report a mismatch against a key of the same algorithm. A server
        // offering ed25519 when we pinned RSA is a negotiation difference, not
        // an attack, and treating it as one would lock the user out for no
        // reason.
        let presentedType = algorithmIdentifier(of: key)
        if let sameType = pinned.first(where: { algorithmIdentifier(of: $0) == presentedType }) {
            return .mismatch(pinned: sameType)
        }
        return .unknown
    }

    func pinnedKeys(host: String, port: Int) -> [NIOSSHPublicKey] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let target = Self.hostPattern(host: host, port: port)

        var keys: [NIOSSHPublicKey] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Skip the optional marker (@cert-authority / @revoked). We do not
            // support certificate authorities, and a revoked key must never be
            // treated as pinned.
            if fields.first?.hasPrefix("@") == true {
                guard fields.first != "@revoked" else { continue }
                fields.removeFirst()
            }
            guard fields.count >= 3 else { continue }

            guard Self.hostList(fields[0], matches: target) else { continue }
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])") {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - Appending

    func append(host: String, port: Int, key: NIOSSHPublicKey) throws {
        let line = "\(Self.hostPattern(host: host, port: port)) \(String(openSSHPublicKey: key))\n"

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        // Opened for updating, not writing: we need to read the last byte back
        // to see whether the file ends in a newline, and a write-only handle
        // fails that read with EBADF.
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()

        // Don't glue our entry onto a file that lacks a trailing newline.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            if last != Data("\n".utf8) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Removing

    /// Drops every pinned key for a host, as `ssh-keygen -R` does — the way
    /// out after a server was legitimately reinstalled. Wildcard lines are left
    /// alone (they were written by hand for many hosts), and so are `@revoked`
    /// lines, which only ever make the file stricter.
    ///
    /// Returns how many lines were removed.
    @discardableResult
    func removeEntries(host: String, port: Int) throws -> Int {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        let target = Self.hostPattern(host: host, port: port)

        var kept: [Substring] = []
        var removed = 0
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, !first.hasPrefix("#"), !first.hasPrefix("@") else {
                kept.append(rawLine)
                continue
            }
            let hostField = String(first)
            let isLiteral = hostField
                .split(separator: ",")
                .contains { $0 == Substring(target) }
            if isLiteral || (hostField.hasPrefix("|1|") && Self.hashedHost(hostField, matches: target)) {
                removed += 1
            } else {
                kept.append(rawLine)
            }
        }

        guard removed > 0 else { return 0 }
        try kept.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return removed
    }

    // MARK: - Host patterns

    /// OpenSSH writes non-default ports as `[host]:port`.
    static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Matches one known_hosts host field (which may hold several
    /// comma-separated patterns) against the host we are connecting to.
    private static func hostList(_ field: String, matches target: String) -> Bool {
        if field.hasPrefix("|1|") {
            return hashedHost(field, matches: target)
        }
        for pattern in field.split(separator: ",", omittingEmptySubsequences: true) {
            // Negations take precedence: `!host` excludes the whole line.
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: target) { return false }
                continue
            }
            if glob(String(pattern), matches: target) { return true }
        }
        return false
    }

    /// `|1|<base64 salt>|<base64 HMAC-SHA1>` — OpenSSH's HashKnownHosts format.
    private static func hashedHost(_ field: String, matches target: String) -> Bool {
        let parts = field.split(separator: "|", omittingEmptySubsequences: false)
        // Leading empty component from the "|1|" prefix, then salt, then hash.
        guard parts.count == 4,
              let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3]))
        else { return false }

        let mac = Crypto.HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(target.utf8),
            using: SymmetricKey(data: salt)
        )
        return Data(mac) == expected
    }

    /// known_hosts supports `*` and `?` wildcards in host patterns.
    private static func glob(_ pattern: String, matches target: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return pattern == target }

        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return target.range(of: regex, options: .regularExpression) != nil
    }

    private func algorithmIdentifier(of key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
            .split(separator: " ", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
    }
}

extension NIOSSHPublicKey {
    /// OpenSSH-style fingerprint, e.g. `SHA256:6Xr…kYs`.
    var sha256Fingerprint: String {
        let openSSH = String(openSSHPublicKey: self)
        let fields = openSSH.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            return "SHA256:<unavailable>"
        }
        // OpenSSH prints the digest base64-encoded with the padding stripped.
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The algorithm name as OpenSSH writes it, e.g. `ssh-ed25519`.
    var algorithmName: String {
        String(openSSHPublicKey: self)
            .split(separator: " ", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "unknown"
    }
}
