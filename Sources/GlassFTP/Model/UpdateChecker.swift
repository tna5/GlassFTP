import AppKit
import Foundation
import Observation

/// Looks for a newer build on GitHub Releases and installs it.
///
/// Every push to `main` publishes a release tagged `build-<N>` whose app
/// carries `N` as its `CFBundleVersion` (see `.github/workflows/dmg.yml`), so
/// "newer" is simply a larger build number. A release without a build number in
/// its tag, such as the original `v1.0.0`, is never offered.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable, Identifiable, Sendable {
        let build: Int
        let title: String
        let notes: String
        let downloadURL: URL
        let pageURL: URL
        var id: Int { build }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String, Release?)
    }

    var phase: Phase = .idle

    /// Whether the sheet is up. Checking at launch stays silent until there is
    /// something to show.
    var isPresented = false

    private let defaults: UserDefaults
    private static let skippedKey = "skippedUpdateBuild"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Nonisolated: they only read Info.plist, and `latestRelease` runs off
    // the main actor.
    nonisolated static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// `owner/name` on GitHub; a fork changes it in Info.plist.
    nonisolated static var repository: String {
        Bundle.main.infoDictionary?["GlassFTPUpdateRepository"] as? String ?? "tna5/GlassFTP"
    }

    /// Only an app bundle can replace itself; `swift run` and the bare binary
    /// in `.build` cannot.
    nonisolated static var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Checking

    /// At launch: quiet unless a build newer than this one, and not skipped,
    /// is out.
    func checkAtLaunch() async {
        guard Self.canInstall, phase == .idle else { return }
        guard let release = try? await Self.latestRelease(),
              release.build > Self.currentBuild,
              release.build != defaults.integer(forKey: Self.skippedKey)
        else { return }
        phase = .available(release)
        isPresented = true
    }

    /// From the menu: always answers, skipped builds included.
    func checkNow() async {
        phase = .checking
        isPresented = true
        do {
            if let release = try await Self.latestRelease(), release.build > Self.currentBuild {
                phase = .available(release)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed("Could not reach GitHub: \(error.localizedDescription)", nil)
        }
    }

    func skip(_ release: Release) {
        defaults.set(release.build, forKey: Self.skippedKey)
        dismiss()
    }

    func dismiss() {
        isPresented = false
        phase = .idle
    }

    // MARK: - Installing

    func install(_ release: Release) async {
        phase = .installing(release)
        do {
            let installed = try await UpdateInstaller.install(from: release.downloadURL)
            UpdateInstaller.relaunch(installed)
        } catch {
            phase = .failed(error.localizedDescription, release)
        }
    }

    // MARK: - GitHub

    nonisolated static func latestRelease() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub refuses API calls without a User-Agent.
        request.setValue("GlassFTP/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        // 404: the repository has no release yet.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// Reads GitHub's release JSON. `nil` for anything that is not a
    /// `build-<N>` release with a disk image attached.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              tag.hasPrefix("build-"),
              let build = Int(tag.dropFirst("build-".count)),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = object["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let download = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)),
              download.scheme == "https"
        else { return nil }

        return Release(
            build: build,
            title: object["name"] as? String ?? "GlassFTP (build \(build))",
            notes: object["body"] as? String ?? "",
            downloadURL: download,
            pageURL: page
        )
    }
}

/// Downloads a release's disk image and swaps it in for the running app.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns where the new app now is: the same path as this one.
    static func install(from url: URL) async throws -> URL {
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app" else {
            throw Failure(message: "This copy of GlassFTP is not an app bundle, so it cannot update itself.")
        }
        let folder = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure(message: "GlassFTP cannot write to \(folder.path). Download the update and drag it there yourself.")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassFTP-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "The download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let image = work.appendingPathComponent("GlassFTP.dmg")
        try FileManager.default.moveItem(at: downloaded, to: image)

        // The disk tools block, so they run off the main actor.
        return try await Task.detached {
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try UpdateInstaller.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-quiet", "-mountpoint", mount.path, image.path])
            defer { try? UpdateInstaller.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }

            let source = mount.appendingPathComponent("GlassFTP.app")
            guard let bundle = Bundle(url: source),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier
            else {
                throw Failure(message: "The downloaded disk image does not contain GlassFTP.")
            }

            // Copied next to the destination first, so the swap below stays on
            // one volume and is atomic: a failure leaves the old app in place.
            let staging = folder.appendingPathComponent(".GlassFTP-update-\(UUID().uuidString).app")
            try UpdateInstaller.run("/usr/bin/ditto", [source.path, staging.path])
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            return destination
        }.value
    }

    /// Opens the new copy once this process has exited, then quits.
    @MainActor
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            app.path
        ]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    fileprivate static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "\((tool as NSString).lastPathComponent) failed\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}
