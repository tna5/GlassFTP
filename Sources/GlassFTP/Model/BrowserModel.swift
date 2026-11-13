import Foundation
import Observation

/// One live connection plus everything the browser window shows for it.
@MainActor
@Observable
final class BrowserModel {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    let connection: Connection
    /// The browsing connection. Transfers run on `transferPool` instead, so a
    /// long download never sits in front of a folder listing.
    let provider: SFTPProvider
    let transferPool: TransferPool

    /// Settings snapshot, pushed in by `AppState` whenever they change.
    var settings: AppSettings {
        didSet {
            if settings.general != oldValue.general {
                sortedListingCache = [:]
                rebuildVisibleEntries()
            }
            if settings.connection.listingCacheBudget != oldValue.connection.listingCacheBudget {
                listingCache.setBudget(settings.connection.listingCacheBudget, pinning: currentPath)
            }
        }
    }

    /// The account's home directory, for `~` in Go to Folder.
    private(set) var homePath: String?
    /// Folders recently visited, most recent first, for Go to Folder.
    private(set) var recentPaths: [String] = []
    private static let recentLimit = 10

    /// The folder the user is rooted at. Navigation and the path bar stop here,
    /// so a connection scoped to one directory does not expose the tree above
    /// it. Empty means the whole server.
    let rootPath: String

    var status: Status = .disconnected
    var currentPath = "/"

    var entries: [RemoteEntry] = [] {
        didSet {
            entriesByIDCache = nil
            rebuildVisibleEntries()
        }
    }

    var selection: Set<RemoteEntry.ID> = [] {
        didSet { updateFocusedEntry() }
    }

    /// Sorts on `sortKey` with `.lexical`, not on `name` with the default
    /// `.localizedStandard`. The key already carries the case folding and the
    /// number padding; leaving the comparator on the locale path would run a
    /// full collation for each of the ~780,000 comparisons a 50,000-entry sort
    /// needs, which is where the seconds were going.
    var sortOrder: [KeyPathComparator<RemoteEntry>] = [
        KeyPathComparator(\RemoteEntry.sortKey, comparator: String.StandardComparator.lexical, order: .forward)
    ] {
        didSet { rebuildVisibleEntries() }
    }

    var searchText = "" {
        didSet { scheduleSearchRebuild() }
    }

    /// Entries after filtering and sorting.
    ///
    /// Stored rather than computed. As a computed property this was re-sorted
    /// on every read — and it is read several times per render pass, by the
    /// table, the path bubble, the overlays and the keyboard handlers. On a
    /// folder of fifty thousand files that alone cost seconds per frame.
    private(set) var visibleEntries: [RemoteEntry] = []

    /// Lets selection lookups skip a full scan of `entries`.
    ///
    /// Built on demand: browsing without selecting anything is common, and
    /// fifty thousand dictionary inserts per listing is a cost worth avoiding
    /// until something asks for it.
    private var entriesByIDCache: [RemoteEntry.ID: RemoteEntry]?

    private var entriesByID: [RemoteEntry.ID: RemoteEntry] {
        if let entriesByIDCache { return entriesByIDCache }
        var index = [RemoteEntry.ID: RemoteEntry](minimumCapacity: entries.count)
        for entry in entries { index[entry.id] = entry }
        entriesByIDCache = index
        return index
    }

    /// The query actually applied to `visibleEntries`, which trails
    /// `searchText` by the debounce interval.
    private var appliedQuery = ""
    private var searchDebounce: Task<Void, Never>?
    private var focusedEntryID: RemoteEntry.ID?
    private var entriesSignature = 0

    private static let searchDebounce = Duration.milliseconds(200)
    /// True only when there is nothing to show yet, so the big spinner does not
    /// replace a folder the user is already looking at.
    var isLoading = false
    /// True while a background revalidation is in flight behind cached content.
    var isRefreshing = false
    var error: ProviderError?

    /// Listings keyed by path.
    ///
    /// A single `listDirectory` costs several sequential round trips — realpath,
    /// opendir, one or more readdirs, close — so on anything but a LAN the wait
    /// is very visible. Cached folders render instantly and are revalidated
    /// behind the content.
    private var listingCache = ListingCache() {
        didSet { sortedListingCache = [:] }
    }
    private var sortedListingCache: [String: [RemoteEntry]] = [:]
    private var prefetching: Set<String> = []

