import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What one column shows, computed by `FileColumnView` from the model.
struct ColumnState: Equatable {
    let path: String
    let entries: [RemoteEntry]
    /// Rows drawn as selected: the real selection in the current folder, the
    /// next step of the trail in an ancestor.
    let selection: Set<RemoteEntry.ID>
}

/// Everything the column browser needs from the rest of the app.
@MainActor
struct ColumnBrowserCallbacks {
    let actions: BrowserActions
    /// Selects `ids` in the column at `path`, making it the current folder.
    let select: (Set<RemoteEntry.ID>, String) -> Void
    /// Replaces the selection of the current folder synchronously.
    let setSelection: (Set<RemoteEntry.ID>) -> Void
    /// Enters a folder and lands on its first item.
    let descend: (RemoteEntry) -> Void
    /// Downloads an entry to a temporary file, for a drag to the Finder.
    let materialize: (RemoteEntry) async throws -> URL
    /// A picture of an image file for the preview column, when small enough.
    let thumbnail: (RemoteEntry) async -> NSImage?
}

/// The Finder's column view, in AppKit.
///
/// One `NSTableView` per column inside a horizontal scroll view. The tables do
/// what they do natively — the rounded inset selection, blue in the focused
/// column and grey in the others, up/down, shift/command extension, type
/// select, multi-row drags and drop-on-row — and this class only translates
/// their events into model calls. Left and right are the one thing a table does
/// not do, and are handled per column.
@MainActor
final class ColumnBrowserView: NSView {
    static let minimumWidth: CGFloat = 140
    static let maximumWidth: CGFloat = 700
    static let previewMinimumWidth: CGFloat = 280
    private static let widthKey = "columnWidth"

