import SwiftUI

/// The Finder's bottom bars: the path bar, then the status bar under it.
///
/// - **Path bar** (View › Hide/Show Path Bar, ⌥⌘P): the server, then each
///   folder, with small icons and chevrons. Click a crumb to go there; each
///   takes drops (move from inside the app, upload from the Finder) and has a
///   context menu. Deep paths fold their middle into a "…" menu.
/// - **Editing** (⌘L, or double-click the empty part of the bar): the path as
///   text in place of the crumbs, with folder completion. Return goes, Escape
///   cancels; a bad path shakes and stays to be corrected. The bar shows
///   itself while editing even when hidden.
/// - **Status bar**: item count and selection, centred.
struct PathBar: View {
    @Bindable var model: BrowserModel
    @Binding var isEditing: Bool
    let showsPath: Bool
    let onCopyPath: (String) -> Void
    let onAddShortcut: (String) -> Void
    let canAddShortcut: (String) -> Bool
    let onDownloadFolder: (String) -> Void
    /// Drops on a crumb: moves from inside the app, uploads from the Finder.
    let actions: BrowserActions

    @State private var text = ""
    @State private var error: String?
    @State private var isGoing = false
    @State private var shakes = 0
    @State private var completer = PathCompleter()
    @FocusState private var isFieldFocused: Bool

    static let pathRowHeight: CGFloat = 26
    static let statusRowHeight: CGFloat = 24

    /// Total height, so floating panels can sit above the bars.
    static func height(showingPath: Bool) -> CGFloat {
        (showingPath ? pathRowHeight + 1 : 0) + statusRowHeight + 1
    }

    /// Crumbs shown in full before the middle folds into "…".
    private static let visibleCrumbLimit = 6