    /// How many child folders to warm after a directory loads. Enough to cover
    /// a normal folder, small enough not to hammer the server on a tree with
    /// hundreds of subdirectories.
    private static let prefetchLimit = 24

    /// Above this many entries, warming the children is skipped entirely.
    /// Pre-listing two dozen folders that each hold tens of thousands of files
    /// would blow the memory budget and monopolise the connection, and someone
    /// in a folder that size is usually searching, not walking down.
    private static let prefetchSuppressionThreshold = 2_000
    /// Wait this long before warming children, so walking quickly through a
    /// deep path does not queue prefetches for every folder passed through.
    private static let prefetchDelay = Duration.milliseconds(250)

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var revalidateTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    init(
        connection: Connection,
        configuration: SFTPProvider.Configuration,
        settings: AppSettings,
        hostKeyConfirmation: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) {
        self.connection = connection
        self.settings = settings
        self.rootPath = connection.initialPath.isEmpty
            ? RemotePath.root
            : RemotePath.normalize(connection.initialPath)
        self.provider = SFTPProvider(configuration: configuration, confirmHostKey: hostKeyConfirmation)
        // Same credentials and proxy. By the time a transfer opens one of
        // these the host key is pinned, so they never prompt.
        self.transferPool = TransferPool(maxIdle: settings.transfers.clampedConcurrency + 1) {
            SFTPProvider(configuration: configuration, confirmHostKey: hostKeyConfirmation)
        }
        self.listingCache = ListingCache(budget: settings.connection.listingCacheBudget)
    }

    // MARK: - Derived state

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Going up stops at the root, so the button greys out there instead of
    /// silently doing nothing.
    var canGoUp: Bool {
        guard currentPath != rootPath else { return false }
        return RemotePath.parent(of: currentPath) != currentPath
    }

    /// Path-bar segments, trimmed to the root.
    var breadcrumbs: [(name: String, path: String)] {
        RemotePath.breadcrumbs(for: currentPath, relativeTo: rootPath)
    }

    var selectedEntries: [RemoteEntry] {
        // Keyed lookup rather than filtering every entry: the selection is
        // almost always one item, and scanning fifty thousand for it happened
        // inside view bodies.
        selection
            .compactMap { entriesByID[$0] }
            .sorted { $0.sortKey < $1.sortKey }
    }

    /// The entry the keyboard acts on.
    ///
    /// The anchor is wherever the last arrow press or single click left it, and
    /// it survives as long as it stays selected — so extending a selection does
    /// not teleport the cursor. When it is no longer selected the topmost
    /// visible selected item takes over, which beats following a `Set`'s
    /// arbitrary ordering.
    var focusedEntry: RemoteEntry? {
        if let focusedEntryID, let entry = entriesByID[focusedEntryID] { return entry }
        guard !selection.isEmpty else { return nil }
        return visibleEntries.first { selection.contains($0.id) }
    }

    // MARK: - Derived state maintenance

    /// Which column the table is sorted by, recovered from the comparator the
    /// `Table` handed back.
    ///
    /// The comparator drives the header UI; the sorting itself does not go
    /// through it. `KeyPathComparator.compare` is an existential call that
    /// evaluates a dynamic key path per comparison, which at ~780,000
    /// comparisons is its own bottleneck.
    private enum SortField {
        case name
        case size
        case kind
        case modified
    }

    private var activeSort: (field: SortField, ascending: Bool) {
        guard let first = sortOrder.first else { return (.name, true) }
        let ascending = first.order == .forward

        switch first.keyPath {
        case \RemoteEntry.size: return (.size, ascending)
        case \RemoteEntry.kindLabel: return (.kind, ascending)
        case \RemoteEntry.modifiedSortKey: return (.modified, ascending)
        default: return (.name, ascending)
        }
    }

