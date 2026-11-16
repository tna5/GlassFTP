import Foundation

/// `GlassFTP --benchmark …`: times one download and one upload of a file
/// against a real server. Used by `.github/workflows/benchmark.yml` to compare
/// tunings; nothing in the app's interface leads here.
///
///     GlassFTP --benchmark --host 127.0.0.1 --port 2222 --user me \
///         --key ~/.ssh/id_ed25519 --remote /srv/big.bin --local /tmp \
///         --tuning legacy|current|oversize
///
/// `oversize` asks for 1 MB reads, more than OpenSSH answers, to exercise the
/// path where the first read teaches the download the server's read size.
///
/// The host key is accepted without asking: point it only at a server you
/// started yourself.
enum TransferBenchmark {
    private final class Status: @unchecked Sendable {
        var code: Int32 = 1
    }

    static func run(_ arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let host = value("host"), let user = value("user"), let key = value("key"),
              let remote = value("remote"), let local = value("local")
        else {
            FileHandle.standardError.write(Data("usage: GlassFTP --benchmark --host H [--port P] --user U --key FILE --remote PATH --local DIR [--tuning legacy|current|oversize]\n".utf8))
            return 2
        }

        let label = value("tuning") ?? "current"
        var tuning = SFTPProvider.Tuning()
        switch label {
        case "legacy": tuning = .legacy
        case "oversize": tuning.readSize = 1 << 20
        default: break
        }

        let configuration = SFTPProvider.Configuration(
            host: host,
            port: value("port").flatMap(Int.init) ?? 22,
            username: user,
            auth: .privateKey(path: (key as NSString).expandingTildeInPath, passphrase: nil),
            proxy: nil,
            connectTimeoutSeconds: 30,
            tuning: tuning
        )
        let directory = URL(fileURLWithPath: (local as NSString).expandingTildeInPath, isDirectory: true)

        // Blocks the main thread on purpose: nothing below needs it, and the
        // process exits as soon as the numbers are printed.
        let status = Status()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            status.code = await measure(configuration, label: label, remote: remote, directory: directory)
            done.signal()
        }
        done.wait()
        return status.code
    }

    private static func measure(
        _ configuration: SFTPProvider.Configuration,
        label: String,
        remote: String,
        directory: URL
    ) async -> Int32 {
        let provider = SFTPProvider(configuration: configuration, confirmHostKey: { _ in true })
        do {
            try await provider.connect()

            // One round trip, to show what latency the numbers were taken at.
            let clock = ContinuousClock()
            var started = clock.now
            _ = try await provider.realPath(".")
            print("round trip   \(label)  \(format(milliseconds: clock.now - started))")

            let target = directory.appendingPathComponent("download-\(label).bin")
            started = clock.now
            try await provider.download(from: remote, to: target, resumingAt: 0, keepPartial: false, progress: { _, _ in })
            let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            report("download", label, size, clock.now - started)

            started = clock.now
            try await provider.upload(from: target, to: "\(remote).\(label).up", resumingAt: 0, progress: { _, _ in })
            report("upload", label, size, clock.now - started)

            await provider.disconnect()
            return 0
        } catch {
            print("benchmark \(label) failed: \(error.localizedDescription) (\(error))")
            await provider.disconnect()
            return 1
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func format(milliseconds duration: Duration) -> String {
        String(format: "%.1f ms", seconds(duration) * 1_000)
    }

    private static func report(_ direction: String, _ label: String, _ bytes: Int64, _ duration: Duration) {
        let elapsed = max(seconds(duration), 0.000_001)
        let mebibytes = Double(bytes) / 1_048_576
        print(String(
            format: "%@  %@  %.0f MiB in %.2f s  %.1f MiB/s",
            direction.padding(toLength: 11, withPad: " ", startingAt: 0),
            label.padding(toLength: 8, withPad: " ", startingAt: 0),
            mebibytes,
            elapsed,
            mebibytes / elapsed
        ))
    }
}