    var body: some View {
        VStack(spacing: 0) {
            if showsPath || isEditing {
                Divider()
                Group {
                    if isEditing {
                        editor
                    } else {
                        crumbRow
                    }
                }
                .frame(height: Self.pathRowHeight)
                .overlay(alignment: .topLeading) { popup }
                .transition(.opacity)
            }
            Divider()
            statusRow
                .frame(height: Self.statusRowHeight)
        }
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: showsPath)
        .onChange(of: isEditing) { _, editing in
            if editing { beginEditing() } else { completer.clear() }
        }
        // ⌘L may have been pressed before this view existed.
        .onAppear { if isEditing { beginEditing() } }
        .onChange(of: model.currentPath) { _, _ in
            if !isGoing { isEditing = false }
        }
    }

    // MARK: - Crumbs

    private var crumbRow: some View {
        HStack(spacing: 0) {
            trail
                .layoutPriority(1)
            // The empty stretch: double-click to type a path.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture(count: 2) { isEditing = true }
        }
        .padding(.horizontal, 8)
    }

    private var trail: some View {
        let crumbs = model.breadcrumbs
        return HStack(spacing: 2) {
            ForEach(Array(displayed(crumbs).enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 1)
                }
                switch item {
                case .crumb(let crumb, let isRoot):
                    CrumbButton(
                        name: isRoot ? rootName(crumb) : crumb.name,
                        icon: isRoot ? FileIcon.volume(size: 14) : FileIcon.folder(size: 14),
                        isCurrent: RemotePath.normalize(crumb.path) == model.currentPath,
                        onNavigate: { Task { await model.navigate(to: crumb.path) } },
                        path: crumb.path,
                        actions: actions
                    )
                    .contextMenu { crumbMenu(crumb.path) }
                case .collapsed(let hidden):
                    Menu {
                        ForEach(hidden, id: \.path) { crumb in
                            Button {
                                Task { await model.navigate(to: crumb.path) }
                            } label: {
                                Label(crumb.name, systemImage: "folder.fill")
                            }
                        }
                    } label: {
                        Text("…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(hidden.map(\.name).joined(separator: " › "))
                }
            }
        }
    }

    private enum TrailItem {
        case crumb((name: String, path: String), isRoot: Bool)
        case collapsed([(name: String, path: String)])
    }

    /// First crumb, "…", then the last few — the shape of a Finder path bar
    /// that has run out of room.
    private func displayed(_ crumbs: [(name: String, path: String)]) -> [TrailItem] {
        guard crumbs.count > Self.visibleCrumbLimit else {
            return crumbs.enumerated().map { .crumb($1, isRoot: $0 == 0) }
        }
        let tailCount = Self.visibleCrumbLimit - 2
        let hidden = Array(crumbs[1..<(crumbs.count - tailCount)])
        return [.crumb(crumbs[0], isRoot: true), .collapsed(hidden)]
            + crumbs.suffix(tailCount).map { .crumb($0, isRoot: false) }
    }

    /// The root crumb carries the server's name, as the Finder's carries the
    /// disk's; a scoped root keeps its folder name after it.
    private func rootName(_ crumb: (name: String, path: String)) -> String {
        let server = model.connection.displayName
        return crumb.name == "/" ? server : "\(server) · \(crumb.name)"
    }

    @ViewBuilder
    private func crumbMenu(_ path: String) -> some View {
        Button("Copy Path") { onCopyPath(path) }
        Button("Add to Shortcuts") { onAddShortcut(path) }
            .disabled(!canAddShortcut(path))
        Button("Download Folder") { onDownloadFolder(path) }
        Divider()
        Button("Edit Path…") { isEditing = true }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .contentTransition(.numericText())
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            if !model.settings.general.showHiddenFiles {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(.tertiary)
                    .help("Hidden files are not shown (Settings › General)")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        let count = model.visibleEntries.count
        let items = count == 1 ? "1 item" : "\(count.formatted()) items"
        if !model.selection.isEmpty {
            return "\(model.selection.count) of \(items) selected"
        }
        return items
    }

    // MARK: - Editing

    private var editor: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcon.folder(size: 14))
            TextField("Path", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospaced())
                .focused($isFieldFocused)
                .onSubmit(go)
                .onChange(of: text) { _, value in
                    error = nil
                    completer.update(for: value, model: model)
                }
                .onKeyPress(.tab) {
                    if let completed = completer.completion(of: text) { text = completed }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    completer.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    completer.moveHighlight(by: -1)
                    return .handled
                }
                .onExitCommand { isEditing = false }
                .onChange(of: isFieldFocused) { _, focused in
                    guard !focused else { return }
                    // Clicking a suggestion briefly takes focus; only a real
                    // click elsewhere should end editing.
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        if !isFieldFocused, !isGoing { isEditing = false }
                    }
                }
            if isGoing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "return")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(.background)
                .strokeBorder(error == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.red), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .modifier(Shake(animatableData: CGFloat(shakes)))
    }

    /// Suggestions or the error, floating just above the bar.
    @ViewBuilder
    private var popup: some View {
        if isEditing, error != nil || !completer.suggestions.isEmpty {
            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                } else {
                    PathSuggestionList(
                        suggestions: completer.suggestions,
                        highlighted: completer.highlighted
                    ) { entry in
                        text = PathCompleter.replacingLastComponent(of: text, with: entry.name)
                        isFieldFocused = true
                    }
                    .frame(width: 320)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.controlRadius))
            .padding(.leading, 8)
            .alignmentGuide(.top) { $0[.bottom] + 6 }
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    private func beginEditing() {
        text = model.currentPath
        error = nil
        Task {
            // Focus once the field exists.
            isFieldFocused = true
        }
    }

    private func go() {
        if completer.highlighted != nil, let completed = completer.completion(of: text) {
            text = completed
            completer.clear()
            return
        }
        guard !isGoing else { return }
        isGoing = true
        let typed = text
        Task {
            let failure = await model.goTo(typed)
            isGoing = false
            if let failure {
                error = failure
                withAnimation(.linear(duration: 0.35)) { shakes += 1 }
                isFieldFocused = true
            } else {
                isEditing = false
            }
        }
    }
}

/// One folder in the trail: small icon and name, as in the Finder.
private struct CrumbButton: View {
    let name: String
    let icon: NSImage
    let isCurrent: Bool
    let onNavigate: () -> Void
    let path: String
    let actions: BrowserActions

    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        Button(action: onNavigate) {
            HStack(spacing: 4) {
                Image(nsImage: icon)
                    .frame(width: 14, height: 14)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .font(.system(size: 11))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isTargeted
                        ? AnyShapeStyle(.tint.opacity(0.3))
                        : AnyShapeStyle(.primary.opacity(isHovering ? 0.08 : 0)))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .remoteDropTarget(path: path, actions: actions, style: .none, isTargeted: $isTargeted)
        .help(isCurrent ? name : "Go to \(name) — drop items here to move or upload them into it")
    }
}

/// A horizontal shake for a rejected path.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}
