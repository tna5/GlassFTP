import Foundation
import Observation

/// A bookmarked folder on a server, shown in the sidebar's Shortcuts section.
///
/// Stores the connection's id rather than a copy of it, so renaming or
/// re-pointing a server carries every shortcut with it.
struct Shortcut: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var connectionID: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), connectionID: UUID, name: String, path: String) {
        self.id = id
        self.connectionID = connectionID
        self.name = name
        self.path = path
    }
}

/// Saved shortcuts, persisted next to the connections file.
@MainActor
@Observable
final class ShortcutStore {
    private(set) var shortcuts: [Shortcut] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    static var defaultFileURL: URL {
        ConnectionStore.defaultFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("shortcuts.json")
    }

    func add(connectionID: UUID, path: String, name: String? = nil) {
        let normalized = RemotePath.normalize(path)
        // Bookmarking the same folder twice is almost always a misclick.
        guard !shortcuts.contains(where: { $0.connectionID == connectionID && $0.path == normalized }) else { return }

        let label = name ?? {
            let component = RemotePath.lastComponent(of: normalized)
            return component == "/" ? "Root" : component
        }()
        shortcuts.append(Shortcut(connectionID: connectionID, name: label, path: normalized))
        save()
    }

    func rename(_ shortcut: Shortcut, to name: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index].name = name
        save()
    }

    func delete(_ shortcut: Shortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        save()
    }

    /// Drops shortcuts whose server is gone, so the sidebar cannot show a row
    /// that leads nowhere.
    func removeOrphans(validConnectionIDs: Set<UUID>) {
        let before = shortcuts.count
        shortcuts.removeAll { !validConnectionIDs.contains($0.connectionID) }
        if shortcuts.count != before { save() }
    }

    func contains(connectionID: UUID, path: String) -> Bool {
        let normalized = RemotePath.normalize(path)
        return shortcuts.contains { $0.connectionID == connectionID && $0.path == normalized }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        shortcuts = (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(shortcuts).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("GlassFTP: could not save shortcuts: \(error.localizedDescription)")
        }
    }
}

/// What the sidebar's selection can point at.
enum SidebarItem: Hashable {
    case connection(UUID)
    case shortcut(UUID)
}
