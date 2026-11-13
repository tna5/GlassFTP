import AppKit
import SwiftUI

/// The browser for one connected session: chrome, dialogs and whichever view
/// mode is active.
struct FileBrowserView: View {
    @Bindable var model: BrowserModel
    @Environment(AppState.self) private var app

    @AppStorage("viewMode") private var viewMode: BrowseViewMode = .list
    @AppStorage("showPathBar") private var showPathBar = true

    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var renameTarget: RemoteEntry?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteEntry] = []
    @State private var isTargetedForDrop = false

    var body: some View {
        content
            .modifier(BrowserDialogs(
                model: model,
                isCreatingFolder: $isCreatingFolder,
                newFolderName: $newFolderName,
                renameTarget: $renameTarget,
                renameText: $renameText,
                deleteTargets: $deleteTargets
            ))
    }

    /// Split out from `body` because the full chain of toolbars, dialogs and
    /// drop handling exceeds what the type checker will solve in one expression.
    private var content: some View {
        @Bindable var app = app

        return viewForMode
            // The list draws its own edge treatment; letting the grid and the
            // columns fade under the glass toolbar keeps them consistent.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The Finder's path and status bars, in a strip of their own.
            .safeAreaInset(edge: .bottom, spacing: 0) { pathBar }
            .overlay { preview }
            .toolbar { toolbarContent }
            .navigationTitle(RemotePath.lastComponent(of: titlePath))
            .searchable(
                text: $model.searchText,
                isPresented: $app.isSearchPresented,
                prompt: "Search this folder"
            )
            .onSubmit(of: .search) { model.flushPendingSearch() }
            .overlay { overlays }
            // Drops that miss every folder land in the one on screen.
            .remoteDropTarget(
                path: model.currentPath,
                actions: actions,
                style: .none,
                isTargeted: $isTargetedForDrop
            )
            .overlay { dropHighlight }
            // Quick Look follows the selection: arrowing through the folder
            // with the panel open swaps the file in place. Stepping into
            // another folder keeps it open too, as in the Finder.
            .onChange(of: model.selection) { _, selection in
                guard app.previewEntry != nil,
                      selection.count == 1,
                      let entry = model.selectedEntries.first,
                      entry.id != app.previewEntry?.id
                else { return }
                app.previewEntry = entry
            }
            .animation(.snappy(duration: 0.2), value: app.previewEntry == nil)
    }

    /// The folder the window is about.
    ///
    /// In the column view a selected folder is already open — its contents
    /// fill the next column — even though the model's current folder is still
    /// its parent; the Finder titles the window after it, and so does this.
    private var titlePath: String {
        if viewMode == .columns,
           model.selection.count == 1,
           let entry = model.selectedEntries.first,
           entry.isDirectory {
            return entry.path
        }
        return model.currentPath
    }

    @ViewBuilder
    private var viewForMode: some View {
        switch viewMode {
        case .icons:
            FileIconView(model: model, actions: actions, dragPromise: dragPromise)
        case .list:
            FileListView(model: model, actions: actions, dragPromise: dragPromise)
        case .columns:
            FileColumnView(model: model, actions: actions, dragPromise: dragPromise)
        }
    }

    private var pathBar: some View {
        @Bindable var app = app

        return PathBar(
            model: model,
            isEditing: $app.isEditingPath,
            showsPath: showPathBar,
            onCopyPath: { path in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            onAddShortcut: { app.addShortcut(for: $0) },
            canAddShortcut: { app.canAddShortcut(for: $0) },
            onDownloadFolder: { path in
                let folder = RemoteEntry(
                    name: RemotePath.lastComponent(of: path),
                    path: path,
                    kind: .directory,
                    size: 0,
                    modifiedAt: nil,
                    permissions: nil
                )
                download([folder])
            },
            actions: actions
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let entry = app.previewEntry {
            ZStack {
                // Light enough that the panel still has something to refract,
                // dark enough to pull the eye to it. Clicking it dismisses.
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { app.previewEntry = nil }

                PreviewPanel(
                    entry: entry,
                    provider: model.provider,
                    listing: { await model.listing(for: $0) },
                    onDownload: { download([$0]) }
                ) {
                    app.previewEntry = nil
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            // Escape closes it, matching every other panel on the system.
            .onExitCommand { app.previewEntry = nil }
        }
    }

    /// Dragging a selected item drags the whole selection, as in the Finder;
    /// dragging anything else drags just that item and leaves the selection be.
    private func dragPromise(_ entry: RemoteEntry) -> FilePromise {
        let paths = model.selection.contains(entry.id) && model.selection.count > 1
            ? model.selectedEntries.map(\.path)
            : [entry.path]
        return FilePromise(entry: entry, paths: paths, session: model, transfers: app.transfers)
    }

    // MARK: - Actions

    private var actions: BrowserActions {
        BrowserActions(
            open: open,
            download: download,
            rename: { entry in
                renameText = entry.name
                renameTarget = entry
            },
            getInfo: { app.inspectorEntry = $0 },
            copyPath: { entries in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries.map(\.path).joined(separator: "\n"), forType: .string)
            },
            delete: { entries in
                if app.settings.settings.general.confirmBeforeDelete {
                    deleteTargets = entries
                } else {
                    Task { await model.delete(entries) }
                }
            },
            addShortcut: { app.addShortcut(for: $0.path) },
            newFolder: beginCreateFolder,
            upload: chooseUploads,
            refresh: { Task { await model.refresh() } },
            canAddShortcut: { app.canAddShortcut(for: $0.path) },
            warm: { model.warm($0) },
            togglePreview: { entry in
                // Space toggles: pressing it again on the same file closes the
                // panel, as Quick Look does.
                app.previewEntry = app.previewEntry?.id == entry.id ? nil : entry
            },
            connectionID: model.connection.id,
            move: { paths, destination in
                Task { await model.move(paths, into: destination) }
            },
            uploadInto: { urls, destination in upload(urls, to: destination) }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    /// Outline symbols, as in the Finder's toolbar — the one place the app
    /// does not use the filled set, so each label opts out of it.
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await model.goBack() }
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .symbolVariant(.none)
            }
            .disabled(!model.canGoBack)

            Button {
                Task { await model.goForward() }
            } label: {
                Label("Forward", systemImage: "chevron.forward")
                    .symbolVariant(.none)
            }
            .disabled(!model.canGoForward)
        }

        ToolbarSpacer(.fixed, placement: .navigation)

        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.goUp() }
            } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
                    .symbolVariant(.none)
            }
            .disabled(!model.canGoUp)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem {
            Picker("View", selection: $viewMode) {
                ForEach(BrowseViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                        .symbolVariant(.none)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button {
                beginCreateFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .symbolVariant(.none)
            }

            Button {
                app.addShortcut(for: model.currentPath)
            } label: {
                Label("Add to Shortcuts", systemImage: "star")
                    .symbolVariant(.none)
            }
            .disabled(!app.canAddShortcut(for: model.currentPath))

            Button {
                chooseUploads()
            } label: {
                Label("Upload", systemImage: "arrow.up.document")
                    .symbolVariant(.none)
            }

            Button {
                download(model.selectedEntries)
            } label: {
                Label("Download", systemImage: "arrow.down.document")
                    .symbolVariant(.none)
            }
            .disabled(model.selection.isEmpty)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolVariant(.none)
            }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        if model.isLoading && model.entries.isEmpty {
            ProgressView().controlSize(.large)
        } else if model.entries.isEmpty && !model.isLoading && viewMode != .columns {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder.fill")
            } description: {
                Text("Drag files here to upload them.")
            }
        } else if model.visibleEntries.isEmpty && !model.searchText.isEmpty && viewMode != .columns {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isTargetedForDrop {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Operations

    private func open(_ entry: RemoteEntry) {
        guard entry.kind != .file else {
            openFile(entry)
            return
        }
        Task {
            // A symlink may point at a file; fall back to treating it as one.
            if await model.open(entry) == false {
                openFile(entry)
            }
        }
    }

    /// Double-click or Return on a file, per Settings › General.
    private func openFile(_ entry: RemoteEntry) {
        switch app.settings.settings.general.fileOpenAction {
        case .download: download([entry])
        case .preview: app.previewEntry = entry
        }
    }

    private func beginCreateFolder() {
        newFolderName = "untitled folder"
        isCreatingFolder = true
    }

    private func download(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }
        let options = app.settings.settings.transfers
        let destination: URL
        if options.askForDownloadFolder {
            guard let chosen = FileDialogs.chooseDownloadDirectory() else { return }
            destination = chosen
        } else {
            destination = URL(fileURLWithPath: (options.downloadFolder as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        app.isShowingTransfers = true
        app.transfers.download(entries, to: destination, pool: model.transferPool)
    }

    private func chooseUploads() {
        let urls = FileDialogs.chooseUploads()
        guard !urls.isEmpty else { return }
        upload(urls)
    }

    private func upload(_ urls: [URL], to directory: String? = nil) {
        guard !urls.isEmpty else { return }
        let target = directory ?? model.currentPath
        app.isShowingTransfers = true
        app.transfers.upload(urls, to: target, pool: model.transferPool) {
            // Only the folder on screen needs redrawing; another one is
            // revalidated whenever it is next opened.
            if model.currentPath == target {
                Task { await model.refresh() }
            }
        }
    }
}

/// The alerts and confirmation dialogs for the browser, factored out to keep
/// the main view's type-checking tractable.
private struct BrowserDialogs: ViewModifier {
    @Bindable var model: BrowserModel
    @Binding var isCreatingFolder: Bool
    @Binding var newFolderName: String
    @Binding var renameTarget: RemoteEntry?
    @Binding var renameText: String
    @Binding var deleteTargets: [RemoteEntry]

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { await model.createDirectory(named: name) }
                }
            }
            .alert("Rename", isPresented: isPresented($renameTarget)) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Rename") {
                    guard let target = renameTarget else { return }
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    renameTarget = nil
                    guard !name.isEmpty, name != target.name else { return }
                    Task { await model.rename(target, to: name) }
                }
            }
            .confirmationDialog(deleteMessage, isPresented: hasTargets($deleteTargets)) {
                Button("Delete", role: .destructive) {
                    let targets = deleteTargets
                    deleteTargets = []
                    Task { await model.delete(targets) }
                }
                Button("Cancel", role: .cancel) { deleteTargets = [] }
            } message: {
                Text("This cannot be undone. Items are removed from the server, not moved to a Trash.")
            }
            .alert(
                model.error?.errorDescription ?? "Error",
                isPresented: isPresented($model.error)
            ) {
                Button("OK") { model.error = nil }
            } message: {
                if let suggestion = model.error?.recoverySuggestion {
                    Text(suggestion)
                }
            }
    }

    private var deleteMessage: String {
        if deleteTargets.count == 1, let target = deleteTargets.first {
            return "Delete \u{201C}\(target.name)\u{201D}?"
        }
        return "Delete \(deleteTargets.count) items?"
    }

    private func isPresented<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    private func hasTargets(_ binding: Binding<[RemoteEntry]>) -> Binding<Bool> {
        Binding(get: { !binding.wrappedValue.isEmpty }, set: { if !$0 { binding.wrappedValue = [] } })
    }
}