    /// Directories are grouped first, whatever the sort column, unless turned
    /// off in Settings. A transfer client is a navigation tool before it is a file list, and
    /// hunting for a folder interleaved among a thousand files is miserable.
    ///
    /// Sorts an array of indices against flat key arrays rather than sorting
    /// the entries themselves. `RemoteEntry` carries five reference-counted
    /// strings, so moving one during a sort costs five retain/release pairs —
    /// on fifty thousand entries the ARC traffic dwarfs the comparisons.
    private func rebuildVisibleEntries() {
        let source = entries
        guard !source.isEmpty else {
            visibleEntries = []
            return
        }

        var indices: [Int]
        if appliedQuery.isEmpty {
            indices = Array(source.indices)
        } else {
            // Borrowed through a buffer for the same reason as the sort: going
            // through `source[i].searchKey` retains a string per entry.
            let needle = appliedQuery.lowercased()
            let searchKeys = source.map(\.searchKey)
            indices = searchKeys.withUnsafeBufferPointer { keys in
                (0..<keys.count).filter { keys[$0].contains(needle) }
            }
        }
        if !settings.general.showHiddenFiles {
            let hidden = source.map(\.isHidden)
            indices.removeAll { hidden[$0] }
        }

        let isDirectory = settings.general.foldersFirst
            ? source.map(\.isDirectory)
            : Array(repeating: false, count: source.count)
        let names = source.map(\.sortKey)
        let sort = activeSort

        switch sort.field {
        case .name:
            Self.order(&indices, foldersFirst: isDirectory, keys: names, tie: names, ascending: sort.ascending)
        case .kind:
            Self.order(&indices, foldersFirst: isDirectory, keys: source.map(\.kindLabel), tie: names, ascending: sort.ascending)
        case .size:
            Self.order(&indices, foldersFirst: isDirectory, keys: source.map(\.size), tie: names, ascending: sort.ascending)
        case .modified:
            // Seconds as a Double: no ARC on the key array at all, unlike Date.
            let stamps = source.map { $0.modifiedAt?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude }
            Self.order(&indices, foldersFirst: isDirectory, keys: stamps, tie: names, ascending: sort.ascending)
        }

        var result = [RemoteEntry]()
        result.reserveCapacity(indices.count)
        for index in indices { result.append(source[index]) }
        visibleEntries = result
    }

    /// Sorts `indices` in place. Every array is borrowed through an unsafe
    /// buffer so element access skips both bounds checks and retain/release.
    private static func order<Key: Comparable>(
        _ indices: inout [Int],
        foldersFirst: [Bool],
        keys: [Key],
        tie: [String],
        ascending: Bool
    ) {
        foldersFirst.withUnsafeBufferPointer { directories in
            keys.withUnsafeBufferPointer { key in
                tie.withUnsafeBufferPointer { tiebreak in
                    indices.sort { lhs, rhs in
                        if directories[lhs] != directories[rhs] { return directories[lhs] }
                        if key[lhs] != key[rhs] {
                            return ascending ? key[lhs] < key[rhs] : key[rhs] < key[lhs]
                        }
                        // Equal keys always fall back to name order, in the
                        // same direction, so the list never jitters.
                        return tiebreak[lhs] < tiebreak[rhs]
                    }
                }
            }
        }
    }

