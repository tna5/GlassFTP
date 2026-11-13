import AppKit
import SwiftUI

/// How the browser displays a folder. Mirrors the Finder's view menu.
enum BrowseViewMode: String, CaseIterable, Identifiable {
    case icons
    case list
    case columns

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icons: return "as Icons"
        case .list: return "as List"
        case .columns: return "as Columns"
        }
    }

    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .icons: return "1"
        case .list: return "2"
        case .columns: return "3"
        }
    }
}

/// The operations every view mode offers, so the icon, list and column views
/// can share one context menu instead of each growing its own copy.
struct BrowserActions {
    var open: (RemoteEntry) -> Void
    var download: ([RemoteEntry]) -> Void
    var rename: (RemoteEntry) -> Void
    var getInfo: (RemoteEntry) -> Void
    var copyPath: ([RemoteEntry]) -> Void
    var delete: ([RemoteEntry]) -> Void
    var addShortcut: (RemoteEntry) -> Void
    var newFolder: () -> Void
    var upload: () -> Void
    var refresh: () -> Void
    var canAddShortcut: (RemoteEntry) -> Bool
    /// Warms a folder's listing ahead of a click.
    var warm: (RemoteEntry) -> Void
    /// Space bar: show or dismiss the preview for an entry.
    var togglePreview: (RemoteEntry) -> Void
    /// The server drags belong to; a drop only moves items from the same one.
    var connectionID: UUID
    /// Moves remote paths into a folder (an in-app drop).
    var move: ([String], String) -> Void
    /// Uploads local files into a folder (a drop from the Finder).
    var uploadInto: ([URL], String) -> Void
}

/// The context menu shown for a selection — or for empty space, when the
/// selection is empty.
struct EntryContextMenu: View {
    let entries: [RemoteEntry]
    let actions: BrowserActions

    var body: some View {
        if entries.isEmpty {
            Button("New Folder") { actions.newFolder() }
            Button("Upload…") { actions.upload() }
            Divider()
            Button("Refresh") { actions.refresh() }
        } else {
            if entries.count == 1, let entry = entries.first, entry.kind != .file {
                Button("Open") { actions.open(entry) }
                Divider()
            }

            Button(entries.count == 1 ? "Download" : "Download \(entries.count) Items") {
                actions.download(entries)
            }

            if entries.count == 1, let entry = entries.first, entry.isDirectory {
                Button("Add to Shortcuts") { actions.addShortcut(entry) }
                    .disabled(!actions.canAddShortcut(entry))
            }

            Divider()

            if entries.count == 1, let entry = entries.first {
                Button("Quick Look") { actions.togglePreview(entry) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Rename…") { actions.rename(entry) }
                Button("Get Info") { actions.getInfo(entry) }
            }
            Button("Copy Path") { actions.copyPath(entries) }

            Divider()
            Button("Delete", role: .destructive) { actions.delete(entries) }
        }
    }
}

/// Click handling shared by the icon view.
///
/// SwiftUI grids have no built-in multi-selection, and `TapGesture.modifiers`
/// competes with the double-click recogniser, so the modifier is read straight
/// off the current event instead.
@MainActor
enum SelectionGesture {
    static func select(_ entry: RemoteEntry, in selection: inout Set<RemoteEntry.ID>) {
        guard NSEvent.modifierFlags.contains(.command) else {
            selection = [entry.id]
            return
        }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }
}
