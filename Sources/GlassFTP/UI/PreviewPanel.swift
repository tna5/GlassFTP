import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Space-bar preview, after Quick Look: a glass panel sized to what it shows,
/// a title bar with the name and the facts that matter for that kind of file,
/// and the content edge to edge.
///
/// It follows the selection: arrowing through a folder with the panel open
/// swaps the file in place, keeping the previous one on screen until the next
/// has loaded so the panel does not flash a spinner on every press.
///
/// The file lives on a server, so previewing means fetching it. Two rules keep
/// that honest: nothing is fetched for a kind we cannot render — an archive or
/// a disk image shows its details instead — and what we do fetch is capped, so
/// a large text file previews its head rather than refusing outright.
struct PreviewPanel: View {
    let entry: RemoteEntry
    let provider: SFTPProvider
    /// Folder contents, served from the browser's cache when it has them.
    let listing: (String) async -> [RemoteEntry]
    let onDownload: (RemoteEntry) -> Void
    let onClose: () -> Void

    /// Generous for a document, small enough that a stray space bar on a disk
    /// image costs nothing.
    private static let byteLimit = 16 * 1024 * 1024

    /// Text is capped far lower than binary content, and deliberately close to
    /// the 32 KB SFTP packet size: two round trips, roughly a thousand lines.
    private static let textLimit = 64 * 1024

    @State private var phase: Phase = .loading
    /// The entry `phase` belongs to. Differs from `entry` while the next one
    /// loads, which is when the old content stays up, dimmed.
    @State private var shownID: RemoteEntry.ID?

