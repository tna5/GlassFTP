import Foundation
import Observation

/// One thing the user asked for: a file, or a whole folder.
///
/// A folder is deliberately *not* expanded into one row per file. At the scale
/// this app is used on that would mean tens of thousands of observable objects
/// and rows for a single drag, so a job keeps aggregate counters and names only
/// the files currently moving.
@MainActor
@Observable
final class TransferJob: Identifiable {
    enum Direction: Sendable {
        case download
        case upload
    }

    enum State: Equatable {
        case waiting
        /// Still walking the tree; the totals are not final yet.
        case discovering
        case running
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool { self == .waiting || self == .discovering || self == .running }
    }

    /// A file being transferred right now.
    struct InFlight: Equatable {
        var name: String
        var bytes: Int64
        var size: Int64
    }

    let id = UUID()
    let direction: Direction
    let title: String

    var state: State = .waiting
    var filesTotal = 0
    var filesCompleted = 0
    var filesFailed = 0
    var filesSkipped = 0
    var bytesTotal: Int64 = 0
    /// Bytes from files already finished.
    var bytesCompleted: Int64 = 0
    var inFlight: [UUID: InFlight] = [:]
    /// The most recent per-file failure, shown when only one file failed.
    var lastError: String?
    /// Smoothed over the last few seconds; zero when nothing is moving.
    private(set) var bytesPerSecond: Double = 0

    // Bookkeeping owned by `TransferManager`.
    fileprivate var isWalking = true
    fileprivate var walkError: String?
    fileprivate var queuedCount = 0
    fileprivate var walkTask: Task<Void, Never>?
    fileprivate var fileTasks: [UUID: Task<Void, Never>] = [:]
    /// Set by "Apply to all" in the conflict sheet.
    fileprivate var conflictAnswer: FileExistsAction?
    fileprivate var onFinish: (@MainActor () -> Void)?
    fileprivate var onCancel: (@MainActor (TransferJob) -> Void)?

    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []
    private static let speedWindow = Duration.seconds(3)

    init(direction: Direction, title: String) {
        self.direction = direction
        self.title = title
    }

    var bytesTransferred: Int64 {
        bytesCompleted + inFlight.values.reduce(0) { $0 + $1.bytes }
    }

    /// `nil` while the size is still unknown, so the bar can be indeterminate
    /// rather than pinned at zero.
    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, Double(bytesTransferred) / Double(bytesTotal))
    }

    /// Totals grow while the tree is still being walked, so they are shown as
    /// provisional rather than as a finished count.
    var isCountProvisional: Bool { state.isActive && isWalking }

    /// Names of the files moving now, in a stable order.
    var currentFileNames: [String] {
        inFlight.values.map(\.name).sorted()
    }

    var estimatedSecondsRemaining: Double? {
        guard bytesPerSecond > 0, bytesTotal > 0, !isWalking else { return nil }
        return Double(max(bytesTotal - bytesTransferred, 0)) / bytesPerSecond
    }

    func cancel() {
        walkTask?.cancel()
        fileTasks.values.forEach { $0.cancel() }
        if state.isActive {
            state = .cancelled
            bytesPerSecond = 0
            onCancel?(self)
        }
    }

    fileprivate func recordSample() {
        let now = ContinuousClock.now
        samples.append((now, bytesTransferred))
        samples.removeAll { now - $0.time > Self.speedWindow }
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return }
        let elapsed = (last.time - first.time).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard seconds > 0.25 else { return }
        bytesPerSecond = max(0, Double(last.bytes - first.bytes) / seconds)
    }

    fileprivate func resetSpeed() {
        samples = []
        bytesPerSecond = 0
    }
}

