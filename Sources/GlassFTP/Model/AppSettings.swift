import Foundation
import Observation

/// Every user preference, grouped the way the Settings window shows them.
///
/// Each group decodes field by field with a fallback to its default, so a
/// settings blob written by an older build — missing whatever was added since —
/// keeps everything it does have instead of being thrown away wholesale.
struct AppSettings: Codable, Equatable, Sendable {
    var general = General()
    var transfers = Transfers()
    var connection = ConnectionOptions()
    var proxy = ProxySettings()
    var advanced = Advanced()
    var agents = Agents()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        general = container.value(.general, default: defaults.general)
        transfers = container.value(.transfers, default: defaults.transfers)
        connection = container.value(.connection, default: defaults.connection)
        proxy = container.value(.proxy, default: defaults.proxy)
        advanced = container.value(.advanced, default: defaults.advanced)
        agents = container.value(.agents, default: defaults.agents)
    }

    // MARK: - General

    struct General: Codable, Equatable, Sendable {
        enum FileOpenAction: String, Codable, CaseIterable, Sendable {
            case download
            case preview

            var label: String {
                switch self {
                case .download: return "Download it"
                case .preview: return "Preview it"
                }
            }
        }

        /// Dotfiles are shown by default: on a server they are usually the
        /// point (`.htaccess`, `.env`), unlike in a home folder.
        var showHiddenFiles = true
        var foldersFirst = true
        var confirmBeforeDelete = true
        var reconnectOnLaunch = false
        var checkForUpdates = true
        var fileOpenAction = FileOpenAction.download

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            showHiddenFiles = container.value(.showHiddenFiles, default: defaults.showHiddenFiles)
            foldersFirst = container.value(.foldersFirst, default: defaults.foldersFirst)
            confirmBeforeDelete = container.value(.confirmBeforeDelete, default: defaults.confirmBeforeDelete)
            reconnectOnLaunch = container.value(.reconnectOnLaunch, default: defaults.reconnectOnLaunch)
            checkForUpdates = container.value(.checkForUpdates, default: defaults.checkForUpdates)
            fileOpenAction = container.value(.fileOpenAction, default: defaults.fileOpenAction)
        }
    }

    // MARK: - Transfers

    struct Transfers: Codable, Equatable, Sendable {
        static let concurrencyRange = 1...10
        static let retryRange = 0...5

        /// How many files move at once, each over its own SSH connection.
        /// Eight overlaps the per-file round trips of a folder of small files
        /// and stays under OpenSSH's default `MaxStartups` of 10 handshakes.
        var maxConcurrent = 8
        var askForDownloadFolder = true
        /// Used when `askForDownloadFolder` is off.
        var downloadFolder = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
        var whenDownloadExists = FileExistsAction.ask
        var whenUploadExists = FileExistsAction.ask
        var preserveModificationTime = true
        var retries = 2
        var retryDelaySeconds = 3
        var uploadHiddenFiles = false
        /// Leaves an interrupted download on disk so it can be resumed rather
        /// than starting again from zero.
        var keepPartialDownloads = true

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            maxConcurrent = container.value(.maxConcurrent, default: defaults.maxConcurrent)
            askForDownloadFolder = container.value(.askForDownloadFolder, default: defaults.askForDownloadFolder)
            downloadFolder = container.value(.downloadFolder, default: defaults.downloadFolder)
            whenDownloadExists = container.value(.whenDownloadExists, default: defaults.whenDownloadExists)
            whenUploadExists = container.value(.whenUploadExists, default: defaults.whenUploadExists)
            preserveModificationTime = container.value(.preserveModificationTime, default: defaults.preserveModificationTime)
            retries = container.value(.retries, default: defaults.retries)
            retryDelaySeconds = container.value(.retryDelaySeconds, default: defaults.retryDelaySeconds)
            uploadHiddenFiles = container.value(.uploadHiddenFiles, default: defaults.uploadHiddenFiles)
            keepPartialDownloads = container.value(.keepPartialDownloads, default: defaults.keepPartialDownloads)
        }

        var clampedConcurrency: Int {
            min(max(maxConcurrent, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound)
        }
    }

    // MARK: - Connection

    struct ConnectionOptions: Codable, Equatable, Sendable {
        var connectTimeoutSeconds = 30
        /// Entries, not folders — see `ListingCache`.
        var listingCacheBudget = ListingCache.defaultBudget
        var prefetchChildFolders = true
        var warmOnHover = true

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            connectTimeoutSeconds = container.value(.connectTimeoutSeconds, default: defaults.connectTimeoutSeconds)
            listingCacheBudget = container.value(.listingCacheBudget, default: defaults.listingCacheBudget)
            prefetchChildFolders = container.value(.prefetchChildFolders, default: defaults.prefetchChildFolders)
            warmOnHover = container.value(.warmOnHover, default: defaults.warmOnHover)
        }
    }

    // MARK: - Advanced

    struct Advanced: Codable, Equatable, Sendable {
        /// Read sizes offered when tuning by hand. 255 KB is the most OpenSSH
        /// answers per read.
        static let chunkSizes = [32_768, 65_536, 131_072, 261_120]
        static let pipelineRange = 1...128

        /// On by default, and on for settings saved before it existed: those
        /// carry the old 32 KB × 16 values, which would keep the transfers
        /// that saved them slow.
        var automaticTuning = true
        var chunkSize = 261_120
        var pipelineDepth = 16

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            automaticTuning = container.value(.automaticTuning, default: defaults.automaticTuning)
            chunkSize = container.value(.chunkSize, default: defaults.chunkSize)
            pipelineDepth = container.value(.pipelineDepth, default: defaults.pipelineDepth)
        }

        /// Never trust a stored value blindly: a zero chunk size would spin
        /// forever, and a huge one gets truncated or rejected by the server.
        var tuning: SFTPProvider.Tuning {
            guard !automaticTuning else { return SFTPProvider.Tuning() }

            let size = Self.chunkSizes.contains(chunkSize) ? chunkSize : 261_120
            let depth = min(max(pipelineDepth, Self.pipelineRange.lowerBound), Self.pipelineRange.upperBound)
            var tuning = SFTPProvider.Tuning()
            tuning.readSize = size
            tuning.readsInFlight = depth
            // Writes are always 32,000-byte requests (see `Tuning`); keep the
            // same number of bytes in flight as the reads.
            tuning.writesInFlight = max(1, size * depth / tuning.writeSize)
            return tuning
        }
    }
}