    /// The width new columns open at. Changed by Option-dragging a divider,
    /// which resizes every column, as in the Finder.
    static var defaultWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            return stored > 0 ? stored : 240
        }
        set { UserDefaults.standard.set(newValue, forKey: widthKey) }
    }

    var callbacks: ColumnBrowserCallbacks?

    private let scrollView = NSScrollView()
    private let strip = FlippedView()
    private var columns: [ColumnController] = []
    private var handles: [ColumnResizeHandle] = []
    private var handleOwners: [ObjectIdentifier] = []
    private var previewHost: NSHostingView<AnyView>?
    private var previewID: RemoteEntry.ID?
    private var currentPath = ""
    private var hasAppeared = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Rubber-band only when there is somewhere to scroll to; with the
        // columns fitting, a sideways swipe should do nothing at all.
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = strip
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutStrip()
    }

    // MARK: - Updates from SwiftUI

    func update(columns states: [ColumnState], currentPath: String, preview: RemoteEntry?) {
        let pathChanged = currentPath != self.currentPath
        let previousCount = columns.count + (previewHost == nil ? 0 : 1)
        self.currentPath = currentPath

        // Reuse columns by path, so a column that stays keeps its scroll
        // position and its table keeps first responder.
        var reused: [String: ColumnController] = [:]
        for column in columns { reused[column.path] = column }
        var next: [ColumnController] = []
        for state in states {
            let column = reused.removeValue(forKey: state.path) ?? makeColumn(path: state.path)
            column.apply(state, isCurrent: state.path == currentPath)
            next.append(column)
        }
        for stale in reused.values { stale.container.removeFromSuperview() }
        columns = next

        updatePreview(preview)
        rebuildHandles()
        layoutStrip()

        let firstUpdate = !hasAppeared
        hasAppeared = true
        if pathChanged || firstUpdate {
            focusCurrentColumn(force: firstUpdate)
        }
        if pathChanged || firstUpdate || previousCount != columns.count + (previewHost == nil ? 0 : 1) {
            revealLastColumn()
        }
    }

    private func makeColumn(path: String) -> ColumnController {
        let column = ColumnController(path: path, browser: self)
        column.width = Self.defaultWidth
        strip.addSubview(column.container)
        return column
    }

    private func updatePreview(_ entry: RemoteEntry?) {
        guard entry?.id != previewID else { return }
        previewID = entry?.id
        previewHost?.removeFromSuperview()
        previewHost = nil
        guard let entry else { return }
        let actions = callbacks?.actions
        let thumbnail = callbacks?.thumbnail
        let host = NSHostingView(rootView: AnyView(FilePreviewColumn(
            entry: entry,
            thumbnail: { await thumbnail?($0) },
            onQuickLook: { actions?.togglePreview($0) },
            onDownload: { actions?.download([$0]) }
        )))
        strip.addSubview(host)
        previewHost = host
    }

    private func layoutStrip() {
        let height = scrollView.contentView.bounds.height
        let visibleWidth = scrollView.contentView.bounds.width
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let frame = NSRect(x: x, y: 0, width: column.width, height: height)
            if column.container.frame != frame {
                column.container.frame = frame
                column.fitTable()
            }
            x += column.width
            if handles.indices.contains(index) {
                // Straddles the boundary so it is easy to grab from either side.
                handles[index].frame = NSRect(x: x - 4, y: 0, width: 8, height: height)
            }
        }
        if let previewHost {
            // The preview takes whatever is left, so it sits centred in the
            // remaining space instead of in a fixed strip.
            let width = max(Self.previewMinimumWidth, visibleWidth - x)
            previewHost.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(x, visibleWidth), height: height)
    }

    /// One divider per column, kept above every column in the z-order.
    private func rebuildHandles() {
        // Only when the set of columns changed: this runs on every update,
        // including each arrow press.
        let owners = columns.map(ObjectIdentifier.init)
        guard owners != handleOwners else {
            for handle in handles { strip.addSubview(handle, positioned: .above, relativeTo: nil) }
            return
        }
        handleOwners = owners
        for handle in handles { handle.removeFromSuperview() }
        handles = columns.map { column in
            let handle = ColumnResizeHandle()
            var startWidths: [ObjectIdentifier: CGFloat] = [:]
            handle.onBegin = { [weak self] in
                guard let self else { return }
                startWidths = Dictionary(uniqueKeysWithValues: self.columns.map { (ObjectIdentifier($0), $0.width) })
            }
            handle.onDrag = { [weak self, weak column] delta, allColumns in
                guard let self, let column else { return }
                let clamp = { (value: CGFloat) in min(max(value, Self.minimumWidth), Self.maximumWidth) }
                if allColumns {
                    let width = clamp((startWidths[ObjectIdentifier(column)] ?? column.width) + delta)
                    for each in self.columns { each.width = width }
                    Self.defaultWidth = width
                } else {
                    column.width = clamp((startWidths[ObjectIdentifier(column)] ?? column.width) + delta)
                }
                self.layoutStrip()
            }
            handle.onDoubleClick = { [weak self, weak column] in
                // Fit the column to its longest name.
                guard let self, let column else { return }
                column.width = min(max(column.fittingWidth, Self.minimumWidth), Self.maximumWidth)
                self.layoutStrip()
            }
            strip.addSubview(handle)
            return handle
        }
    }

    private func revealLastColumn() {
        let target = previewHost?.frame ?? columns.last?.container.frame
        guard let target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            strip.scrollToVisible(target)
        }
    }

    /// Hands the keyboard to the current folder's column — but only when the
    /// keyboard is already somewhere in the browser, so typing in the search
    /// or path field is never interrupted.
    private func focusCurrentColumn(force: Bool) {
        guard let window, let column = columns.first(where: { $0.path == currentPath }) else { return }
        let responder = window.firstResponder
        let ownsFocus = force
            || responder === window
            || responder == nil
            || columns.contains { $0.table === responder }
        if ownsFocus {
            window.makeFirstResponder(column.table)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  let column = self.columns.first(where: { $0.path == self.currentPath })
            else { return }
            window.makeFirstResponder(column.table)
        }
    }

    // MARK: - Events from the columns

    fileprivate func userChangedSelection(in column: ColumnController, to ids: Set<RemoteEntry.ID>) {
        guard let callbacks else { return }
        if column.path == currentPath {
            callbacks.setSelection(ids)
        } else {
            callbacks.select(ids, column.path)
        }
    }

    fileprivate func moveRight(from column: ColumnController) {
        guard let callbacks else { return }
        let selected = column.selectedEntries
        if selected.isEmpty {
            guard let first = column.entries.first else { return }
            callbacks.select([first.id], column.path)
            return
        }
        guard selected.count == 1, let entry = selected.first, entry.kind != .file else { return }
        callbacks.descend(entry)
    }

    fileprivate func moveLeft(from column: ColumnController) {
        guard let callbacks, let first = columns.first, column !== first else { return }
        let parent = RemotePath.parent(of: column.path)
        callbacks.select([column.path], parent)
    }

    fileprivate func open(_ entry: RemoteEntry) {
        callbacks?.actions.open(entry)
    }

    fileprivate func preview(_ entry: RemoteEntry) {
        callbacks?.actions.togglePreview(entry)
    }

    fileprivate func springLoad(_ entry: RemoteEntry, in column: ColumnController) {
        callbacks?.select([entry.id], column.path)
    }
}