/// The transfer queue behind the floating transfers panel.
///
/// Work is scheduled per *file*, across every job: up to `maxConcurrent` files
/// move at once, each over its own pooled SSH connection, and each of those is
/// itself pipelined in chunks. A folder of ten thousand small files therefore
/// keeps several connections busy instead of paying every file's round trips
/// one after another, and two separate downloads run side by side.
@MainActor
@Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    let conflicts = ConflictPrompter()

    /// Snapshot of Settings › Transfers. Raising the concurrency takes effect
    /// immediately; lowering it lets running files finish.
    var options = AppSettings.Transfers() {
        didSet { pump() }
    }

    /// FIFO across all jobs. Consumed from `head` and compacted now and then,
    /// because `removeFirst` on fifty thousand items is quadratic.
    private var pending: [WorkItem] = []
    private var head = 0
    private var running = 0

    /// Guards against symlink loops on the server, which would otherwise make
    /// a walk run forever.
    private static let maximumDepth = 32

    fileprivate struct WorkItem {
        enum Kind {
            case download(RemoteEntry, into: URL)
            case upload(URL, facts: TransferPlanner.FileFacts, into: String, siblings: RemoteFolderIndex?)
        }

        let id = UUID()
        let job: TransferJob
        let pool: TransferPool
        let kind: Kind
        /// Forces a policy regardless of Settings, e.g. drag-out into a fresh
        /// temporary folder must never ask.
        let policy: FileExistsAction?
    }

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    var hasTransfers: Bool { !jobs.isEmpty }

    /// Combined progress of everything still running, for the collapsed pill.
    var overallFraction: Double? {
        let active = jobs.filter { $0.state.isActive && $0.bytesTotal > 0 }
        guard !active.isEmpty else { return nil }
        let done = active.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        let total = active.reduce(Int64(0)) { $0 + $1.bytesTotal }
        guard total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    var overallBytesPerSecond: Double {
        jobs.filter { $0.state.isActive }.reduce(0) { $0 + $1.bytesPerSecond }
    }

    var filesInFlight: Int { running }

    // MARK: - Public API

    @discardableResult
    func download(
        _ entries: [RemoteEntry],
        to directory: URL,
        pool: TransferPool,
        policy: FileExistsAction? = nil
    ) -> TransferJob {
        let job = makeJob(direction: .download, title: Self.title(for: entries.map(\.name)))
        let maximumDepth = Self.maximumDepth
        job.walkTask = Task.detached { [weak self] in
            guard let manager = self else { return }
            await manager.walk {
                for entry in entries {
                    try await Self.walkDownload(
                        entry: entry,
                        into: directory,
                        depth: 0,
                        maximumDepth: maximumDepth,
                        pool: pool
                    ) { batch in
                        await manager.enqueue(batch.map { .download($0.0, into: $0.1) }, job: job, pool: pool, policy: policy)
                    }
                }
            } finished: { error in
                manager.walkEnded(job, error: error)
            }
        }
        return job
    }

    func upload(
        _ urls: [URL],
        to remoteDirectory: String,
        pool: TransferPool,
        onFinish: (@MainActor () -> Void)? = nil
    ) {
        let job = makeJob(direction: .upload, title: Self.title(for: urls.map(\.lastPathComponent)))
        job.onFinish = onFinish

        let maximumDepth = Self.maximumDepth
        let includeHidden = options.uploadHiddenFiles
        // Listing destinations only matters when existing files change what
        // happens; a blind overwrite can skip those round trips.
        let needsListing = options.whenUploadExists != .overwrite

        job.walkTask = Task.detached { [weak self] in
            guard let manager = self else { return }
            await manager.walk {
                try await Self.walkUpload(
                    urls: urls,
                    into: remoteDirectory,
                    depth: 0,
                    maximumDepth: maximumDepth,
                    includeHidden: includeHidden,
                    needsListing: needsListing,
                    directoryIsNew: false,
                    pool: pool
                ) { batch in
                    await manager.enqueue(
                        batch.map { .upload($0.url, facts: $0.facts, into: $0.directory, siblings: $0.siblings) },
                        job: job,
                        pool: pool,
                        policy: nil
                    )
                }
            } finished: { error in
                manager.walkEnded(job, error: error)
            }
        }
    }

    /// Downloads one entry into a temporary directory and returns its local
    /// URL. Used by drag-and-drop to the Finder, which needs a real file.
    func materialize(_ entry: RemoteEntry, pool: TransferPool) async throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GlassFTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let job = download([entry], to: directory, pool: pool, policy: .overwrite)
        while job.state.isActive {
            try await Task.sleep(for: .milliseconds(80))
        }
        switch job.state {
        case .failed(let message): throw ProviderError.operationFailed(message)
        case .cancelled: throw ProviderError.cancelled
        default: return directory.appendingPathComponent(entry.name)
        }
    }

    func remove(_ job: TransferJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    func cancelAll() {
        jobs.forEach { $0.cancel() }
    }

    // MARK: - Queue

    private static func title(for names: [String]) -> String {
        guard names.count != 1 else { return names[0] }
        return "\(names.count) items"
    }

    private func makeJob(direction: TransferJob.Direction, title: String) -> TransferJob {
        let job = TransferJob(direction: direction, title: title)
        job.state = .discovering
        job.onCancel = { [weak self] job in
            self?.conflicts.dismiss(jobID: job.id)
            self?.pump()
        }
        jobs.append(job)
        return job
    }

    /// Runs a walk off the main actor — it creates directories and lists
    /// folders, and on a tree of tens of thousands of files those syscalls
    /// would otherwise run on the thread drawing the window.
    nonisolated private func walk(
        _ body: @Sendable () async throws -> Void,
        finished: @escaping @MainActor @Sendable (String?) -> Void
    ) async {
        var message: String?
        do {
            try await body()
        } catch is CancellationError {
        } catch let error as ProviderError {
            if case .cancelled = error {} else { message = error.localizedDescription }
        } catch {
            message = error.localizedDescription
        }
        let result = message
        await MainActor.run { finished(result) }
    }

    private func enqueue(
        _ kinds: [WorkItem.Kind],
        job: TransferJob,
        pool: TransferPool,
        policy: FileExistsAction?
    ) {
        guard job.state.isActive, !kinds.isEmpty else { return }
        for kind in kinds {
            pending.append(WorkItem(job: job, pool: pool, kind: kind, policy: policy))
            job.filesTotal += 1
            switch kind {
            case .download(let entry, _): job.bytesTotal += entry.size
            case .upload(_, let facts, _, _): job.bytesTotal += facts.size
            }
        }
        job.queuedCount += kinds.count
        pump()
    }

    private func walkEnded(_ job: TransferJob, error: String?) {
        job.isWalking = false
        job.walkError = error
        job.walkTask = nil
        settle(job)
    }

    private func nextItem() -> WorkItem? {
        while head < pending.count {
            let item = pending[head]
            head += 1
            if head > 4_096, head * 2 > pending.count {
                pending.removeFirst(head)
                head = 0
            }
            item.job.queuedCount -= 1
            if item.job.state.isActive { return item }
            // A cancelled job's leftovers are simply dropped.
            settle(item.job)
        }
        return nil
    }

    private func pump() {
        while running < options.clampedConcurrency, let item = nextItem() {
            running += 1
            let job = item.job
            if job.state == .discovering || job.state == .waiting { job.state = .running }

            job.fileTasks[item.id] = Task { [weak self] in
                await self?.process(item)
                guard let self else { return }
                self.running -= 1
                job.fileTasks[item.id] = nil
                job.inFlight[item.id] = nil
                self.settle(job)
                self.pump()
            }
        }
    }

    /// Moves a job to its final state once nothing is left for it.
    private func settle(_ job: TransferJob) {
        if job.inFlight.isEmpty, job.state == .running, job.queuedCount == 0, job.isWalking {
            job.state = .discovering
        }
        guard !job.isWalking, job.queuedCount == 0, job.fileTasks.isEmpty else { return }

        let finish = job.onFinish
        job.onFinish = nil
        job.resetSpeed()

        guard job.state.isActive else {
            finish?()
            return
        }

        if job.filesFailed > 0 {
            if job.filesFailed == 1, job.filesTotal == 1, let message = job.lastError {
                job.state = .failed(message)
            } else {
                job.state = .failed(job.filesFailed == 1 ? "1 file failed" : "\(job.filesFailed) files failed")
            }
        } else if let walkError = job.walkError {
            // Part of the tree could not be listed: whatever was found went
            // through, but the job must not claim to be complete.
            job.state = .failed(job.filesCompleted == 0 ? walkError : "Incomplete — \(walkError)")
        } else {
            job.state = .finished
            job.bytesCompleted = max(job.bytesCompleted, job.bytesTotal)
        }
        finish?()
    }

    // MARK: - One file

    private func process(_ item: WorkItem) async {
        switch item.kind {
        case .download(let entry, let directory):
            await processDownload(item, entry: entry, directory: directory)
        case .upload(let url, let facts, let directory, let siblings):
            await processUpload(item, url: url, facts: facts, directory: directory, siblings: siblings)
        }
    }

    private func processDownload(_ item: WorkItem, entry: RemoteEntry, directory: URL) async {
        let job = item.job
        var target = directory.appendingPathComponent(entry.name)
        var offset: Int64 = 0
        let source = TransferPlanner.FileFacts(size: entry.size, modifiedAt: entry.modifiedAt)

        if let existing = Self.localFacts(at: target) {
            let action = await decide(
                item,
                default: options.whenDownloadExists,
                name: entry.name,
                destination: target.deletingLastPathComponent().path,
                source: source,
                existing: existing
            )
            guard let action, job.state.isActive else { return }
            switch TransferPlanner.resolve(action, source: source, destination: existing) {
            case .skip:
                skip(entry.size, in: job)
                return
            case .rename:
                target = TransferPlanner.uniqueURL(for: target)
            case .transfer(let resumeFrom):
                offset = resumeFrom
            }
        }

        let destination = target
        let keepPartial = options.keepPartialDownloads
        let preserveTime = options.preserveModificationTime
        let id = item.id
        job.inFlight[id] = .init(name: entry.name, bytes: offset, size: entry.size)

        let succeeded = await withRetries(item) { provider, attempt in
            if attempt > 0, let partial = Self.localFacts(at: destination) {
                offset = TransferPlanner.resumeOffset(forExisting: min(partial.size, entry.size))
            }
            let throttle = ProgressThrottle()
            // Partial files are always kept between attempts so a retry can
            // resume; the setting only decides what is left after giving up.
            try await provider.download(
                from: entry.path,
                to: destination,
                resumingAt: offset,
                keepPartial: true,
                progress: Self.progressHandler(job: job, id: id, throttle: throttle)
            )
        }

        if succeeded {
            if preserveTime, let date = entry.modifiedAt {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            }
            complete(entry.size, in: job)
        } else if !keepPartial {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    private func processUpload(
        _ item: WorkItem,
        url: URL,
        facts: TransferPlanner.FileFacts,
        directory: String,
        siblings: RemoteFolderIndex?
    ) async {
        let job = item.job
        let name = url.lastPathComponent
        var remotePath = RemotePath.join(directory, name)
        var offset: Int64 = 0

        if let existing = siblings?.entries[name], !existing.isDirectory {
            let existingFacts = TransferPlanner.FileFacts(size: existing.size, modifiedAt: existing.modifiedAt)
            let action = await decide(
                item,
                default: options.whenUploadExists,
                name: name,
                destination: directory,
                source: facts,
                existing: existingFacts
            )
            guard let action, job.state.isActive else { return }
            switch TransferPlanner.resolve(action, source: facts, destination: existingFacts) {
            case .skip:
                skip(facts.size, in: job)
                return
            case .rename:
                let taken = Set(siblings.map { Array($0.entries.keys) } ?? [])
                remotePath = RemotePath.join(directory, TransferPlanner.uniqueName(for: name, taken: taken))
            case .transfer(let resumeFrom):
                offset = resumeFrom
            }
        }

        let destination = remotePath
        let preserveTime = options.preserveModificationTime
        let id = item.id
        job.inFlight[id] = .init(name: name, bytes: offset, size: facts.size)

        let succeeded = await withRetries(item) { provider, attempt in
            if attempt > 0, let partial = try? await provider.attributes(at: destination) {
                offset = TransferPlanner.resumeOffset(forExisting: min(partial.size, facts.size))
            }
            let throttle = ProgressThrottle()
            try await provider.upload(
                from: url,
                to: destination,
                resumingAt: offset,
                progress: Self.progressHandler(job: job, id: id, throttle: throttle)
            )
            if preserveTime, let date = facts.modifiedAt {
                // Not every server allows setting times; the file is there
                // either way, so this must not fail the upload.
                try? await provider.setModificationTime(date, at: destination)
            }
        }

        if succeeded { complete(facts.size, in: job) }
    }

    /// Settles a conflict: the job's remembered answer, the forced policy, the
    /// setting, or — for "Ask" — the user. `nil` means the job went away while
    /// waiting.
    private func decide(
        _ item: WorkItem,
        default setting: FileExistsAction,
        name: String,
        destination: String,
        source: TransferPlanner.FileFacts,
        existing: TransferPlanner.FileFacts
    ) async -> FileExistsAction? {
        let job = item.job
        let action = job.conflictAnswer ?? item.policy ?? setting
        guard action == .ask else { return action }

        let answer = await conflicts.ask(TransferConflict(
            jobID: job.id,
            direction: job.direction,
            name: name,
            destination: destination,
            source: source,
            existing: existing
        ))
        guard job.state.isActive else { return nil }
        if answer.applyToAll { job.conflictAnswer = answer.action }
        return answer.action
    }

    /// Runs one file transfer on a pooled connection, retrying per Settings.
    ///
    /// Retries reconnect: the connection that failed is discarded, since a
    /// dropped link is the usual cause and reusing the dead session would
    /// just fail again.
    private func withRetries(
        _ item: WorkItem,
        _ operation: (SFTPProvider, Int) async throws -> Void
    ) async -> Bool {
        let job = item.job
        let retries = min(max(options.retries, 0), AppSettings.Transfers.retryRange.upperBound)
        let delay = Duration.seconds(max(options.retryDelaySeconds, 0))

        for attempt in 0...retries {
            guard job.state.isActive, !Task.isCancelled else { return false }
            do {
                let provider = try await item.pool.checkout()
                do {
                    try await operation(provider, attempt)
                    await item.pool.checkin(provider)
                    return true
                } catch {
                    await item.pool.checkin(provider, healthy: await provider.isConnected)
                    throw error
                }
            } catch {
                if Self.isCancellation(error) || !job.state.isActive { return false }
                if attempt < retries, Self.isRetryable(error) {
                    try? await Task.sleep(for: delay)
                    continue
                }
                job.filesFailed += 1
                job.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return false
    }

    private func complete(_ size: Int64, in job: TransferJob) {
        job.bytesCompleted += size
        job.filesCompleted += 1
        job.recordSample()
    }

    private func skip(_ size: Int64, in job: TransferJob) {
        job.filesSkipped += 1
        // Skipped bytes leave the total so the bar still reaches the end.
        job.bytesTotal -= size
    }

    // MARK: - Helpers

    nonisolated private static func progressHandler(
        job: TransferJob,
        id: UUID,
        throttle: ProgressThrottle
    ) -> ProgressHandler {
        { transferred, total in
            guard throttle.shouldReport(transferred, total: total) else { return }
            Task { @MainActor in
                guard job.inFlight[id] != nil else { return }
                job.inFlight[id]?.bytes = transferred
                job.recordSample()
            }
        }
    }

    nonisolated private static func localFacts(at url: URL) -> TransferPlanner.FileFacts? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeDirectory
        else { return nil }
        return TransferPlanner.FileFacts(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled = error as? ProviderError { return true }
        return false
    }

    /// Errors that a second attempt can plausibly fix. A missing file or a
    /// permission problem will be just as missing next time.
    private static func isRetryable(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .permissionDenied, .noSuchFile, .alreadyExists, .authenticationFailed,
             .hostKeyRejected, .hostKeyChanged:
            return false
        default:
            return true
        }
    }

    // MARK: - Walks

    /// Walks a remote tree, creating local folders and handing files over in
    /// batches — one per folder, so a folder of fifty thousand files is one
    /// hop to the main actor rather than fifty thousand.
    nonisolated private static func walkDownload(
        entry: RemoteEntry,
        into directory: URL,
        depth: Int,
        maximumDepth: Int,
        pool: TransferPool,
        emit: ([(RemoteEntry, URL)]) async -> Void
    ) async throws {
        try Task.checkCancellation()

        guard entry.isDirectory else {
            await emit([(entry, directory)])
            return
        }
        guard depth < maximumDepth else { return }

        let destination = directory.appendingPathComponent(entry.name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let provider = try await pool.checkout()
        let children: [RemoteEntry]
        do {
            children = try await provider.list(entry.path)
            await pool.checkin(provider)
        } catch {
            await pool.checkin(provider, healthy: await provider.isConnected)
            throw error
        }

        let files = children.filter { !$0.isDirectory }
        if !files.isEmpty {
            await emit(files.map { ($0, destination) })
        }
        for child in children where child.isDirectory {
            try await walkDownload(
                entry: child,
                into: destination,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                pool: pool,
                emit: emit
            )
        }
    }

    fileprivate struct UploadFile {
        let url: URL
        let facts: TransferPlanner.FileFacts
        let directory: String
        let siblings: RemoteFolderIndex?
    }

    nonisolated private static func walkUpload(
        urls: [URL],
        into remoteDirectory: String,
        depth: Int,
        maximumDepth: Int,
        includeHidden: Bool,
        needsListing: Bool,
        directoryIsNew: Bool,
        pool: TransferPool,
        emit: ([UploadFile]) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let manager = FileManager.default

        // What is already in the destination, listed once for the whole
        // folder instead of one stat per file. A folder this walk just
        // created is empty by definition.
        var siblings: RemoteFolderIndex?
        if needsListing, !directoryIsNew {
            let provider = try await pool.checkout()
            let listing = try? await provider.list(remoteDirectory)
            await pool.checkin(provider, healthy: await provider.isConnected)
            siblings = RemoteFolderIndex(listing ?? [])
        }

        var files: [UploadFile] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folders.append(url)
            } else {
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let facts = TransferPlanner.FileFacts(
                    size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                    modifiedAt: attributes?[.modificationDate] as? Date
                )
                files.append(UploadFile(url: url, facts: facts, directory: remoteDirectory, siblings: siblings))
            }
        }
        if !files.isEmpty { await emit(files) }

        guard depth < maximumDepth else { return }
        for folder in folders {
            try Task.checkCancellation()
            let remotePath = RemotePath.join(remoteDirectory, folder.lastPathComponent)

            let provider = try await pool.checkout()
            var created = true
            do {
                try await provider.makeDirectory(at: remotePath)
            } catch {
                // "Already exists" is normal when re-uploading into a tree.
                created = false
            }
            await pool.checkin(provider, healthy: await provider.isConnected)

            let children = try manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            try await walkUpload(
                urls: children,
                into: remotePath,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                includeHidden: includeHidden,
                needsListing: needsListing,
                directoryIsNew: created,
                pool: pool,
                emit: emit
            )
        }
    }
}

/// A remote folder's entries by name, shared by every file uploaded into it.
final class RemoteFolderIndex: Sendable {
    let entries: [String: RemoteEntry]

    init(_ listing: [RemoteEntry]) {
        var entries = [String: RemoteEntry](minimumCapacity: listing.count)
        for entry in listing { entries[entry.name] = entry }
        self.entries = entries
    }
}

/// Rate-limits progress callbacks to something a screen can show.
///
/// Also serialises them: pipeline workers report from several tasks at once and
/// their byte counts can arrive out of order, so a stale smaller value must not
/// be allowed to overwrite a newer one.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = ContinuousClock.now
    private var lastValue: Int64 = 0
    private var hasReported = false

    private static let interval = Duration.milliseconds(100)

    func shouldReport(_ transferred: Int64, total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard transferred > lastValue else { return false }

        let now = ContinuousClock.now
        let isComplete = total > 0 && transferred >= total
        guard !hasReported || isComplete || now - lastReport >= Self.interval else { return false }

        lastReport = now
        lastValue = transferred
        hasReported = true
        return true
    }
}
