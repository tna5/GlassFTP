import Foundation

/// Naming and conflict rules shared by the transfer walks.
enum TransferPlanner {
    /// How far a resume backs off from the end of the partial file.
    ///
    /// Chunks are transferred out of order, so the bytes just below a partial
    /// file's end may include holes left by chunks still in flight when it
    /// stopped. At most `pipelineDepth` chunks are in flight, so the holes
    /// lie within `pipelineDepth × chunkSize` of the end; this covers the
    /// largest values Settings allows (64 × 64 KB), whatever they were when
    /// the partial file was written.
    static let resumeSafetyMargin: Int64 = 64 * 65_536

    /// Finder-style disambiguation so a second download does not silently
    /// clobber the first.
    static func uniqueURL(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for index in 2...999 {
            let candidate = directory
                .appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// The same rule for a remote folder, against the names already in it.
    static func uniqueName(for name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension

        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    // MARK: - Conflicts

    /// What is known about one side of a conflict.
    struct FileFacts: Equatable, Sendable {
        var size: Int64
        var modifiedAt: Date?
    }

    enum Resolution: Equatable, Sendable {
        /// Send the file, keeping the destination's first `resumeFrom` bytes.
        case transfer(resumeFrom: Int64)
        case rename
        case skip
    }

    /// Decides what to do with an existing destination. `action` must not be
    /// `.ask` — that is settled with the user first.
    static func resolve(_ action: FileExistsAction, source: FileFacts, destination: FileFacts) -> Resolution {
        switch action {
        case .ask, .overwrite:
            return .transfer(resumeFrom: 0)

        case .overwriteIfNewer:
            // SFTP v3 carries whole seconds, so anything within a second is
            // the same timestamp seen through a coarser clock.
            guard let sourceDate = source.modifiedAt, let destinationDate = destination.modifiedAt else {
                return .transfer(resumeFrom: 0)
            }
            return sourceDate.timeIntervalSince(destinationDate) > 1 ? .transfer(resumeFrom: 0) : .skip

        case .overwriteIfSizeDiffers:
            return source.size != destination.size ? .transfer(resumeFrom: 0) : .skip

        case .resume:
            if destination.size == source.size { return .skip }
            // A destination larger than the source is not a prefix of it.
            guard destination.size < source.size else { return .transfer(resumeFrom: 0) }
            return .transfer(resumeFrom: resumeOffset(forExisting: destination.size))

        case .rename:
            return .rename

        case .skip:
            return .skip
        }
    }

    static func resumeOffset(forExisting size: Int64) -> Int64 {
        max(0, size - resumeSafetyMargin)
    }
}