// MARK: - One column

@MainActor
private final class ColumnController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let path: String
    let container = NSView()
    let table = ColumnTableView()
    private let scrollView = ColumnScrollView()
    private weak var browser: ColumnBrowserView?
    var width: CGFloat = 240

    private(set) var entries: [RemoteEntry] = []
    private var selection: Set<RemoteEntry.ID> = []
    /// Set while the selection is changed from the model, so the table's
    /// change notification is not mistaken for a click.
    private var isSyncing = false

    private var springTimer: Timer?
    private var springRow = -1

    private static let rowHeight: CGFloat = 22
    private static let cellID = NSUserInterfaceItemIdentifier("ColumnCell")

    init(path: String, browser: ColumnBrowserView) {
        self.path = path
        self.browser = browser
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        column.width = 240
        column.maxWidth = 10_000
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        // The single column always matches the visible width: a table even a
        // few points wider than its column scrolled sideways under a swipe and
        // slid the chevrons out of view.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.column = self
        table.registerForDraggedTypes([.glassftpRemoteItems, .fileURL])
        table.setDraggingSourceOperationMask([.move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // The divider is drawn by the resize handle over this last point.
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
        ])
    }

    /// Brings the table's width back to the column's after a resize.
    func fitTable() {
        container.layoutSubtreeIfNeeded()
        table.sizeLastColumnToFit()
    }

    /// Wide enough for the longest name, with icon, chevron and insets.
    var fittingWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // A long folder is capped: measuring fifty thousand names to fit one
        // column is not worth the pause.
        let widest = entries.prefix(5_000).reduce(CGFloat(0)) { widest, entry in
            max(widest, (entry.name as NSString).size(withAttributes: attributes).width)
        }
        return ceil(widest) + Theme.rowIconSize + 6 + 8 + 14 + 32
    }

    func apply(_ state: ColumnState, isCurrent: Bool) {
        if state.entries != entries {
            entries = state.entries
            isSyncing = true
            table.reloadData()
            isSyncing = false
            selection = []
        }
        selection = state.selection
        guard selectedIDsInTable != state.selection else { return }
        let rows = IndexSet(entries.indices.filter { state.selection.contains(entries[$0].id) })
        isSyncing = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncing = false
        if let first = rows.first {
            table.scrollRowToVisible(first)
        }
    }

    private var selectedIDsInTable: Set<RemoteEntry.ID> {
        Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
    }

    var selectedEntries: [RemoteEntry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ColumnCell) ?? {
            let cell = ColumnCell()
            cell.identifier = Self.cellID
            return cell
        }()
        cell.configure(with: entries[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        let ids = selectedIDsInTable
        selection = ids
        browser?.userChangedSelection(in: self, to: ids)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        browser?.open(entries[row])
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.specialKey {
        case .rightArrow:
            browser?.moveRight(from: self)
            return true
        case .leftArrow:
            browser?.moveLeft(from: self)
            return true
        case .downArrow where command:
            openSelection()
            return true
        case .upArrow where command:
            browser?.moveLeft(from: self)
            return true
        case .carriageReturn, .enter:
            openSelection()
            return true
        default:
            break
        }
        if event.charactersIgnoringModifiers == " ", let entry = selectedEntries.first, selectedEntries.count == 1 {
            browser?.preview(entry)
            return true
        }
        return false
    }

    private func openSelection() {
        let selected = selectedEntries
        guard selected.count == 1, let entry = selected.first else { return }
        browser?.open(entry)
    }

    // MARK: Drag source

    /// Dragging a selected row drags every selected row, which the table does
    /// by asking for a writer per row.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let browser, let callbacks = browser.callbacks, entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: entry.fileExtension) ?? .data)
        let provider = RemoteFilePromiseProvider(fileType: type.identifier, delegate: PromiseDelegate.shared)
        provider.entry = entry
        provider.materialize = callbacks.materialize
        provider.connectionID = callbacks.actions.connectionID
        return provider
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let callbacks = browser?.callbacks else { return }
        let paths = rowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].path : nil }
        // Recorded once for the whole drag: drop targets read the full list
        // from here rather than from each row's pasteboard item.
        RemoteDragSession.current = RemoteDragPayload(connectionID: callbacks.actions.connectionID, paths: paths)
    }

    // MARK: Drop target

    /// Where a drop at `row` would land: on a folder row, that folder;
    /// anywhere else, this column's own folder.
    private func destination(for row: Int, operation: NSTableView.DropOperation) -> (path: String, row: Int) {
        if operation == .on, entries.indices.contains(row), entries[row].isDirectory {
            return (entries[row].path, row)
        }
        return (path, -1)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let target = destination(for: row, operation: dropOperation)
        tableView.setDropRow(target.row, dropOperation: .on)
        scheduleSpring(row: target.row)

        let pasteboard = info.draggingPasteboard
        if pasteboard.availableType(from: [.glassftpRemoteItems]) != nil {
            guard let payload = RemoteDragSession.current,
                  payload.connectionID == browser?.callbacks?.actions.connectionID,
                  BrowserModel.canMove(payload.paths, into: target.path)
            else { return [] }
            return .move
        }
        if pasteboard.availableType(from: [.fileURL]) != nil {
            return .copy
        }
        return []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        cancelSpring()
        guard let actions = browser?.callbacks?.actions else { return false }
        let target = destination(for: row, operation: dropOperation).path
        let pasteboard = info.draggingPasteboard

        if pasteboard.availableType(from: [.glassftpRemoteItems]) != nil {
            guard let payload = RemoteDragSession.current,
                  BrowserModel.canMove(payload.paths, into: target)
            else { return false }
            RemoteDragSession.current = nil
            actions.move(payload.paths, target)
            return true
        }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        actions.uploadInto(urls, target)
        return true
    }

    func draggingExited() { cancelSpring() }

    /// Hovering a folder during a drag opens it in the next column, as the
    /// Finder's spring-loaded folders do.
    private func scheduleSpring(row: Int) {
        guard row != springRow else { return }
        cancelSpring()
        springRow = row
        guard entries.indices.contains(row), entries[row].isDirectory else { return }
        let entry = entries[row]
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let browser = self.browser else { return }
                browser.springLoad(entry, in: self)
            }
        }
    }

    private func cancelSpring() {
        springTimer?.invalidate()
        springTimer = nil
        springRow = -1
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let actions = browser?.callbacks?.actions else { return }

        let clicked = table.clickedRow
        let targets: [RemoteEntry]
        if entries.indices.contains(clicked) {
            // Right-clicking outside the selection acts on the clicked row
            // alone, as in the Finder.
            targets = table.selectedRowIndexes.contains(clicked) ? selectedEntries : [entries[clicked]]
        } else {
            targets = []
        }

        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let handler = MenuAction(action)
            item.target = handler
            item.representedObject = handler
            item.isEnabled = enabled
            menu.addItem(item)
        }

        guard !targets.isEmpty else {
            add("New Folder") { actions.newFolder() }
            add("Upload…") { actions.upload() }
            menu.addItem(.separator())
            add("Refresh") { actions.refresh() }
            return
        }

        let single = targets.count == 1 ? targets.first : nil
        if let entry = single, entry.kind != .file {
            add("Open") { actions.open(entry) }
            menu.addItem(.separator())
        }
        add(targets.count == 1 ? "Download" : "Download \(targets.count) Items") { actions.download(targets) }
        if let entry = single, entry.isDirectory {
            add("Add to Shortcuts", enabled: actions.canAddShortcut(entry)) { actions.addShortcut(entry) }
        }
        menu.addItem(.separator())
        if let entry = single {
            add("Quick Look") { actions.togglePreview(entry) }
            add("Rename…") { actions.rename(entry) }
            add("Get Info") { actions.getInfo(entry) }
        }
        add("Copy Path") { actions.copyPath(targets) }
        menu.addItem(.separator())
        add("Delete") { actions.delete(targets) }
    }
}