    /// Filtering runs over every entry, so it trails the keystrokes. Clearing
    /// the field is applied at once — waiting to see the folder come back would
    /// feel broken.
    private func scheduleSearchRebuild() {
        searchDebounce?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            appliedQuery = ""
            rebuildVisibleEntries()
            return
        }

        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.appliedQuery = query
            self.rebuildVisibleEntries()
        }
    }

    /// Applies the pending search at once instead of waiting out the debounce.
    ///
    /// Bound to the search field's submit action: someone who presses Return
    /// has finished typing and should not sit through the delay.
    func flushPendingSearch() {
        searchDebounce?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query != appliedQuery else { return }
        appliedQuery = query
        rebuildVisibleEntries()
    }

    /// Keeps the keyboard anchor on the single selected item without scanning.
    private func updateFocusedEntry() {
        if let focusedEntryID, selection.contains(focusedEntryID) { return }
        focusedEntryID = selection.count == 1 ? selection.first : nil
    }

    // MARK: - Keyboard selection    // MARK: - Keyboard selection

    /// Moves the selection `offset` positions through the visible order.
    /// Returns the newly selected entry so the view can scroll to it.
    @discardableResult
    func moveSelection(by offset: Int) -> RemoteEntry? {
        let items = visibleEntries
        guard !items.isEmpty else { return nil }

        guard let current = focusedEntry,
              let index = items.firstIndex(where: { $0.id == current.id })
        else {
            // Nothing selected yet: enter the list from whichever end the user
            // is heading towards.
            let entry = offset >= 0 ? items[0] : items[items.count - 1]
            focusedEntryID = entry.id
            selection = [entry.id]
            return entry
        }

        let next = min(max(index + offset, 0), items.count - 1)
        guard next != index else { return nil }
        focusedEntryID = items[next].id
        selection = [items[next].id]
        return items[next]
    }

    // MARK: - Lifecycle

    func connect(startingAt destination: String? = nil) async {
        guard status != .connecting, status != .connected else { return }
        status = .connecting
        error = nil

        do {
            try await provider.connect()
            // Ask the server where we start rather than assuming "/": the user
            // almost always wants their home directory, and many accounts are
            // chrooted somewhere else entirely. A shortcut overrides both.
            //
            // Written out rather than chained with `??` because that operator's
            // autoclosure cannot carry an `await`.
            homePath = try? await provider.realPath(".")
            let start: String
            if let destination {
                start = destination
            } else if !connection.initialPath.isEmpty {
                start = connection.initialPath
            } else {
                start = homePath ?? "/"
            }
            status = .connected
            await load(path: start, recordHistory: false)
        } catch let providerError as ProviderError {
            status = .failed(providerError.localizedDescription)
            error = providerError
        } catch {
            let translated = SFTPProvider.translate(error)
            status = .failed(translated.localizedDescription)
            self.error = translated
        }
    }

    func disconnect() async {
        revalidateTask?.cancel()
        prefetchTask?.cancel()
        await provider.disconnect()
        // Transfers already running finish on their own connections.
        await transferPool.retire()
        status = .disconnected
        entries = []
        selection = []
        backStack = []
        forwardStack = []
        listingCache.removeAll()
        revalidateTask?.cancel()
        prefetchTask?.cancel()
    }

    // MARK: - Navigation

    /// Descends into `entry`. Returns `false` when it turned out not to be a
    /// directory, so the caller can download it instead.
    ///
    /// A listing gives no clue what a symlink points at, so the only way to
    /// find out is to try — quietly, because a symlink to a file is perfectly
    /// normal and should not raise an error dialog.
    @discardableResult
    func open(_ entry: RemoteEntry) async -> Bool {
        switch entry.kind {
        case .directory:
            await load(path: entry.path)
            return true
        case .file:
            return false
        case .symlink:
            do {
                _ = try await provider.list(entry.path)
            } catch {
                return false
            }
            await load(path: entry.path)
            return true
        }
    }

    func navigate(to path: String) async {
        await load(path: path)
    }

    /// Resolves what was typed into Go to Folder or the path bar and goes
    /// there. Returns an error message to show next to the field instead of
    /// raising an alert, so the user can correct the path in place.
    ///
    /// A path to a file opens its folder with the file selected, as the
    /// Finder does.
    func goTo(_ input: String) async -> String? {
        guard let path = RemotePath.resolve(input, from: currentPath, home: homePath) else {
            return "Enter a path."
        }

        let canonical: String
        do {
            canonical = RemotePath.normalize(try await provider.realPath(path))
        } catch {
            return Self.message(for: error, path: path)
        }

        if canonical == currentPath { return nil }

        let attributes: RemoteEntry?
        do {
            attributes = try await provider.attributes(at: canonical)
        } catch {
            return Self.message(for: error, path: canonical)
        }
        guard let attributes else { return "The folder “\(path)” can’t be found." }

        // `load` reports failures through `error`, which raises an alert;
        // here the message belongs next to the field instead.
        if attributes.isDirectory {
            await load(path: canonical)
            if let failure = error {
                error = nil
                return Self.message(for: failure, path: canonical)
            }
            return nil
        }

        let parent = RemotePath.parent(of: canonical)
        await load(path: parent)
        if let failure = error {
            error = nil
            return Self.message(for: failure, path: parent)
        }
        if let entry = entries.first(where: { $0.path == canonical }) {
            selection = [entry.id]
        }
        return nil
    }

    private static func message(for error: Error, path: String) -> String {
        switch error as? ProviderError {
        case .noSuchFile:
            return "The folder “\(path)” can’t be found."
        case .permissionDenied:
            return "You don’t have permission to open “\(path)”."
        case let providerError?:
            return providerError.localizedDescription
        case nil:
            return SFTPProvider.translate(error, path: path).localizedDescription
        }
    }

    func goUp() async {
        guard canGoUp else { return }
        let leaving = currentPath
        await load(path: RemotePath.parent(of: currentPath))

        // Highlight the folder we just stepped out of, so left-then-right
        // returns where you were instead of dumping you at the top of the list.
        if let entry = entries.first(where: { $0.path == leaving }) {
            selection = [entry.id]
        }
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        await load(path: previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        await load(path: next, recordHistory: false)
    }

    func refresh() async {
        listingCache.remove(currentPath)
        await load(path: currentPath, recordHistory: false)
    }

    /// Warms the listing for a folder the user is about to open.
    ///
    /// Called on hover, which in practice fires well before the click and hides
    /// the whole round trip.
    func warm(_ entry: RemoteEntry) {
        guard settings.connection.warmOnHover else { return }
        guard entry.isDirectory, listingCache[entry.path] == nil else { return }
        Task { await prefetch(entry.path) }
    }

    // MARK: - Column view support

    func cachedListing(for path: String) -> [RemoteEntry]? {
        listingCache[RemotePath.normalize(path)]
    }

    /// Folders-first ordering for a column, memoised.
    ///
    /// The column view draws every ancestor at once and re-rendered on any
    /// state change, so this was re-sorting several folders per frame.
    func sortedListing(for path: String) -> [RemoteEntry] {
        let target = RemotePath.normalize(path)
        if let cached = sortedListingCache[target] { return cached }
        guard let listing = listingCache[target] else { return [] }

        var indices = Array(listing.indices)
        if !settings.general.showHiddenFiles {
            indices.removeAll { listing[$0].isHidden }
        }
        let names = listing.map(\.sortKey)
        Self.order(
            &indices,
            foldersFirst: settings.general.foldersFirst
                ? listing.map(\.isDirectory)
                : Array(repeating: false, count: listing.count),
            keys: names,
            tie: names,
            ascending: true
        )
        let sorted = indices.map { listing[$0] }
        sortedListingCache[target] = sorted
        return sorted
    }

    private func store(_ listing: [RemoteEntry], for path: String) {
        listingCache.store(listing, for: path, pinning: currentPath)
    }

    /// Cached contents of a folder, fetching them if this is the first look.
    func listing(for path: String) async -> [RemoteEntry] {
        if let cached = cachedListing(for: path) { return cached }
        await prefetch(path)
        return cachedListing(for: path) ?? []
    }

    /// Loads a listing into the cache without disturbing the current path.
    func prefetch(_ path: String) async {
        let target = RemotePath.normalize(path)
        guard listingCache[target] == nil, !prefetching.contains(target) else { return }
        prefetching.insert(target)
        defer { prefetching.remove(target) }

        // Failures are silent here: a parent folder we cannot list should leave
        // an empty column, not an error dialog on top of a working view.
        if let listed = try? await provider.list(target) {
            store(listed, for: target)
        } else {
            store([], for: target)
        }
    }

    /// Makes `column` the current folder and selects `ids` in it.
    ///
    /// The column view's single entry point for selection: a click, an arrow
    /// press in any column, and stepping back out all land here, so a folder
    /// picked with the mouse and one reached with the keyboard end up in the
    /// same state — the folder selected in its parent, previewed to the right.
    func select(_ ids: Set<RemoteEntry.ID>, inColumn column: String) async {
        let target = RemotePath.normalize(column)
        if target != currentPath {
            await navigate(to: target)
            // Navigation failed (permission, network): leave things alone.
            guard currentPath == target else { return }
        }
        selection = ids.filter { entriesByID[$0] != nil }
    }

    private func load(path: String, recordHistory: Bool = true) async {
        revalidateTask?.cancel()
        prefetchTask?.cancel()

        let target = RemotePath.normalize(path)
        let previousPath = currentPath
        error = nil

        if let cached = listingCache[target] {
            // Show the folder immediately and check the server behind it. This
            // is what makes back/forward and re-entering a folder feel instant.
            move(to: target, entries: cached, from: previousPath, recordHistory: recordHistory)
            revalidate(target)
            schedulePrefetch(for: target, entries: cached)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let listed = try await provider.list(target)
            store(listed, for: target)
            move(to: target, entries: listed, from: previousPath, recordHistory: recordHistory)
            schedulePrefetch(for: target, entries: listed)
        } catch let providerError as ProviderError {
            // Stay where we are on failure — dropping the user into an empty
            // view for a folder they cannot read loses their place.
            error = providerError
        } catch {
            self.error = SFTPProvider.translate(error, path: target)
        }
    }

    private func move(
        to target: String,
        entries newEntries: [RemoteEntry],
        from previousPath: String,
        recordHistory: Bool
    ) {
        if recordHistory, target != previousPath {
            backStack.append(previousPath)
            forwardStack.removeAll()
        }
        currentPath = target
        entries = newEntries
        entriesSignature = Self.signature(of: newEntries)
        selection = []

        recentPaths.removeAll { $0 == target }
        recentPaths.insert(target, at: 0)
        if recentPaths.count > Self.recentLimit { recentPaths.removeLast() }
    }

    /// Cheap fingerprint of a listing: enough to notice a file appearing,
    /// disappearing, growing or being touched.
    private static func signature(of entries: [RemoteEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.name)
            hasher.combine(entry.size)
            hasher.combine(entry.modifiedAt)
        }
        return hasher.finalize()
    }

    /// Re-lists a folder we served from cache and swaps the result in if it
    /// changed and the user is still there.
    private func revalidate(_ target: String) {
        isRefreshing = true
        revalidateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }

            guard let listed = try? await self.provider.list(target) else { return }
            guard !Task.isCancelled else { return }

            self.store(listed, for: target)
            // The user may have moved on while this was in flight.
            guard self.currentPath == target else { return }

            // Compare a cheap signature rather than the arrays themselves.
            // Swapping in an identical listing would cost a full re-sort for
            // nothing, and structural equality over fifty thousand entries is
            // itself not free.
            let signature = Self.signature(of: listed)
            guard signature != self.entriesSignature else { return }

            let keep = self.selection
            self.entries = listed
            self.entriesSignature = signature
            self.selection = keep.intersection(Set(listed.map(\.id)))
        }
    }

    /// Warms the child folders of `target` so the next step down is instant.
    ///
    /// Cancelled on every navigation: the provider is an actor and serializes
    /// its requests, so leaving stale prefetches queued would put the user's
    /// own click behind them.
    private func schedulePrefetch(for target: String, entries: [RemoteEntry]) {
        guard settings.connection.prefetchChildFolders else { return }
        guard entries.count <= Self.prefetchSuppressionThreshold else { return }
        guard !listingCache.isOverBudget else { return }

        let children = entries
            .filter { $0.isDirectory && listingCache[$0.path] == nil }
            .prefix(Self.prefetchLimit)
        guard !children.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prefetchDelay)
            guard !Task.isCancelled, let self else { return }

            for child in children {
                guard !Task.isCancelled, self.currentPath == target else { return }
                await self.prefetch(child.path)
            }
        }
    }

    // MARK: - File operations

    func createDirectory(named name: String) async {
        let path = RemotePath.join(currentPath, name)
        await mutate { try await self.provider.makeDirectory(at: path) }
    }

    func rename(_ entry: RemoteEntry, to newName: String) async {
        let destination = RemotePath.join(RemotePath.parent(of: entry.path), newName)
        await mutate { try await self.provider.rename(from: entry.path, to: destination) }
    }

    /// True when dropping `paths` on `directory` would actually do something:
    /// not into one of the dragged folders (or below it), and not all of them
    /// already living there.
    static func canMove(_ paths: [String], into directory: String) -> Bool {
        let destination = RemotePath.normalize(directory)
        guard !paths.isEmpty else { return false }
        let sources = paths.map(RemotePath.normalize)
        if sources.contains(where: { RemotePath.isDescendant(destination, of: $0) }) { return false }
        return sources.contains { RemotePath.parent(of: $0) != destination }
    }

    /// Moves items to another folder on the same server with a server-side
    /// rename — no bytes travel, whatever the size.
    ///
    /// Never overwrites: SFTP servers disagree on whether rename replaces an
    /// existing target (OpenSSH's posix-rename does, silently), so a name that
    /// is already taken is checked first and reported instead.
    func move(_ paths: [String], into directory: String) async {
        let destination = RemotePath.normalize(directory)
        var moved: [(from: String, to: String)] = []
        var failures: [String] = []

        for source in paths.map(RemotePath.normalize) {
            let name = RemotePath.lastComponent(of: source)
            guard RemotePath.parent(of: source) != destination else { continue }
            guard !RemotePath.isDescendant(destination, of: source) else {
                failures.append("“\(name)” can’t be moved into itself.")
                continue
            }
            let target = RemotePath.join(destination, name)
            do {
                if try await provider.attributes(at: target) != nil {
                    failures.append("An item named “\(name)” already exists in “\(RemotePath.lastComponent(of: destination))”.")
                    continue
                }
                try await provider.rename(from: source, to: target)
                moved.append((source, target))
            } catch {
                let translated = (error as? ProviderError) ?? SFTPProvider.translate(error, path: source)
                failures.append("“\(name)”: \(translated.localizedDescription)")
            }
        }

        await applyMoves(moved, into: destination)

        if !failures.isEmpty {
            let header = moved.isEmpty ? "Nothing was moved." : "Some items could not be moved."
            error = .operationFailed(([header] + failures).joined(separator: "\n"))
        }
    }

    /// Brings every cached view of the tree in line with completed moves.
    ///
    /// The column view shows several folders at once, so refreshing only the
    /// current one would leave a moved file visible in its old column.
    private func applyMoves(_ moved: [(from: String, to: String)], into destination: String) async {
        guard !moved.isEmpty else { return }

        // Anything cached under a moved folder now lives at a different path.
        for path in listingCache.cachedPaths
        where moved.contains(where: { RemotePath.isDescendant(path, of: $0.from) }) {
            listingCache.remove(path)
        }

        // If the folder on screen was itself moved (an ancestor dragged away in
        // the column view), follow it to its new home.
        var newCurrent = currentPath
        if let move = moved.first(where: { RemotePath.isDescendant(currentPath, of: $0.from) }) {
            newCurrent = move.to + String(currentPath.dropFirst(move.from.count))
        }

        let touched = Set(moved.map { RemotePath.parent(of: $0.from) } + [destination])
        let visible = Set(RemotePath.breadcrumbs(for: newCurrent, relativeTo: rootPath).map {
            RemotePath.normalize($0.path)
        })
        for folder in touched {
            let wasCached = listingCache[folder] != nil
            listingCache.remove(folder)
            // Re-list folders the user can see or will come back to; the rest
            // fetch fresh the next time they are opened.
            if folder != newCurrent, wasCached || visible.contains(folder) {
                await prefetch(folder)
            }
        }

        let keepSelection = newCurrent == currentPath
            ? selection.subtracting(moved.map(\.from))
            : []
        await load(path: newCurrent, recordHistory: false)
        // Selecting what just arrived is how the Finder confirms a drop.
        let arrived = Set(moved.map(\.to)).filter { RemotePath.parent(of: $0) == currentPath }
        selection = arrived.isEmpty ? keepSelection.filter { entriesByID[$0] != nil } : arrived.filter { entriesByID[$0] != nil }
    }

    func delete(_ entries: [RemoteEntry]) async {
        await mutate {
            for entry in entries {
                try await self.provider.remove(entry)
            }
        }
    }

    func setPermissions(_ mode: UInt16, on entry: RemoteEntry) async {
        await mutate { try await self.provider.setPermissions(mode, at: entry.path) }
    }

    /// Runs a mutation and refreshes, surfacing any failure in `error`.
    private func mutate(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            await refresh()
        } catch let providerError as ProviderError {
            error = providerError
        } catch {
            self.error = SFTPProvider.translate(error)
        }
    }
}