    /// Not named `State`: that shadows the property wrapper and the compiler
    /// stops recognising `@State` entirely.
    private enum Phase {
        case loading
        case folder([RemoteEntry])
        case image(NSImage, partial: Bool)
        case pdf(PDFDocument)
        case text([Substring], truncated: Bool)
        case info(reason: String?)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.35)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(shownID == entry.id ? 1 : 0.55)
                .clipped()
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .animation(.smooth(duration: 0.25), value: panelSize)
        .task(id: entry.id) { await load() }
    }

    // MARK: - Size

    /// Each kind gets the shape that suits it; an image takes its own aspect
    /// ratio, within bounds.
    private var panelSize: CGSize {
        let titleHeight: CGFloat = 58
        switch phase {
        case .loading:
            return CGSize(width: 460, height: 340)
        case .image(let image, _):
            let maxSize = CGSize(width: 900, height: 620)
            let natural = image.size
            let scale = min(1, maxSize.width / max(natural.width, 1), maxSize.height / max(natural.height, 1))
            let width = max(420, natural.width * scale)
            let height = max(260, natural.height * scale)
            return CGSize(width: width, height: height + titleHeight)
        case .pdf, .text:
            return CGSize(width: 800, height: 600)
        case .folder:
            return CGSize(width: 560, height: 480)
        case .info, .failed:
            return CGSize(width: 440, height: 440)
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        ZStack {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.image(for: entry, size: 16))
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                    if let note = truncationNote {
                        Text(note)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 110)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Close (Space)")

                Spacer()

                if entry.kind != .directory {
                    Button {
                        onClose()
                        onDownload(entry)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .help("Download to your Mac")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    /// The facts worth a glance for this kind of file.
    private var subtitle: String {
        var parts = [entry.kindLabel]
        switch phase {
        case .folder(let entries) where shownID == entry.id:
            parts.append(entries.count == 1 ? "1 item" : "\(entries.count.formatted()) items")
        case .image(let image, _) where shownID == entry.id:
            if let rep = image.representations.first, rep.pixelsWide > 0 {
                parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
            }
            parts.append(entry.displaySize)
        case .pdf(let document) where shownID == entry.id:
            parts.append(document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages")
            parts.append(entry.displaySize)
        case .text(let lines, _) where shownID == entry.id:
            parts.append("\(lines.count.formatted()) lines")
            parts.append(entry.displaySize)
        default:
            if entry.kind != .directory { parts.append(entry.displaySize) }
        }
        parts.append(entry.displayModified)
        return parts.joined(separator: " · ")
    }

    /// Says plainly that what is on screen is not the whole file.
    private var truncationNote: String? {
        guard shownID == entry.id else { return nil }
        switch phase {
        case .text(_, true): return "FIRST \(Self.textLimit / 1024) KB"
        case .image(_, true): return "PARTIAL"
        default: return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.large)

        case .folder(let entries):
            FolderPreview(entries: entries)

        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()

        case .pdf(let document):
            PDFPreview(document: document)

        case .text(let lines, _):
            TextPreview(lines: lines)

        case .info(let reason):
            infoCard(note: reason)

        case .failed(let reason):
            infoCard(note: reason, isError: true)
        }
    }

    /// For anything we do not render: the big icon and the details, as
    /// Quick Look shows for a file it cannot open.
    private func infoCard(note: String?, isError: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(nsImage: FileIcon.image(for: entry, size: 112))
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

            if let note {
                Label(note, systemImage: isError ? "exclamationmark.triangle.fill" : "eye.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
            }

            EntryInfoRows(entry: entry)
                .frame(maxWidth: 320)
        }
        .padding(24)
    }

    // MARK: - Loading

    private var contentType: UTType? {
        let ext = entry.fileExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    private func load() async {
        let target = entry

        // Keep the previous file up while the next one loads; only a slow
        // load earns a spinner.
        let spinner = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            phase = .loading
            shownID = target.id
        }
        defer { spinner.cancel() }

        let next = await fetch(target)
        guard !Task.isCancelled else { return }
        spinner.cancel()
        phase = next
        shownID = target.id
    }

    private func fetch(_ entry: RemoteEntry) async -> Phase {
        guard entry.kind != .directory else {
            return .folder(await listing(entry.path))
        }
        guard let type = contentType else {
            return .info(reason: "No preview for this kind of file")
        }

        let textual = isTextual(type)
        let isImage = type.conforms(to: .image)
        let isPDF = type.conforms(to: .pdf)

        guard textual || isImage || isPDF else {
            // Archives, disk images, media: nothing to render, so nothing is
            // fetched. This is the case the size cap must never override.
            return .info(reason: nil)
        }

        // A truncated PDF has no cross-reference table at its end, so it will
        // never open. Reading 16 MB to prove that would waste the transfer.
        guard !isPDF || entry.size <= Int64(Self.byteLimit) else {
            return .info(reason: "Too large to preview")
        }

        let limit = textual ? Self.textLimit : Self.byteLimit
        let isTruncated = entry.size > Int64(limit)

        do {
            let data = try await provider.read(entry.path, maxBytes: limit)
            if isImage {
                // Many formats decode the leading rows of a truncated file,
                // which is a real preview; the ones that cannot say so.
                if let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                    return .image(image, partial: isTruncated)
                }
                return .info(reason: "Too large to preview")
            }
            if isPDF {
                if let document = PDFDocument(data: data) { return .pdf(document) }
                return .info(reason: "This PDF could not be opened")
            }
            // Lossy on purpose: a file that is mostly text but carries a
            // stray byte should still be readable.
            let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            // A cut-off last line is noise.
            if isTruncated, lines.count > 1 { lines.removeLast() }
            return .text(lines, truncated: isTruncated)
        } catch is CancellationError {
            return .loading
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `.text` alone misses a lot: many source and config formats declare
    /// themselves as data or as their own type without inheriting from text.
    private func isTextual(_ type: UTType) -> Bool {
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
        if type == .json || type == .xml || type == .yaml || type == .propertyList { return true }
        return ["env", "lock", "gitignore", "dockerfile", "toml", "ini", "conf", "cfg", "log"]
            .contains(entry.fileExtension)
    }
}

/// Monospaced text with a line-number gutter.
///
/// AppKit's text view rather than SwiftUI: a two-axis SwiftUI scroll view
/// over lazily built rows changed its content width as rows came and went,
/// which made sideways scrolling lurch and could stop vertical scrolling
/// short. A text view scrolls natively, selects across lines, and never wraps.
private struct TextPreview: NSViewRepresentable {
    let lines: [Substring]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 6, height: 10)
        // No wrapping: long lines scroll sideways, as in an editor.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView)
    }

    private func update(_ textView: NSTextView) {
        let text = lines.joined(separator: "\n")
        guard textView.string != text else { return }
        textView.string = text
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.scroll(.zero)
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

/// Line numbers beside a text view, drawn for the visible lines only.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentChanged),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func contentChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString

        // Widen the gutter for long files.
        let digits = max(3, String(text.length == 0 ? 1 : text.components(separatedBy: "\n").count).count)
        let thickness = CGFloat(digits) * 7.5 + 16
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Number of the first visible line: count the newlines before it.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        var index = characters.location
        let origin = convert(NSPoint.zero, from: textView)
        let inset = textView.textContainerInset.height
        while index <= NSMaxRange(characters), index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(layoutManager.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = origin.y + lineRect.minY + inset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
            if index >= text.length { break }
        }
    }
}

/// PDFKit's view, which handles paging and scrolling for us.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// A folder's contents, listed compactly.
private struct FolderPreview: View {
    let entries: [RemoteEntry]

    /// Folders first, matching every other list in the app.
    private var sorted: [RemoteEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.sortKey < rhs.sortKey
        }
    }

    private var summary: String {
        let folders = entries.filter(\.isDirectory).count
        let files = entries.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 10) {
                Image(nsImage: FileIcon.folder(size: 96))
                    .frame(width: 96, height: 96)
                Text("Empty Folder")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Image(nsImage: FileIcon.image(for: entry, size: Theme.rowIconSize))
                                    .frame(width: Theme.rowIconSize, height: Theme.rowIconSize)
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(entry.isDirectory ? "" : entry.displaySize)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background {
                                // Zebra rows, as in a Finder list.
                                if index.isMultiple(of: 2) {
                                    RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }
}

/// Label–value rows describing an entry, shared by the preview panel and the
/// column view's preview column.
struct EntryInfoRows: View {
    let entry: RemoteEntry

    private var rows: [(String, String)] {
        var result: [(String, String)] = [("Kind", entry.kindLabel)]
        if entry.kind != .directory {
            let exact = entry.size.formatted(.number)
            result.append(("Size", "\(entry.displaySize) (\(exact) bytes)"))
        }
        result.append(("Modified", entry.displayModified))
        if entry.permissions != nil {
            result.append(("Permissions", "\(entry.displayPermissions) (\(entry.octalPermissions))"))
        }
        result.append(("Where", RemotePath.parent(of: entry.path)))
        return result
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(value)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11))
    }
}