/// A target for a context-menu item, kept alive by the item itself.
private final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

// MARK: - Table and cell

/// Adds the horizontal half of the Finder's keyboard model to a table.
private final class ColumnTableView: NSTableView {
    weak var column: ColumnController?

    override func keyDown(with event: NSEvent) {
        if column?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        column?.draggingExited()
    }

    /// A click on empty space below the rows clears the selection, which
    /// closes the columns to the right — the Finder's behaviour.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) < 0 {
            window?.makeFirstResponder(self)
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Icon, name and — for folders — a chevron, at the Finder's density.
private final class ColumnCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor

        addSubview(icon)
        addSubview(label)
        addSubview(chevron)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.rowIconSize),
            icon.heightAnchor.constraint(equalToConstant: Theme.rowIconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: RemoteEntry) {
        icon.image = FileIcon.image(for: entry, size: Theme.rowIconSize)
        label.stringValue = entry.name
        chevron.isHidden = !entry.isDirectory
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// White on the blue selection, as the label does on its own.
    private func updateColors() {
        chevron.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
    }
}

/// A column's scroll view: vertical only.
///
/// A sideways swipe belongs to the strip of columns, not to whichever column
/// happens to be under the pointer, so horizontal gestures are handed up the
/// responder chain to the outer scroll view. The decision is made once per
/// gesture — at its start — and kept through its momentum, so a swipe never
/// switches owner halfway.
private final class ColumnScrollView: NSScrollView {
    private var forwardsGesture = false
    private var hasDecided = false

