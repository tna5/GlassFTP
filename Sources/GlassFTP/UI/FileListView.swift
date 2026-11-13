import SwiftUI

/// Finder's List view: sortable columns, multi-selection, one row per entry.
struct FileListView: View {
    @Bindable var model: BrowserModel
    let actions: BrowserActions
    let dragPromise: (RemoteEntry) -> FilePromise

    var body: some View {
        Table(model.visibleEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
            // Sorted on the precomputed natural key, not on `name`, and with
            // `.lexical` rather than the default `.localizedStandard` — the key
            // has already done the case folding and number padding, so paying
            // for a locale collation on every comparison would undo the point.
            TableColumn("Name", value: \.sortKey, comparator: String.StandardComparator.lexical) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.image(for: entry))
                        .resizable()
                        .frame(width: Theme.rowIconSize, height: Theme.rowIconSize)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(.rect)
                // Double-click on the name cell is the reliable way to open a
                // row: Table exposes no row-level activation gesture.
                .onTapGesture(count: 2) { actions.open(entry) }
                // Hovering reliably precedes the click, so warming here hides
                // most of the round trip behind the user's own aim.
                .onHover { if $0 { actions.warm(entry) } }
                .remoteDragSource(entry, promise: dragPromise)
                // Hovering a folder with a drag opens it, as in the Finder.
                .remoteDropTarget(for: entry, actions: actions) { actions.open(entry) }
            }
            .width(min: 220, ideal: 320)

            TableColumn("Size", value: \.size) { entry in
                Text(entry.displaySize)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 140)

            TableColumn("Kind", value: \.kindLabel, comparator: String.StandardComparator.lexical) { entry in
                Text(entry.kindLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130, max: 220)

            TableColumn("Date Modified", value: \.modifiedSortKey) { entry in
                Text(entry.displayModified)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 180, max: 260)
        }
        .tableStyle(.inset)
        // Up and down are handled by the table itself; these add the Finder's
        // horizontal navigation on top.
        .onKeyPress(.rightArrow) { descend() }
        .onKeyPress(.leftArrow) { ascend() }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) {
            guard let entry = model.focusedEntry else { return .ignored }
            actions.togglePreview(entry)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            press.modifiers.contains(.command) ? activate() : .ignored
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            EntryContextMenu(entries: entries(for: ids), actions: actions)
        } primaryAction: { ids in
            if let entry = entries(for: ids).first { actions.open(entry) }
        }
    }

    private func entries(for ids: Set<RemoteEntry.ID>) -> [RemoteEntry] {
        model.visibleEntries.filter { ids.contains($0.id) }
    }

    /// Right arrow steps into the highlighted folder.
    private func descend() -> KeyPress.Result {
        guard let entry = model.focusedEntry, entry.kind != .file else { return .ignored }
        actions.open(entry)
        return .handled
    }

    /// Left arrow steps back out, as in the Finder's column and list views.
    private func ascend() -> KeyPress.Result {
        guard model.canGoUp else { return .ignored }
        Task { await model.goUp() }
        return .handled
    }

    private func activate() -> KeyPress.Result {
        guard let entry = model.focusedEntry else { return .ignored }
        actions.open(entry)
        return .handled
    }
}
