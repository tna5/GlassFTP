import SwiftUI

/// Folder-name completion for typed remote paths, shared by Go to Folder and
/// the path bar's edit mode.
///
/// Lists the folder being typed into (cache-first, through the browser's
/// listing cache) and offers the subfolders whose name starts with what was
/// typed after the last slash — the Finder's Go to Folder behaviour.
@MainActor
@Observable
final class PathCompleter {
    private(set) var suggestions: [RemoteEntry] = []
    /// Index into `suggestions` chosen with the arrow keys.
    var highlighted: Int?

    private var task: Task<Void, Never>?
    private static let limit = 8
    private static let debounce = Duration.milliseconds(120)

    func update(for text: String, model: BrowserModel) {
        task?.cancel()
        guard let parts = RemotePath.completionParts(of: text, from: model.currentPath, home: model.homePath) else {
            suggestions = []
            highlighted = nil
            return
        }

        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let listing = await model.listing(for: parts.folder)
            guard !Task.isCancelled, let self else { return }

            let prefix = parts.prefix.lowercased()
            // Dotfolders only once the user has typed the dot — the same
            // reason the Finder hides them.
            let includeHidden = prefix.hasPrefix(".")
            let matches = listing
                .filter { $0.kind != .file }
                .filter { includeHidden || !$0.isHidden }
                .filter { prefix.isEmpty || $0.searchKey.hasPrefix(prefix) }
                .sorted { $0.sortKey < $1.sortKey }
            // Typing a folder's full name exactly should not keep offering it.
            let exact = matches.count == 1 && matches[0].searchKey == prefix
            self.suggestions = exact ? [] : Array(matches.prefix(Self.limit))
            self.highlighted = nil
        }
    }

    func clear() {
        task?.cancel()
        suggestions = []
        highlighted = nil
    }

    func moveHighlight(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        guard let current = highlighted else {
            highlighted = offset > 0 ? 0 : suggestions.count - 1
            return
        }
        highlighted = min(max(current + offset, 0), suggestions.count - 1)
    }

    /// `text` with its last component replaced by the highlighted (or only, or
    /// first) suggestion, ending in a slash so the next level can be typed.
    func completion(of text: String) -> String? {
        guard !suggestions.isEmpty else { return nil }
        let chosen = suggestions[highlighted ?? 0]
        return Self.replacingLastComponent(of: text, with: chosen.name)
    }

    nonisolated static func replacingLastComponent(of text: String, with name: String) -> String {
        guard let slash = text.lastIndex(of: "/") else { return name + "/" }
        return String(text[...slash]) + name + "/"
    }
}

/// The suggestion list, drawn on the same glass as the field it belongs to.
struct PathSuggestionList: View {
    let suggestions: [RemoteEntry]
    let highlighted: Int?
    let onChoose: (RemoteEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                Button {
                    onChoose(entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: FileIcon.image(for: entry))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                    .background {
                        if index == highlighted {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .selectedContentBackgroundColor))
                        }
                    }
                    .foregroundStyle(index == highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
    }
}