    override func scrollWheel(with event: NSEvent) {
        let isDiscrete = event.phase.isEmpty && event.momentumPhase.isEmpty
        if isDiscrete || event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            hasDecided = false
        }
        // The first events of a swipe often carry no movement; decide on the
        // first one that does.
        let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
        if !hasDecided, dx > 0 || dy > 0 {
            forwardsGesture = dx > dy
            hasDecided = true
        }
        if forwardsGesture {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Top-left origin, so columns lay out from the top like a list.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Drag to the Finder

/// A row on the pasteboard: a file promise for the Finder, plus our own type
/// so a drop inside the app moves instead of copying.
private final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    var entry: RemoteEntry?
    var connectionID: UUID?
    var materialize: ((RemoteEntry) async throws -> URL)?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        types.append(NSPasteboard.PasteboardType(UTType.glassftpRemoteItems.identifier))
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == UTType.glassftpRemoteItems.identifier {
            guard let entry, let connectionID else { return nil }
            return try? JSONEncoder().encode(RemoteDragPayload(connectionID: connectionID, paths: [entry.path]))
        }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type.rawValue == UTType.glassftpRemoteItems.identifier { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// Fulfils promises by downloading to a temporary file, then moving it to
/// where the Finder asked.
private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = PromiseDelegate()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? RemoteFilePromiseProvider)?.entry?.name ?? "Untitled"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let remote = provider as? RemoteFilePromiseProvider,
              let entry = remote.entry,
              let materialize = remote.materialize
        else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let done = UncheckedSendable(completionHandler)
        Task { @MainActor in
            do {
                let local = try await materialize(entry)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: local, to: url)
                done.value(nil)
            } catch {
                done.value(error)
            }
        }
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - SwiftUI bridge

struct ColumnBrowserRepresentable: NSViewRepresentable {
    let columns: [ColumnState]
    let currentPath: String
    let preview: RemoteEntry?
    let callbacks: ColumnBrowserCallbacks

