import AppKit
import SwiftUI

/// Finder's Icon view: a grid of large icons with names underneath.
struct FileIconView: View {
    @Bindable var model: BrowserModel
    let actions: BrowserActions
    let dragPromise: (RemoteEntry) -> FilePromise

    @AppStorage("iconSize") private var iconSize: Double = 72

    /// Live column count, needed so the up and down arrows move by one row
    /// rather than one item.
    @State private var columnCount = 1

    private static let gridSpacing: CGFloat = 12

    private var itemMinimum: CGFloat { iconSize + 44 }

    private var columns: [GridItem] {
        // Top-aligned so a two-line name does not push its neighbours' icons
        // down out of line.
        [GridItem(.adaptive(minimum: itemMinimum), spacing: Self.gridSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                    ForEach(model.visibleEntries) { entry in
                        cell(for: entry)
                            .id(entry.id)
                    }
                }
                .padding(16)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // Mirrors how an adaptive grid packs its columns.
                let usable = width - 32
                columnCount = max(1, Int((usable + Self.gridSpacing) / (itemMinimum + Self.gridSpacing)))
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(by: -1, using: proxy) }
            .onKeyPress(.rightArrow) { move(by: 1, using: proxy) }
            .onKeyPress(.upArrow) { move(by: -columnCount, using: proxy) }
            .onKeyPress(.downArrow, phases: .down) { press in
                press.modifiers.contains(.command)
                    ? activate()
                    : move(by: columnCount, using: proxy)
            }
            .onKeyPress(.return) { activate() }
            .onKeyPress(.space) {
            guard let entry = model.focusedEntry else { return .ignored }
            actions.togglePreview(entry)
            return .handled
        }
        }
        // A click on the background clears the selection, as in the Finder.
        .contentShape(.rect)
        .onTapGesture { model.selection = [] }
        .contextMenu {
            EntryContextMenu(entries: model.selectedEntries, actions: actions)
        }
    }

    private func move(by offset: Int, using proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let entry = model.moveSelection(by: offset) else { return .ignored }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(entry.id) }
        return .handled
    }

    /// Command-Down and Return open the highlighted item, as in the Finder.
    private func activate() -> KeyPress.Result {
        guard let entry = model.focusedEntry else { return .ignored }
        actions.open(entry)
        return .handled
    }

    private func cell(for entry: RemoteEntry) -> some View {
        let isSelected = model.selection.contains(entry.id)

        return VStack(spacing: 6) {
            Image(nsImage: FileIcon.image(for: entry, size: iconSize))
                .frame(width: iconSize, height: iconSize)

            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .selectedContentBackgroundColor))
                    }
                }
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .frame(width: iconSize + 36)
        .padding(6)
        .background {
            // The Finder's grey plate behind a selected icon.
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.1))
            }
        }
        .contentShape(.rect)
        // One recogniser reading the click count, instead of a double-tap
        // gesture in front of a single one: that pairing held every single
        // click back for the double-click interval, which is what made
        // selecting in this view feel sluggish.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                actions.open(entry)
            } else {
                SelectionGesture.select(entry, in: &model.selection)
            }
        }
        .onHover { if $0 { actions.warm(entry) } }
        .remoteDragSource(entry, promise: dragPromise)
        .remoteDropTarget(for: entry, actions: actions) { actions.open(entry) }
        .contextMenu {
            // Right-clicking outside the selection acts on the clicked item,
            // matching the Finder.
            EntryContextMenu(
                entries: model.selection.contains(entry.id) ? model.selectedEntries : [entry],
                actions: actions
            )
        }
    }
}
