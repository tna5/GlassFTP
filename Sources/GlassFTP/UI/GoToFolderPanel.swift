import SwiftUI

/// ⌘⇧G — the Finder's "Go to Folder", for the server.
///
/// Drawn like the Finder's own: a floating panel with no title or buttons, a
/// large field on top and, under a hairline, a list of paths drawn as
/// breadcrumbs — recent folders until you type, completions after. Return goes
/// to the highlighted row (or to what was typed), Tab completes, Escape or a
/// click outside closes.
///
/// Takes absolute paths, paths relative to the current folder, `~` and `..`.
/// A path to a file opens its folder with the file selected. Errors appear in
/// the panel, which stays open for a correction.
struct GoToFolderPanel: View {
    let model: BrowserModel
    let onClose: () -> Void

    @State private var text: String
    /// False until the user types: the list shows recents until then.
    @State private var hasEdited = false
    @State private var error: String?
    @State private var isGoing = false
    @State private var highlighted: Int?
    @State private var completer = PathCompleter()
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 470
    private static let rowHeight: CGFloat = 22

    init(model: BrowserModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _text = State(initialValue: Self.display(model.currentPath, home: model.homePath))
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        let path: String
        var id: String { path }
    }

    private var showsSuggestions: Bool {
        hasEdited && !completer.suggestions.isEmpty
    }

    private var rows: [Row] {
        if hasEdited {
            return completer.suggestions.map { Row(path: $0.path) }
        }
        // The folder in the field first, so Return on the untouched panel does
        // what it says; then where the user has been lately.
        var paths = [model.currentPath]
        for path in model.recentPaths where !paths.contains(path) && paths.count < 6 {
            paths.append(path)
        }
        return paths.map(Row.init)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field

            if error != nil || !rows.isEmpty {
                Divider()
                list
            }
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .animation(.snappy(duration: 0.12), value: rows.map(\.id))
        .animation(.snappy(duration: 0.12), value: error)
        .onAppear { highlighted = 0 }
        .task {
            // The panel arrives through a transition, and focus asked for in
            // `onAppear` is dropped while the field is not yet in the window;
            // the column table also tends to keep first responder. Ask again
            // once it has landed.
            for delay in [0, 60, 200] {
                try? await Task.sleep(for: .milliseconds(delay))
                if isFocused { break }
                isFocused = true
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $text, prompt: Text("Enter a path"))
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($isFocused)
                .onSubmit(go)
                .onChange(of: text) { _, value in
                    hasEdited = true
                    error = nil
                    highlighted = nil
                    completer.update(for: value, model: model)
                }
                .onKeyPress(.tab) {
                    complete()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            if isGoing {
                ProgressView().controlSize(.small)
            } else if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

            if !hasEdited, !rows.isEmpty {
                Text("Go to:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                PathCrumbRow(
                    components: Self.components(of: row.path, root: model.rootPath),
                    isHighlighted: index == highlighted
                )
                .frame(height: Self.rowHeight)
                .contentShape(.rect)
                .onTapGesture {
                    highlighted = index
                    go(to: row.path)
                }
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func moveHighlight(by offset: Int) {
        guard !rows.isEmpty else { return }
        guard let current = highlighted else {
            highlighted = offset > 0 ? 0 : rows.count - 1
            return
        }
        highlighted = min(max(current + offset, 0), rows.count - 1)
    }

    /// Tab: the highlighted (or first) completion, ending in a slash so the
    /// next level can be typed straight away.
    private func complete() {
        guard showsSuggestions else { return }
        let entry = completer.suggestions[highlighted ?? 0]
        text = PathCompleter.replacingLastComponent(of: text, with: entry.name)
    }

    /// Return: the highlighted row if there is one, otherwise what was typed.
    private func go() {
        if let highlighted, rows.indices.contains(highlighted) {
            go(to: rows[highlighted].path)
        } else {
            go(to: text)
        }
    }

    private func go(to input: String) {
        guard !isGoing, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isGoing = true
        Task {
            let failure = await model.goTo(input)
            isGoing = false
            if let failure {
                error = failure
                highlighted = nil
            } else {
                onClose()
            }
        }
    }

    // MARK: - Formatting

    /// `~/…` for paths under the home folder, as the Finder prefills it.
    private static func display(_ path: String, home: String?) -> String {
        guard let home, home != "/", RemotePath.isDescendant(path, of: home) else { return path }
        let rest = String(RemotePath.normalize(path).dropFirst(RemotePath.normalize(home).count))
        return "~" + (rest.isEmpty ? "/" : rest)
    }

    /// Breadcrumb names for a path, trimmed to the connection's root.
    private static func components(of path: String, root: String) -> [String] {
        let crumbs = RemotePath.breadcrumbs(for: path, relativeTo: root)
        // The server root reads better as "/" alone than as a leading crumb.
        let names = crumbs.map(\.name).filter { $0 != "/" }
        return names.isEmpty ? ["/"] : names
    }
}

/// One path drawn the way the Finder draws it here: `Users › me › Documents`,
/// with a rounded blue highlight for the active row.
private struct PathCrumbRow: View {
    let components: [String]
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                Text(name)
                    .lineLimit(1)
                    // Long trails give way in the middle, keeping the folder
                    // you are actually going to readable.
                    .layoutPriority(index == components.count - 1 ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
    }
}