    func makeNSView(context: Context) -> ColumnBrowserView {
        ColumnBrowserView(frame: .zero)
    }

    func updateNSView(_ view: ColumnBrowserView, context: Context) {
        view.callbacks = callbacks
        view.update(columns: columns, currentPath: currentPath, preview: preview)
    }
}

/// The divider between two columns, and the grip that resizes the one on its
/// left. Drag to resize, Option-drag to resize every column, double-click to
/// fit the column to its longest name — the Finder's three gestures.
@MainActor
private final class ColumnResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()

        // The Finder's grip: two short bars at the foot of the divider.
        NSColor.tertiaryLabelColor.setFill()
        let gripHeight: CGFloat = 10
        let y = bounds.height - gripHeight - 6
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 2.5, y: y, width: 1, height: gripHeight), xRadius: 0.5, yRadius: 0.5).fill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX + 1.5, y: y, width: 1, height: gripHeight), xRadius: 0.5, yRadius: 0.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        onBegin?()
        let start = event.locationInWindow.x
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let allColumns = next.modifierFlags.contains(.option)
            onDrag?(next.locationInWindow.x - start, allColumns)
        }
    }
}

/// The trailing column the Finder shows when a file is selected: a large
/// preview — the picture itself for images — then the name, and the details.
struct FilePreviewColumn: View {
    let entry: RemoteEntry
    let thumbnail: (RemoteEntry) async -> NSImage?
    let onQuickLook: (RemoteEntry) -> Void
    let onDownload: (RemoteEntry) -> Void

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    artwork
                        .frame(maxWidth: min(geometry.size.width - 48, 260), maxHeight: 200)

                    VStack(spacing: 3) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Text("\(entry.kindLabel) – \(entry.displaySize)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Information")
                            .font(.system(size: 11, weight: .semibold))
                        Divider()
                        EntryInfoRows(entry: entry)
                    }
                    .frame(maxWidth: 300)

                    HStack(spacing: 8) {
                        Button("Quick Look") { onQuickLook(entry) }
                            .buttonStyle(.glass)
                        Button {
                            onDownload(entry)
                        } label: {
                            Label("Download", systemImage: "arrow.down")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                }
                .padding(24)
                // Centred in both directions while it fits, scrolling when the
                // window is too short for it.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .task(id: entry.id) {
            image = nil
            // Arrowing past an image should not download it.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let loaded = await thumbnail(entry)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .transition(.opacity)
        } else {
            Image(nsImage: FileIcon.image(for: entry, size: 128))
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let glassftpRemoteItems = NSPasteboard.PasteboardType(UTType.glassftpRemoteItems.identifier)
}