extension AppSettings {
    // MARK: - Agents

    /// What AI agents may do through `GlassFTP --mcp` (see `MCPServer`).
    ///
    /// Off by default, read-only by default, and no server is shared until it
    /// is ticked: an agent gets exactly what the user handed it and nothing
    /// that was added later.
    struct Agents: Codable, Equatable, Sendable {
        enum Access: String, Codable, CaseIterable, Identifiable, Sendable {
            case readOnly
            case readWrite
            case full

            var id: String { rawValue }

            var label: String {
                switch self {
                case .readOnly: return "Browse and download only"
                case .readWrite: return "Also upload, create, rename and move"
                case .full: return "Also delete"
                }
            }

            var canWrite: Bool { self != .readOnly }
            var canDelete: Bool { self == .full }
        }

        var enabled = false
        var access = Access.readOnly
        var allowedConnectionIDs: Set<UUID> = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            enabled = container.value(.enabled, default: defaults.enabled)
            access = container.value(.access, default: defaults.access)
            allowedConnectionIDs = container.value(.allowedConnectionIDs, default: defaults.allowedConnectionIDs)
        }
    }
}

/// What to do when a transfer's destination already exists.
enum FileExistsAction: String, Codable, CaseIterable, Sendable {
    case ask
    case overwrite
    case overwriteIfNewer
    case overwriteIfSizeDiffers
    case resume
    case rename
    case skip

    var label: String {
        switch self {
        case .ask: return "Ask"
        case .overwrite: return "Overwrite"
        case .overwriteIfNewer: return "Overwrite if source is newer"
        case .overwriteIfSizeDiffers: return "Overwrite if size differs"
        case .resume: return "Resume"
        case .rename: return "Keep both (rename)"
        case .skip: return "Skip"
        }
    }

    /// The choices offered once a conflict is in front of the user — "Ask"
    /// itself makes no sense as an answer.
    static var answers: [FileExistsAction] { allCases.filter { $0 != .ask } }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when it is missing or unreadable.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Owns the settings and persists them.
///
/// Code outside the UI receives `settings` as a value snapshot rather than a
/// reference to this store, so a transfer that started under one set of
/// options is not changed underneath itself.
@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private let defaults: UserDefaults
    private static let key = "appSettings"
    private static let lastConnectionKey = "lastConnectionID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    /// The connection last opened, for "reconnect on launch".
    var lastConnectionID: UUID? {
        get { defaults.string(forKey: Self.lastConnectionKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.lastConnectionKey) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
