import Crypto
import Foundation
import NIOSSH

/// Assertions for the pure logic, run with `GlassFTP --self-test`.
///
/// Command Line Tools do not ship XCTest, so `swift test` is not available on
/// this machine. Rather than leave the known_hosts parser — which is the
/// security boundary of the whole app — untested, the checks live in the binary
/// behind a launch argument.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    @MainActor
    static func run() -> Int32 {
        pathTests()
        knownHostsTests()
        namingTests()
        permissionTests()
        shortcutTests()
        keyboardTests()
        sortKeyTests()
        chunkingTests()
        resumeTests()
        listingCacheTests()
        settingsTests()
        connectionMigrationTests()
        pathResolutionTests()
        conflictTests()
        proxyTests()
        privateKeyTests()
        knownHostsRemovalTests()
        scaleBenchmark()

        print("")
        if failures == 0 {
            print("\(checks) checks passed")
            return 0
        }
        print("\(failures) of \(checks) checks FAILED")
        return 1
    }

    // MARK: - Harness

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("  ok    \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label)")
        }
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual == expected {
            print("  ok    \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label) — got \(actual), expected \(expected)")
        }
    }

    private static func section(_ name: String) {
        print("\n\(name)")
    }

    // MARK: - Fixtures
    //
    // Throwaway keys generated with ssh-keygen purely to exercise the parser.

    private static let ed25519A = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDNR/UNOLNGCWXXlmIXeE2YS/vaiSOKNL6SbeySc5ne8"
    private static let ed25519B = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnzaOFEq5UaGDWigUx2/G6HmF2o3FQUYefZ9kDC+rXI"
    private static let ecdsaC = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHouCJXYkH6s8eL4SHqSBNeTJpGs57zw5L2LYsEsNC9YOvfzkgjupG7BI/j7Ekm/hUCzfDVEpefvBOeFuVmGpxk="
    /// NIOSSH has no RSA host-key support, so this line must be skipped
    /// rather than crashing the parser.
    private static let unsupportedRSA = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCpraVZ1F3QCVtfs8CE2sVOxGgPTaWF7zd/EtMHC8jLI6GkiVwTvqepDN+fUst3G9WUlVX7N9yPqnvAZgmfYIQ1JdRi+1bck0L841mCwLnCK93ookYBknE0Hbw4MCvzUS/4a3g7ti7VwccKiK6qZeLPhHv87g4JVIWd4C/ZdiibGaeXRgK+aZLNlaLJEIa1beI0+WUyV/1Q+4BQeN1jovZ9vloEKcdQQXZOvn9w511XtggpOkbDqaLkmAUMv+r2qFRW3WXdlckR475sRsLq9KDjbN6fP/pJiM3Rkr9qWGV8aZJM+dW6y0miWRvjtVGgwW3LtCqUk4ffnt8gcl8xaoZx"

    private static func key(_ openSSH: String) -> NIOSSHPublicKey {
        try! NIOSSHPublicKey(openSSHPublicKey: openSSH)
    }

    private static func store(_ contents: String) -> KnownHostsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-selftest-\(UUID().uuidString)")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return KnownHostsStore(fileURL: url)
    }

    private static func isTrusted(_ match: KnownHostsStore.Match) -> Bool {
        if case .trusted = match { return true }
        return false
    }

    private static func isMismatch(_ match: KnownHostsStore.Match) -> Bool {
        if case .mismatch = match { return true }
        return false
    }

    private static func isUnknown(_ match: KnownHostsStore.Match) -> Bool {
        if case .unknown = match { return true }
        return false
    }

    // MARK: - Path

    private static func pathTests() {
        section("RemotePath")
        expect(RemotePath.normalize("/var//www/"), "/var/www", "collapses and trims slashes")
        expect(RemotePath.normalize(""), "/", "empty path is root")
        expect(RemotePath.normalize("/"), "/", "root stays root")
        expect(RemotePath.join("/var/www", "index.html"), "/var/www/index.html", "join")
        expect(RemotePath.join("/", "etc"), "/etc", "join at root")
        expect(RemotePath.join("/var", "/absolute"), "/absolute", "absolute component wins")
        expect(RemotePath.parent(of: "/var/www/index.html"), "/var/www", "parent")
        expect(RemotePath.parent(of: "/var"), "/", "parent of top level is root")
        expect(RemotePath.parent(of: "/"), "/", "root is its own parent")
        expect(RemotePath.lastComponent(of: "/var/www"), "www", "last component")
        expect(RemotePath.lastComponent(of: "/"), "/", "last component of root")

        let crumbs = RemotePath.breadcrumbs(for: "/var/www")
        expect(crumbs.count, 3, "breadcrumb count")
        expect(crumbs.last?.path ?? "", "/var/www", "breadcrumb leaf path")
        expect(crumbs[1].path, "/var", "breadcrumb intermediate path")

        section("RemotePath — rooted breadcrumbs")
        // A connection scoped to /datalake must not show the tree above it.
        let rooted = RemotePath.breadcrumbs(for: "/datalake/raw/2026", relativeTo: "/datalake")
        expect(rooted.count, 3, "rooted breadcrumb count")
        expect(rooted.first?.name ?? "", "datalake", "root crumb is the scoped folder")
        expect(rooted.first?.path ?? "", "/datalake", "root crumb path")
        expect(rooted.last?.path ?? "", "/datalake/raw/2026", "rooted leaf path")

        let atRoot = RemotePath.breadcrumbs(for: "/datalake", relativeTo: "/datalake")
        expect(atRoot.count, 1, "sitting at the root gives a single crumb")

        // Falling outside the root must show the honest full path, not a
        // trail that pretends the folder lives under it.
        let outside = RemotePath.breadcrumbs(for: "/etc/nginx", relativeTo: "/datalake")
        expect(outside.first?.path ?? "", "/", "a path outside the root falls back to full crumbs")
        expect(outside.count, 3, "full crumbs for an outside path")

        expect(RemotePath.breadcrumbs(for: "/var/www", relativeTo: "/").count, 3, "a root of / behaves as before")

        section("RemotePath.isDescendant")
        expect(RemotePath.isDescendant("/datalake/raw", of: "/datalake"), "child is a descendant")
        expect(RemotePath.isDescendant("/datalake", of: "/datalake"), "a folder is its own descendant")
        expect(!RemotePath.isDescendant("/datalake2", of: "/datalake"), "a name-prefix sibling is not a descendant")
        expect(!RemotePath.isDescendant("/var", of: "/datalake"), "unrelated path is not a descendant")
        expect(RemotePath.isDescendant("/anything", of: "/"), "everything descends from root")
    }

    // MARK: - known_hosts

    private static func knownHostsTests() {
        section("KnownHostsStore — plain entries")
        let plain = store("""
        example.com \(ed25519A)
        other.net \(ed25519B)
        """)
        expect(isTrusted(plain.match(host: "example.com", port: 22, key: key(ed25519A))), "pinned key is trusted")
        expect(isMismatch(plain.match(host: "example.com", port: 22, key: key(ed25519B))), "different key of same type is a mismatch")
        expect(isUnknown(plain.match(host: "unlisted.org", port: 22, key: key(ed25519A))), "unlisted host is unknown")

        section("KnownHostsStore — algorithm handling")
        // An RSA key offered where only ed25519 is pinned is a negotiation
        // difference, not an attack; treating it as a mismatch would lock the
        // user out for no reason.
        expect(isUnknown(plain.match(host: "example.com", port: 22, key: key(ecdsaC))), "different algorithm is unknown, not a mismatch")

        // NIOSSH cannot represent an RSA host key at all, so such a line must be
        // skipped quietly instead of taking the whole file down with it.
        let withRSA = store("""
        rsa.example.com \(unsupportedRSA)
        rsa.example.com \(ed25519A)
        """)
        expect(isTrusted(withRSA.match(host: "rsa.example.com", port: 22, key: key(ed25519A))), "unparseable line does not break the rest of the file")

        section("KnownHostsStore — ports")
        let ported = store("[example.com]:2222 \(ed25519A)")
        expect(isTrusted(ported.match(host: "example.com", port: 2222, key: key(ed25519A))), "bracketed non-default port matches")
        expect(isUnknown(ported.match(host: "example.com", port: 22, key: key(ed25519A))), "port 22 does not match a 2222 entry")
        expect(KnownHostsStore.hostPattern(host: "h", port: 22), "h", "default port is unbracketed")
        expect(KnownHostsStore.hostPattern(host: "h", port: 2222), "[h]:2222", "non-default port is bracketed")

        section("KnownHostsStore — comma lists and wildcards")
        let multi = store("alpha.example.com,10.0.0.5,*.wild.net \(ed25519A)")
        expect(isTrusted(multi.match(host: "alpha.example.com", port: 22, key: key(ed25519A))), "first pattern in list")
        expect(isTrusted(multi.match(host: "10.0.0.5", port: 22, key: key(ed25519A))), "ip in list")
        expect(isTrusted(multi.match(host: "any.wild.net", port: 22, key: key(ed25519A))), "wildcard pattern")
        expect(isUnknown(multi.match(host: "any.wild.net.evil.com", port: 22, key: key(ed25519A))), "wildcard is anchored")

        section("KnownHostsStore — markers and comments")
        let marked = store("""
        # a comment line
        @revoked revoked.example.com \(ed25519A)
        @cert-authority ca.example.com \(ed25519B)
        """)
        expect(isUnknown(marked.match(host: "revoked.example.com", port: 22, key: key(ed25519A))), "revoked key is never trusted")
        expect(isTrusted(marked.match(host: "ca.example.com", port: 22, key: key(ed25519B))), "marker is skipped before the host field")

        section("KnownHostsStore — hashed entries")
        // OpenSSH's HashKnownHosts format: |1|<b64 salt>|<b64 HMAC-SHA1>.
        let salt = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let hostname = "hashed.example.com"
        let mac = Crypto.HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(hostname.utf8),
            using: SymmetricKey(data: salt)
        )
        let hashedField = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        let hashed = store("\(hashedField) \(ed25519A)")
        expect(isTrusted(hashed.match(host: hostname, port: 22, key: key(ed25519A))), "hashed host matches")
        expect(isUnknown(hashed.match(host: "other.example.com", port: 22, key: key(ed25519A))), "hashed host does not match another host")

        section("KnownHostsStore — appending")
        let appendURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-append-\(UUID().uuidString)")
        // No trailing newline: a naive append would glue onto this line.
        try! "first.example.com \(ed25519B)".write(to: appendURL, atomically: true, encoding: .utf8)
        let appendable = KnownHostsStore(fileURL: appendURL)
        try! appendable.append(host: "second.example.com", port: 2222, key: key(ed25519A))
        expect(isTrusted(appendable.match(host: "second.example.com", port: 2222, key: key(ed25519A))), "appended entry reads back")
        expect(isTrusted(appendable.match(host: "first.example.com", port: 22, key: key(ed25519B))), "pre-existing entry survives the append")

        section("Fingerprints")
        expect(
            key(ed25519A).sha256Fingerprint,
            "SHA256:jCcAS7ciEKPa+CAv9GUWOJS9Qo1hcJax0q8Wjj5DvPs",
            "fingerprint matches ssh-keygen -lf"
        )
        expect(key(ed25519A).algorithmName, "ssh-ed25519", "algorithm name")
        expect(key(ecdsaC).algorithmName, "ecdsa-sha2-nistp256", "ecdsa algorithm name")
    }

    // MARK: - Naming

    private static func namingTests() {
        section("TransferPlanner.uniqueURL")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-unique-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory.appendingPathComponent("report.pdf")
        expect(TransferPlanner.uniqueURL(for: target).lastComponent, "report.pdf", "free name is returned unchanged")

        FileManager.default.createFile(atPath: target.path, contents: Data())
        expect(TransferPlanner.uniqueURL(for: target).lastComponent, "report 2.pdf", "taken name is disambiguated")

        let extensionless = directory.appendingPathComponent("archive")
        FileManager.default.createFile(atPath: extensionless.path, contents: Data())
        expect(TransferPlanner.uniqueURL(for: extensionless).lastComponent, "archive 2", "disambiguation without an extension")
    }

    // MARK: - Sort keys

    @MainActor
    private static func sortKeyTests() {
        section("RemoteEntry natural sort key")

        func order(_ names: [String]) -> [String] {
            names.sorted { RemoteEntry.naturalSortKey(for: $0) < RemoteEntry.naturalSortKey(for: $1) }
        }

        expect(
            order(["file10", "file2", "file1"]),
            ["file1", "file2", "file10"],
            "numbers order numerically, not lexically"
        )
        expect(
            order(["IMG_100.jpg", "IMG_9.jpg", "IMG_20.jpg"]),
            ["IMG_9.jpg", "IMG_20.jpg", "IMG_100.jpg"],
            "digit runs inside a name order numerically"
        )
        expect(
            order(["Beta", "alpha", "Gamma"]),
            ["alpha", "Beta", "Gamma"],
            "ordering is case-insensitive"
        )
        // Zero padding in the name must not change the numeric value.
        expect(
            RemoteEntry.naturalSortKey(for: "v007"),
            RemoteEntry.naturalSortKey(for: "v7"),
            "leading zeros carry no weight"
        )
        expect(
            order(["2026-01-10.log", "2026-01-02.log", "2025-12-31.log"]),
            ["2025-12-31.log", "2026-01-02.log", "2026-01-10.log"],
            "multiple digit runs each order numerically"
        )
        // A name with no digits should not be rewritten at all.
        expect(RemoteEntry.naturalSortKey(for: "README"), "readme", "digit-free names are just lowercased")

        section("RemoteEntry precomputed fields")
        let entry = entry("Report 2.PDF", kind: .file)
        expect(entry.searchKey, "report 2.pdf", "search key is the lowercased name")
        expect(entry.kindLabel.isEmpty == false, "kind label resolves")
        expect(self.entry("x", kind: .directory).kindLabel, "Folder", "directories label as Folder")
        expect(self.entry("x", kind: .symlink).kindLabel, "Alias", "symlinks label as Alias")
    }

    // MARK: - Chunked transfers

    @MainActor
    private static func chunkingTests() {
        section("ChunkCursor")

        // Every byte exactly once: a gap here is a corrupt file of the right
        // size, which is the worst kind of bug this code can produce.
        let total: Int64 = 100_000
        let chunk = 32_768
        let cursor = ChunkCursor(total: total, chunkSize: chunk)

        var ranges: [(offset: Int64, length: Int)] = []
        while let claimed = cursor.claim() { ranges.append(claimed) }

        expect(ranges.count, 4, "100,000 bytes in 32 KB chunks is four claims")
        expect(ranges.first?.offset ?? -1, 0, "first chunk starts at zero")
        expect(ranges.last?.length ?? 0, Int(total) - chunk * 3, "last chunk is the remainder")

        var covered: Int64 = 0
        var contiguous = true
        for range in ranges {
            if range.offset != covered { contiguous = false }
            covered += Int64(range.length)
        }
        expect(contiguous, "chunks are contiguous, with no gaps or overlaps")
        expect(covered, total, "chunks cover the file exactly")
        expect(cursor.claim() == nil, "an exhausted cursor hands out nothing more")

        // A file smaller than one chunk must still produce one claim.
        let small = ChunkCursor(total: 10, chunkSize: chunk)
        expect(small.claim()?.length ?? 0, 10, "a short file is a single partial chunk")
        expect(small.claim() == nil, "and nothing after it")

        expect(ChunkCursor(total: 0, chunkSize: chunk).claim() == nil, "an empty file claims nothing")

        section("ChunkCursor under concurrency")
        // The pipeline claims from sixteen tasks at once; handing the same
        // range to two of them would double-count progress and waste transfer.
        let shared = ChunkCursor(total: 4_000_000, chunkSize: 1_000)
        let collector = NSLock()
        var seen: [Int64] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            var local: [Int64] = []
            while let claimed = shared.claim() { local.append(claimed.offset) }
            collector.lock()
            seen.append(contentsOf: local)
            collector.unlock()
        }
        expect(seen.count, 4_000, "every chunk was claimed")
        expect(Set(seen).count, 4_000, "no chunk was claimed twice")

        section("ChunkedFile positional access")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-chunk-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = (0..<3_000).map { UInt8($0 % 251) }
        do {
            let file = try ChunkedFile.create(at: url, size: Int64(payload.count))
            expect(try file.size() == Int64(payload.count), "the file is pre-allocated to its final size")

            // Written back to front, the way out-of-order pipeline workers land.
            try file.write(Data(payload[2_000...]), at: 2_000)
            try file.write(Data(payload[0..<1_000]), at: 0)
            try file.write(Data(payload[1_000..<2_000]), at: 1_000)
            file.close()

            let readBack = try Data(contentsOf: url)
            expect(readBack.count, payload.count, "size is unchanged after out-of-order writes")
            expect(Array(readBack) == payload, "out-of-order writes reassemble in the right order")

            let reader = try ChunkedFile.openForReading(at: url)
            defer { reader.close() }
            expect(try reader.read(count: 100, at: 500) == Data(payload[500..<600]), "positional read")
            // Asking past the end must return what exists, not fail.
            expect(try reader.read(count: 500, at: 2_900).count == 100, "a read past the end returns only what is there")
            expect(try reader.read(count: 10, at: 3_000).isEmpty, "a read at the end returns nothing")
        } catch {
            expect(false, "chunked file round trip threw: \(error)")
        }
    }

    // MARK: - Resume

    private static func resumeTests() {
        section("ChunkCursor — resuming")
        let cursor = ChunkCursor(total: 100_000, chunkSize: 32_768, start: 40_000)
        expect(cursor.claim()?.offset ?? -1, 40_000, "a resumed cursor starts at the resume offset")
        expect(cursor.advance(by: 1_000), 41_000, "progress counts the bytes already on disk")

        var covered: Int64 = 40_000
        var contiguous = true
        let rest = ChunkCursor(total: 100_000, chunkSize: 32_768, start: 40_000)
        while let claimed = rest.claim() {
            if claimed.offset != covered { contiguous = false }
            covered += Int64(claimed.length)
        }
        expect(contiguous && covered == 100_000, "the rest of the file is covered exactly once")
        expect(ChunkCursor(total: 10, chunkSize: 4, start: 50).claim() == nil, "a start past the end claims nothing")
        expect(ChunkCursor(total: 10, chunkSize: 0).claim()?.length ?? 0, 1, "a zero chunk size cannot spin forever")

        section("ChunkedFile — resuming")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-resume-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(repeating: 7, count: 5_000).write(to: url)
            let file = try ChunkedFile.openForResume(at: url, truncatingTo: 3_000)
            expect(try file.size() == 3_000, "resuming cuts the unsafe tail")
            try file.write(Data(repeating: 9, count: 2_000), at: 3_000)
            file.close()
            let data = try Data(contentsOf: url)
            expect(data.count == 5_000 && data[2_999] == 7 && data[3_000] == 9, "the kept head is untouched and the rest appended")
        } catch {
            expect(false, "resume round trip threw: \(error)")
        }
    }

    // MARK: - Settings

    private static func settingsTests() {
        section("AppSettings decoding")
        let decoder = JSONDecoder()

        let empty = try? decoder.decode(AppSettings.self, from: Data("{}".utf8))
        expect(empty == AppSettings(), "an empty blob decodes to the defaults")

        let partial = try? decoder.decode(
            AppSettings.self,
            from: Data(#"{"transfers":{"maxConcurrent":7},"general":{"showHiddenFiles":false}}"#.utf8)
        )
        expect(partial?.transfers.maxConcurrent ?? 0, 7, "a stored value survives")
        expect(partial?.transfers.retries ?? -1, AppSettings().transfers.retries, "a missing sibling falls back to its default")
        expect(partial?.general.showHiddenFiles == false, "nested groups decode")

        let wrongType = try? decoder.decode(AppSettings.self, from: Data(#"{"transfers":{"maxConcurrent":"lots","retries":4}}"#.utf8))
        expect(wrongType?.transfers.maxConcurrent ?? 0, AppSettings().transfers.maxConcurrent, "an unreadable value falls back instead of failing")
        expect(wrongType?.transfers.retries ?? 0, 4, "and does not take its neighbours with it")

        var odd = AppSettings.Transfers()
        odd.maxConcurrent = 99
        expect(odd.clampedConcurrency, 10, "concurrency is clamped to the allowed range")

        var tuning = AppSettings.Advanced()
        tuning.chunkSize = 0
        tuning.pipelineDepth = 1_000
        expect(tuning.tuning.chunkSize, 32_768, "an unknown chunk size falls back to 32 KB")
        expect(tuning.tuning.pipelineDepth, 64, "pipeline depth is clamped")

        let roundTrip = try? decoder.decode(AppSettings.self, from: JSONEncoder().encode(partial ?? AppSettings()))
        expect(roundTrip == partial, "settings round-trip through JSON")
    }

    private static func connectionMigrationTests() {
        section("Connection decoding")
        let id = UUID()
        let old = """
        [{"id":"\(id.uuidString)","name":"prod","kind":"sftp","host":"example.com","port":2222,"username":"deploy","initialPath":"/srv"}]
        """
        let decoded = try? JSONDecoder().decode([Connection].self, from: Data(old.utf8))
        expect(decoded?.count ?? 0, 1, "a connections.json from before auth and proxy fields still loads")
        expect(decoded?.first?.port ?? 0, 2222, "existing fields are kept")
        expect(decoded?.first?.authMethod == .password, "old connections authenticate with a password")
        expect(decoded?.first?.proxy == .useDefault, "old connections use the default proxy")

        var connection = Connection(host: "h", username: "u")
        connection.authMethod = .privateKey
        expect(!connection.isComplete, "key authentication needs a key file")
        connection.privateKeyPath = "~/.ssh/id_ed25519"
        connection.proxy = .custom(ProxySettings(kind: .httpConnect, host: "p", port: 3128, username: "me"))
        expect(connection.isComplete, "with a key file it is complete")

        let again = try? JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
        expect(again == connection, "new fields round-trip, custom proxy included")
    }

    // MARK: - Path resolution

    private static func pathResolutionTests() {
        section("RemotePath.resolve")
        expect(RemotePath.resolve("~", from: "/var", home: "/home/me") ?? "", "/home/me", "~ is home")
        expect(RemotePath.resolve("~/www/", from: "/var", home: "/home/me") ?? "", "/home/me/www", "~/x is under home")
        expect(RemotePath.resolve("logs", from: "/var", home: nil) ?? "", "/var/logs", "a bare name is relative to the current folder")
        expect(RemotePath.resolve("../etc", from: "/var", home: nil) ?? "", "/var/../etc", ".. is left for the server's realpath")
        expect(RemotePath.resolve("  /srv//data/ ", from: "/var", home: nil) ?? "", "/srv/data", "absolute paths are trimmed and normalised")
        expect(RemotePath.resolve("   ", from: "/var", home: nil) == nil, "blank input resolves to nothing")
        expect(RemotePath.resolve("~", from: "/var", home: nil) ?? "", "/", "~ without a known home is the root")

        section("Path completion")
        let parts = RemotePath.completionParts(of: "/var/lo", from: "/", home: nil)
        expect(parts?.folder ?? "", "/var", "the folder to list is everything before the last slash")
        expect(parts?.prefix ?? "", "lo", "the prefix is what follows it")
        expect(RemotePath.completionParts(of: "/var/", from: "/", home: nil)?.prefix ?? "x", "", "a trailing slash lists the folder itself")
        expect(RemotePath.completionParts(of: "ww", from: "/home/me", home: nil)?.folder ?? "", "/home/me", "a bare prefix completes in the current folder")
        expect(RemotePath.completionParts(of: "~/w", from: "/", home: "/home/me")?.folder ?? "", "/home/me", "~/ completes in home")
        expect(PathCompleter.replacingLastComponent(of: "~/w", with: "www"), "~/www/", "completion keeps the typed form")
        expect(PathCompleter.replacingLastComponent(of: "ww", with: "www"), "www/", "and works without a slash")
    }

    // MARK: - Conflicts

    private static func conflictTests() {
        section("TransferPlanner.resolve")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let source = TransferPlanner.FileFacts(size: 10_000_000, modifiedAt: new)
        let smaller = TransferPlanner.FileFacts(size: 6_000_000, modifiedAt: old)
        let same = TransferPlanner.FileFacts(size: 10_000_000, modifiedAt: new.addingTimeInterval(0.5))

        expect(TransferPlanner.resolve(.overwrite, source: source, destination: same), .transfer(resumeFrom: 0), "overwrite always sends")
        expect(TransferPlanner.resolve(.skip, source: source, destination: smaller), .skip, "skip always skips")
        expect(TransferPlanner.resolve(.rename, source: source, destination: same), .rename, "rename keeps both")
        expect(TransferPlanner.resolve(.overwriteIfNewer, source: source, destination: smaller), .transfer(resumeFrom: 0), "a newer source replaces")
        expect(TransferPlanner.resolve(.overwriteIfNewer, source: source, destination: same), .skip, "sub-second differences count as the same time")
        expect(TransferPlanner.resolve(.overwriteIfNewer, source: smaller, destination: source), .skip, "an older source is skipped")
        expect(
            TransferPlanner.resolve(.overwriteIfNewer, source: .init(size: 1, modifiedAt: nil), destination: smaller),
            .transfer(resumeFrom: 0),
            "an unknown date errs on the side of sending"
        )
        expect(TransferPlanner.resolve(.overwriteIfSizeDiffers, source: source, destination: same), .skip, "equal sizes are skipped")
        expect(TransferPlanner.resolve(.overwriteIfSizeDiffers, source: source, destination: smaller), .transfer(resumeFrom: 0), "different sizes are sent")
        expect(
            TransferPlanner.resolve(.resume, source: source, destination: smaller),
            .transfer(resumeFrom: 6_000_000 - TransferPlanner.resumeSafetyMargin),
            "resume backs off by the safety margin"
        )
        expect(TransferPlanner.resolve(.resume, source: source, destination: same), .skip, "a complete file is not resumed")
        expect(
            TransferPlanner.resolve(.resume, source: smaller, destination: source),
            .transfer(resumeFrom: 0),
            "a destination larger than the source is replaced, not resumed"
        )
        expect(TransferPlanner.resumeOffset(forExisting: 1_000), 0, "a tiny partial file restarts from zero")

        section("TransferPlanner.uniqueName")
        expect(TransferPlanner.uniqueName(for: "a.txt", taken: []), "a.txt", "a free name is kept")
        expect(TransferPlanner.uniqueName(for: "a.txt", taken: ["a.txt", "a 2.txt"]), "a 3.txt", "numbering skips taken names")
        expect(TransferPlanner.uniqueName(for: "Makefile", taken: ["Makefile"]), "Makefile 2", "names without an extension")
    }

    // MARK: - Proxy

    private static func proxyTests() {
        section("SOCKS5 wire format")
        expect(ProxyHandshake.socksGreeting(withCredentials: false), [5, 1, 0], "greeting offers no-auth")
        expect(ProxyHandshake.socksGreeting(withCredentials: true), [5, 2, 0, 2], "with credentials it also offers user/pass")
        expect(ProxyHandshake.socksCredentials(username: "ab", password: "c"), [1, 2, 97, 98, 1, 99], "RFC 1929 credentials")
        expect(
            ProxyHandshake.socksConnect(host: "h.io", port: 2222),
            [5, 1, 0, 3, 4, 104, 46, 105, 111, 0x08, 0xAE],
            "CONNECT by domain name, port big-endian"
        )

        expect(ProxyHandshake.parseSocksMethod([5]).0, .needMore, "a half-received method reply waits")
        expect(ProxyHandshake.parseSocksMethod([5, 0]).1, .noAuth, "method 0 is no-auth")
        expect(ProxyHandshake.parseSocksMethod([5, 2]).1, .credentials, "method 2 is user/pass")
        expect(isFailure(ProxyHandshake.parseSocksMethod([5, 0xFF]).0), "0xFF means no acceptable method")
        expect(isFailure(ProxyHandshake.parseSocksMethod([4, 0]).0), "a non-SOCKS5 reply fails")
        expect(isFailure(ProxyHandshake.parseSocksCredentialsReply([1, 1])), "rejected credentials fail")
        expect(ProxyHandshake.parseSocksCredentialsReply([1, 0]), .done(consumed: 2), "accepted credentials")

        let ipv4Reply: [UInt8] = [5, 0, 0, 1, 10, 0, 0, 1, 0, 22]
        expect(ProxyHandshake.parseSocksConnectReply(ipv4Reply), .done(consumed: 10), "IPv4 bound address")
        expect(ProxyHandshake.parseSocksConnectReply(Array(ipv4Reply.prefix(7))), .needMore, "a truncated reply waits")
        expect(
            ProxyHandshake.parseSocksConnectReply(ipv4Reply + Array("SSH-2.0".utf8)),
            .done(consumed: 10),
            "bytes after the reply are left for SSH"
        )
        expect(ProxyHandshake.parseSocksConnectReply([5, 0, 0, 3, 2, 97, 98, 0, 22]), .done(consumed: 9), "domain bound address")
        expect(ProxyHandshake.parseSocksConnectReply([5, 0, 0, 4] + Array(repeating: 0, count: 18)), .done(consumed: 22), "IPv6 bound address")
        expect(ProxyHandshake.parseSocksConnectReply([5, 5, 0, 1, 0]), .failed(ProxyHandshake.socksReason(5)), "a refusal reports its reason")

        section("HTTP CONNECT wire format")
        let request = String(decoding: ProxyHandshake.httpConnectRequest(host: "h.io", port: 22, username: "u", password: "p"), as: UTF8.self)
        expect(request.hasPrefix("CONNECT h.io:22 HTTP/1.1\r\n"), "request line")
        expect(request.contains("Proxy-Authorization: Basic dTpw\r\n"), "basic credentials")
        expect(request.hasSuffix("\r\n\r\n"), "request is terminated")
        expect(
            String(decoding: ProxyHandshake.httpConnectRequest(host: "::1", port: 22, username: "", password: ""), as: UTF8.self)
                .hasPrefix("CONNECT [::1]:22 "),
            "IPv6 literals are bracketed"
        )

        let ok = Array("HTTP/1.1 200 Connection established\r\nVia: x\r\n\r\n".utf8)
        expect(ProxyHandshake.parseHTTPConnectReply(ok), .done(consumed: ok.count), "200 opens the tunnel")
        expect(ProxyHandshake.parseHTTPConnectReply(Array(ok.dropLast(2))), .needMore, "an unfinished head waits")
        expect(ProxyHandshake.parseHTTPConnectReply(ok + Array("SSH-2.0".utf8)), .done(consumed: ok.count), "the SSH banner is not consumed")
        expect(isFailure(ProxyHandshake.parseHTTPConnectReply(Array("HTTP/1.1 407 Auth\r\n\r\n".utf8))), "407 fails")
        expect(isFailure(ProxyHandshake.parseHTTPConnectReply(Array("HTTP/1.0 403 Forbidden\r\n\r\n".utf8))), "403 fails")
        expect(isFailure(ProxyHandshake.parseHTTPConnectReply(Array("garbage\r\n\r\n".utf8))), "a non-HTTP reply fails")

        section("Proxy resolution")
        let global = ProxySettings(kind: .socks5, host: "g", port: 1080, username: "gu")
        let custom = ProxySettings(kind: .httpConnect, host: "c", port: 3128)
        func resolve(_ global: ProxySettings, _ override: ProxyOverride, system: [String: Any]? = nil) -> ProxyEndpoint? {
            ProxyResolver.resolve(
                global: global,
                override: override,
                targetHost: "srv.example.com",
                password: { $0 ? "gp" : "cp" },
                systemSettings: { system }
            )
        }
        expect(resolve(global, .useDefault), ProxyEndpoint(kind: .socks5, host: "g", port: 1080, username: "gu", password: "gp"), "the default proxy, with its Keychain password")
        expect(resolve(global, .direct) == nil, "a direct connection ignores the default")
        expect(resolve(global, .custom(custom))?.host ?? "", "c", "a custom proxy wins")
        expect(resolve(global, .custom(custom))?.password ?? "x", "", "no username means no password is sent")
        expect(resolve(ProxySettings(), .useDefault) == nil, "no default proxy")
        expect(resolve(ProxySettings(kind: .socks5, host: " "), .useDefault) == nil, "a proxy without a host is ignored")

        let system: [String: Any] = [
            "SOCKSEnable": 1, "SOCKSProxy": "s", "SOCKSPort": 9050,
            "HTTPSEnable": 1, "HTTPSProxy": "w", "HTTPSPort": 8443,
        ]
        expect(resolve(ProxySettings(kind: .system), .useDefault, system: system)?.port ?? 0, 9050, "system settings prefer SOCKS")
        let httpsOnly: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "w", "HTTPSPort": 8443]
        expect(resolve(ProxySettings(kind: .system), .useDefault, system: httpsOnly)?.kind == .httpConnect, "then HTTPS")
        let bypassed: [String: Any] = system.merging(["ExceptionsList": ["*.example.com"]]) { $1 }
        expect(resolve(ProxySettings(kind: .system), .useDefault, system: bypassed) == nil, "the system bypass list is honoured")
        expect(ProxyResolver.isExcepted("example.com", by: ["*.example.com"]), "a wildcard covers the bare domain too")
        expect(!ProxyResolver.isExcepted("notexample.com", by: ["*.example.com"]), "but not a lookalike")
    }

    private static func isFailure(_ step: ProxyHandshake.Step) -> Bool {
        if case .failed = step { return true }
        return false
    }

    // MARK: - Keys

    private static func privateKeyTests() {
        section("PrivateKeyLoader.detectType")
        func openSSH(_ algorithm: String) -> String {
            // The real layout starts with the magic and the public key's
            // algorithm name, which is all detection looks at.
            var payload = Data("openssh-key-v1\0".utf8)
            payload.append(Data([0, 0, 0, 4]))
            payload.append(Data("none".utf8))
            payload.append(Data(algorithm.utf8))
            return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(payload.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
        }
        expect(PrivateKeyLoader.detectType(openSSH("ssh-ed25519")), .ed25519, "OpenSSH ed25519")
        expect(PrivateKeyLoader.detectType(openSSH("ssh-rsa")), .rsa, "OpenSSH RSA")
        expect(PrivateKeyLoader.detectType(openSSH("ecdsa-sha2-nistp256")), .ecdsaOpenSSH, "OpenSSH ECDSA is recognised, to explain it")
        expect(PrivateKeyLoader.detectType("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----"), .ecdsaPEM, "PEM ECDSA")
        expect(PrivateKeyLoader.detectType("hello"), .unknown, "anything else")

        // A real key end to end, generated in-process so no fixture is needed.
        let key = P256.Signing.PrivateKey()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glassftp-key-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: url) }
        try? key.pemRepresentation.write(to: url, atomically: true, encoding: .utf8)
        expect((try? PrivateKeyLoader.authenticationMethod(username: "u", keyPath: url.path, passphrase: nil)) != nil, "a PEM P-256 key loads")
        expect((try? PrivateKeyLoader.authenticationMethod(username: "u", keyPath: "/nonexistent/key", passphrase: nil)) == nil, "a missing file fails cleanly")
    }

    private static func knownHostsRemovalTests() {
        section("KnownHostsStore — removing")
        let contents = """
        # comment
        example.com \(ed25519A)
        [example.com]:2222 \(ed25519B)
        other.org,example.com \(ecdsaC)
        *.example.com \(ed25519B)
        @revoked example.com \(ed25519B)
        """
        let known = store(contents)
        defer { try? FileManager.default.removeItem(at: known.fileURL) }

        expect((try? known.removeEntries(host: "example.com", port: 22)) ?? -1, 2, "both lines naming the host are removed")
        expect(known.pinnedKeys(host: "example.com", port: 22).isEmpty, "the host is no longer pinned")
        expect(known.pinnedKeys(host: "www.example.com", port: 22).count, 1, "the hand-written wildcard line is kept")
        expect(known.pinnedKeys(host: "example.com", port: 2222).count, 1, "another port is untouched")
        let after = (try? String(contentsOf: known.fileURL, encoding: .utf8)) ?? ""
        expect(after.contains("# comment") && after.contains("@revoked"), "comments and revocations are kept")
        expect((try? known.removeEntries(host: "nowhere", port: 22)) ?? -1, 0, "nothing to remove leaves the file alone")
    }

    // MARK: - Listing cache

    @MainActor
    private static func listingCacheTests() {
        section("ListingCache")

        func listing(_ prefix: String, count: Int) -> [RemoteEntry] {
            (0..<count).map { entry("\(prefix)\($0)", kind: .file) }
        }

        var cache = ListingCache(budget: 100)
        cache.store(listing("a", count: 40), for: "/a", pinning: nil)
        cache.store(listing("b", count: 40), for: "/b", pinning: nil)
        expect(cache.totalEntries, 80, "entries accumulate")
        expect(cache["/a"]?.count ?? 0, 40, "a stored listing reads back")

        // Going over budget drops the oldest folder, not the newest.
        cache.store(listing("c", count: 40), for: "/c", pinning: nil)
        expect(cache.totalEntries, 80, "the cache stays within budget")
        expect(cache["/a"] == nil, "the least recently stored folder is evicted")
        expect(cache["/c"] != nil, "the folder just stored survives")

        section("ListingCache — pinning")
        var pinned = ListingCache(budget: 100)
        pinned.store(listing("a", count: 40), for: "/a", pinning: "/a")
        pinned.store(listing("b", count: 40), for: "/b", pinning: "/a")
        pinned.store(listing("c", count: 40), for: "/c", pinning: "/a")
        // The folder on screen must survive; evicting it would force an
        // immediate refetch of the one listing certain to be needed.
        expect(pinned["/a"] != nil, "the pinned folder is never evicted")
        expect(pinned["/b"] == nil, "an unpinned folder is evicted instead")

        section("ListingCache — replacement and removal")
        var replaced = ListingCache(budget: 1_000)
        replaced.store(listing("a", count: 40), for: "/a", pinning: nil)
        replaced.store(listing("a", count: 10), for: "/a", pinning: nil)
        expect(replaced.totalEntries, 10, "re-storing a folder replaces rather than adds")
        expect(replaced.cachedPaths.count, 1, "and does not duplicate its cache slot")

        replaced.remove("/a")
        expect(replaced.totalEntries, 0, "removal reclaims the count")
        expect(replaced["/a"] == nil, "removal drops the listing")

        replaced.store(listing("a", count: 5), for: "/a", pinning: nil)
        replaced.removeAll()
        expect(replaced.totalEntries, 0, "removeAll clears the count")
        expect(replaced.cachedPaths.isEmpty, "removeAll clears the order")

        // A single folder larger than the whole budget must still be usable —
        // refusing to cache the folder on screen would be worse than the cost.
        var oversized = ListingCache(budget: 100)
        oversized.store(listing("big", count: 500), for: "/big", pinning: "/big")
        expect(oversized["/big"]?.count ?? 0, 500, "a folder bigger than the budget is still served")
        expect(oversized.isOverBudget, "and the cache reports itself over budget")
    }

    // MARK: - Scale

    /// Times a full rebuild on a folder the size the app is actually used on.
    ///
    /// This is the regression that matters: `visibleEntries` used to be a
    /// computed property re-sorting on every read, several times per render.
    @MainActor
    private static func scaleBenchmark() {
        section("Scale — 50,000 entries")

        let count = 50_000
        var big: [RemoteEntry] = []
        big.reserveCapacity(count)
        let extensions = ["jpg", "mp4", "txt", "json", "log", "bin", ""]
        for index in 0..<count {
            let ext = extensions[index % extensions.count]
            let name = ext.isEmpty ? "item\(index % 977)_\(index)" : "item\(index % 977)_\(index).\(ext)"
            big.append(
                RemoteEntry(
                    name: name,
                    path: "/data/\(name)",
                    kind: index % 50 == 0 ? .directory : .file,
                    size: Int64(index) * 1024,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    permissions: 0o644
                )
            )
        }

        let model = BrowserModel(
            connection: Connection(name: "t", host: "h", username: "u"),
            configuration: .init(host: "h", port: 22, username: "u", auth: .password("")),
            settings: AppSettings(),
            hostKeyConfirmation: { _ in false }
        )

        let clock = ContinuousClock()

        let assign = clock.measure { model.entries = big }
        report("build index + sort by name", assign)

        // Same comparator the Kind column installs — measuring with the default
        // `.localizedStandard` would be benchmarking something we do not ship.
        let byKind = clock.measure {
            model.sortOrder = [
                KeyPathComparator(
                    \RemoteEntry.kindLabel,
                    comparator: String.StandardComparator.lexical,
                    order: .forward
                )
            ]
        }
        report("re-sort by kind", byKind)

        let bySize = clock.measure {
            model.sortOrder = [KeyPathComparator(\RemoteEntry.size, order: .reverse)]
        }
        report("re-sort by size", bySize)

        let search = clock.measure {
            model.searchText = "item42_"
            model.flushPendingSearch()
        }
        report("filter", search)

        expect(model.visibleEntries.count < count, "the filter actually narrows the list")
        expect(model.entries.count, count, "entries are stored intact")

        // Reading the property must now be free — this is what used to cost a
        // full sort each time, several times per render pass.
        model.searchText = ""
        expect(model.visibleEntries.count, count, "every entry survives the round trip")
        let reads = clock.measure {
            for _ in 0..<50 { _ = model.visibleEntries.count }
        }
        report("50 reads of visibleEntries", reads)
        expect(
            reads < .milliseconds(20),
            "50 reads of visibleEntries stay cheap (\(format(reads)))"
        )

        // Threshold sized for the debug build `make test` uses; release is
        // several times faster again. Before index sorting this was ~1000 ms in
        // release and several seconds per frame, since the property re-sorted
        // on every read.
        let worst = max(assign, max(byKind, bySize))
        expect(
            worst < .milliseconds(250),
            "worst single rebuild stays well under a frame budget (\(format(worst)))"
        )
    }

    private static func report(_ label: String, _ duration: Duration) {
        print("  time  \(label): \(format(duration))")
    }

    private static func format(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1000
        return String(format: "%.1f ms", milliseconds)
    }

    // MARK: - Keyboard selection

    @MainActor
    private static func keyboardTests() {
        section("BrowserModel.moveSelection")

        let model = BrowserModel(
            connection: Connection(name: "t", host: "h", username: "u"),
            configuration: .init(host: "h", port: 22, username: "u", auth: .password("")),
            settings: AppSettings(),
            hostKeyConfirmation: { _ in false }
        )
        // Deliberately out of order: `visibleEntries` groups folders first and
        // then sorts, and the arrows must follow what is on screen.
        model.entries = [
            entry("readme.md", kind: .file),
            entry("src", kind: .directory),
            entry("assets", kind: .directory),
            entry("app.js", kind: .file),
        ]
        expect(
            model.visibleEntries.map(\.name),
            ["assets", "src", "app.js", "readme.md"],
            "visible order is folders first, then name"
        )

        expect(model.moveSelection(by: 1)?.name ?? "", "assets", "first press with nothing selected enters at the top")
        expect(model.moveSelection(by: 1)?.name ?? "", "src", "moves down one")
        expect(model.moveSelection(by: 2)?.name ?? "", "readme.md", "moves down by a row's worth")
        expect(model.moveSelection(by: 1) == nil, "does not run off the bottom")
        expect(model.focusedEntry?.name ?? "", "readme.md", "selection stays put at the bottom")
        expect(model.moveSelection(by: -3)?.name ?? "", "assets", "moves back up")
        expect(model.moveSelection(by: -1) == nil, "does not run off the top")

        model.selection = []
        expect(model.moveSelection(by: -1)?.name ?? "", "readme.md", "pressing up with nothing selected enters at the bottom")

        // Extending a selection must not move the cursor: the anchor stays
        // where the last arrow press left it, as long as it is still selected.
        model.selection = Set(model.visibleEntries.map(\.id))
        expect(model.focusedEntry?.name ?? "", "readme.md", "anchor survives a selection being extended")

        // Dropping the anchor from the selection hands it to the topmost item.
        model.selection = Set(model.visibleEntries.dropLast().map(\.id))
        expect(model.focusedEntry?.name ?? "", "assets", "topmost visible item takes over when the anchor is deselected")

        section("BrowserModel search")
        // Filtering is debounced, so the tests drive it through the same flush
        // the search field's Return key uses.
        model.searchText = "s"
        model.flushPendingSearch()
        expect(
            model.visibleEntries.map(\.name),
            ["assets", "src", "app.js"],
            "search matches anywhere in the name, extension included"
        )
        model.searchText = "src"
        model.flushPendingSearch()
        expect(model.visibleEntries.map(\.name), ["src"], "search narrows to one entry")
        model.selection = []
        expect(model.moveSelection(by: 1)?.name ?? "", "src", "arrows follow the filtered list")
        expect(model.moveSelection(by: 1) == nil, "arrows stop at the end of the filtered list")

        // Clearing is applied at once — waiting to see the folder come back
        // would feel broken.
        model.searchText = ""
        expect(model.visibleEntries.count, 4, "clearing the search is not debounced")

        model.entries = []
        model.searchText = ""
        model.selection = []
        expect(model.moveSelection(by: 1) == nil, "an empty folder has nothing to select")
    }

    private static func entry(_ name: String, kind: RemoteEntry.Kind) -> RemoteEntry {
        RemoteEntry(
            name: name,
            path: "/home/u/\(name)",
            kind: kind,
            size: 0,
            modifiedAt: nil,
            permissions: nil
        )
    }

    // MARK: - Shortcuts

    @MainActor
    private static func shortcutTests() {
        section("ShortcutStore")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassftp-shortcuts-\(UUID().uuidString).json")
        let store = ShortcutStore(fileURL: url)

        let serverA = UUID()
        let serverB = UUID()

        store.add(connectionID: serverA, path: "/var/www")
        expect(store.shortcuts.count, 1, "adds a shortcut")
        expect(store.shortcuts.first?.name ?? "", "www", "name defaults to the last path component")

        store.add(connectionID: serverA, path: "/var/www/")
        expect(store.shortcuts.count, 1, "a trailing slash is the same folder, not a second shortcut")

        store.add(connectionID: serverB, path: "/var/www")
        expect(store.shortcuts.count, 2, "same path on another server is a separate shortcut")

        store.add(connectionID: serverA, path: "/")
        expect(store.shortcuts.last?.name ?? "", "Root", "root gets a readable name")

        expect(store.contains(connectionID: serverA, path: "/var/www"), "contains finds an existing shortcut")
        expect(!store.contains(connectionID: serverA, path: "/etc"), "contains rejects an unknown path")

        if let first = store.shortcuts.first {
            store.rename(first, to: "Site")
            expect(store.shortcuts.first?.name ?? "", "Site", "rename")
        }

        // Deleting a server must not leave its shortcuts stranded in the sidebar.
        store.removeOrphans(validConnectionIDs: [serverB])
        expect(store.shortcuts.count, 1, "orphaned shortcuts are dropped")
        expect(store.shortcuts.first?.connectionID ?? UUID(), serverB, "the surviving shortcut belongs to the live server")

        // Round-trip through disk.
        let reloaded = ShortcutStore(fileURL: url)
        expect(reloaded.shortcuts.count, 1, "shortcuts persist across launches")

        if let survivor = reloaded.shortcuts.first {
            reloaded.delete(survivor)
            expect(reloaded.shortcuts.isEmpty, "delete")
        }
    }

    // MARK: - Permissions

    private static func permissionTests() {
        section("RemoteEntry display")
        let file = RemoteEntry(
            name: "script.sh",
            path: "/home/u/script.sh",
            kind: .file,
            size: 2048,
            modifiedAt: nil,
            permissions: 0o754
        )
        expect(file.displayPermissions, "rwxr-xr--", "mode renders as rwx triads")
        expect(file.octalPermissions, "754", "octal mode")
        expect(file.fileExtension, "sh", "extension")
        expect(file.displayModified, "--", "missing date renders as a dash")

        let dotfile = RemoteEntry(
            name: ".bashrc",
            path: "/home/u/.bashrc",
            kind: .file,
            size: 10,
            modifiedAt: nil,
            permissions: nil
        )
        expect(dotfile.fileExtension, "", "leading dot is not an extension")
        expect(dotfile.displayPermissions, "--", "absent mode renders as a dash")

        let folder = RemoteEntry(
            name: "www",
            path: "/var/www",
            kind: .directory,
            size: 4096,
            modifiedAt: nil,
            permissions: 0o755
        )
        expect(folder.displaySize, "--", "directories show no size")
        expect(folder.kindLabel, "Folder", "directory kind label")
    }
}

private extension URL {
    var lastComponent: String { lastPathComponent }
}
