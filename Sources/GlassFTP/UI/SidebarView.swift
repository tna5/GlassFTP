import AppKit
import SwiftUI

/// Saved servers and bookmarked folders, laid out like the Finder sidebar's
/// Locations and Favorites sections.
struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        List(selection: $app.sidebarSelection) {
            Section("Connections") {
                ForEach(app.connections.connections) { connection in
                    connectionRow(connection)
                        .tag(SidebarItem.connection(connection.id))
                }
            }

            if !app.shortcuts.shortcuts.isEmpty {
                Section("Shortcuts") {
                    ForEach(app.shortcuts.shortcuts) { shortcut in
                        shortcutRow(shortcut)
                            .tag(SidebarItem.shortcut(shortcut.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A sidebar list resets symbols to outlines; the rest of the app is solid.
        .symbolVariant(.fill)
        // The Finder's sidebar never takes the keyboard, so its selection
        // stays the quiet grey instead of turning accent-blue on click.
        .background(SidebarFocusRefuser())
        .overlay {
            if app.connections.connections.isEmpty {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom) {
            addButton
        }
        .navigationSplitViewColumnWidth(
            min: Theme.sidebarMinWidth,
            ideal: Theme.sidebarIdealWidth,
            max: 340
        )
    }

    // MARK: - Rows

    /// One line, blue icon, name — the Finder's sidebar row. The selected row
    /// gets the grey pill and a bolder name; a connected server carries an
    /// eject button, as a mounted volume does.
    private func connectionRow(_ connection: Connection) -> some View {
        let isConnected = app.isConnected(to: connection)
        let isSelected = app.sidebarSelection == .connection(connection.id)

        return HStack(spacing: 6) {
            Label {
                Text(connection.displayName)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                // `server.rack` has no filled form; the drive does.
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 4)
            if isConnected {
                Button {
                    Task { await app.disconnect() }
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
            }
        }
        // The address moved out of the row; it is still a hover away.
        .help(connection.subtitle)
        .contextMenu {
            Button("Connect") { Task { await app.connect(to: connection) } }
            Button("Edit…") {
                app.isEditingNewConnection = false
                app.editingConnection = connection
            }
            if isConnected {
                Button("Disconnect") { Task { await app.disconnect() } }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await app.delete(connection) }
            }
        }
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        let isSelected = app.sidebarSelection == .shortcut(shortcut.id)

        return Label {
            Text(shortcut.name)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
        }
        .help(subtitle(for: shortcut))
        .contextMenu {
            Button("Open") {
                Task { await app.handleSidebarSelection(.shortcut(shortcut.id)) }
            }
            Button("Rename…") { app.renamingShortcut = shortcut }
            Divider()
            Button("Remove from Sidebar", role: .destructive) {
                if app.sidebarSelection == .shortcut(shortcut.id) {
                    app.sidebarSelection = app.session.map { .connection($0.connection.id) }
                }
                app.shortcuts.delete(shortcut)
            }
        }
    }

    /// Shows which server a shortcut belongs to, since two servers can easily
    /// have a folder with the same name.
    private func subtitle(for shortcut: Shortcut) -> String {
        let server = app.connections.connections
            .first { $0.id == shortcut.connectionID }?
            .displayName
        guard let server else { return shortcut.path }
        return "\(server) — \(shortcut.path)"
    }

    // MARK: - Chrome

    private var addButton: some View {
        Button {
            app.isEditingNewConnection = true
            app.editingConnection = Connection()
        } label: {
            Label("Add Connection", systemImage: "plus")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(10)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "externaldrive.fill.badge.questionmark")
        } description: {
            Text("Add a server to get started.")
        }
    }
}

/// Stops the sidebar's table from becoming first responder.
///
/// SwiftUI has no switch for this: a focused list draws its selection in the
/// accent colour, and `.focusable(false)` does not reach the AppKit table
/// underneath. Clicks still select rows; only keyboard focus is refused.
private struct SidebarFocusRefuser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// The list is a sibling somewhere up the tree, not an ancestor, so
        /// search down from the nearest common container.
        private func apply() {
            var container = superview
            for _ in 0..<6 {
                guard let current = container else { return }
                if let table = Self.findTable(in: current) {
                    table.refusesFirstResponder = true
                    if table.window?.firstResponder === table {
                        table.window?.makeFirstResponder(nil)
                    }
                    return
                }
                container = current.superview
            }
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }
    }
}
