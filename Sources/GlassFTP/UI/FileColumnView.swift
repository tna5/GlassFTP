import SwiftUI
import UniformTypeIdentifiers

/// Finder's Column view.
///
/// The drawing and the event handling live in AppKit (`ColumnBrowserView`):
/// one native table per column is what gives the Finder's look and, more to
/// the point, its behaviour — clicks, arrows, multi-selection and drags all
/// work the way the system's own lists do.
///
/// This view only derives the columns from the model: one per breadcrumb of
/// the current folder, plus one previewing the selected folder. Every change
/// goes back through `BrowserModel.select(_:inColumn:)`, so a click and an
/// arrow press leave the browser in the same state.
struct FileColumnView: View {
    @Bindable var model: BrowserModel
    let actions: BrowserActions
    let dragPromise: (RemoteEntry) -> FilePromise

    /// Navigation started from the columns, chained so that fast presses
    /// apply in order instead of each acting on a folder about to change.
    @State private var queue = NavigationQueue()
    @State private var thumbnails = ThumbnailCache()

    private var trail: [String] {
        model.breadcrumbs.map { RemotePath.normalize($0.path) }
    }

    private var singleSelection: RemoteEntry? {
        guard model.selection.count == 1 else { return nil }
        return model.selectedEntries.first
    }

    private var columns: [ColumnState] {
        let chain = trail
        var result = chain.enumerated().map { index, path in
            let selection: Set<RemoteEntry.ID> = path == model.currentPath
                ? model.selection
                : (index + 1 < chain.count ? [chain[index + 1]] : [])
            return ColumnState(path: path, entries: model.sortedListing(for: path), selection: selection)
        }
        if let directory = singleSelection, directory.isDirectory {
            let path = RemotePath.normalize(directory.path)
            result.append(ColumnState(path: path, entries: model.sortedListing(for: path), selection: []))
        }
        return result
    }

    var body: some View {
        ColumnBrowserRepresentable(
            columns: columns,
            currentPath: model.currentPath,
            preview: singleSelection.flatMap { $0.isDirectory ? nil : $0 },
            callbacks: callbacks
        )
        .task(id: model.currentPath) {
            // Ancestors are usually cached from walking down, but a shortcut
            // can drop us deep into a tree we have never listed.
            for path in trail {
                await model.prefetch(path)
            }
        }
        .task(id: singleSelection?.path) {
            guard let entry = singleSelection, entry.isDirectory else { return }
            await model.prefetch(entry.path)
        }
    }

    private var callbacks: ColumnBrowserCallbacks {
        let model = model
        let queue = queue
        let dragPromise = dragPromise
        let thumbnails = thumbnails
        return ColumnBrowserCallbacks(
            actions: actions,
            select: { ids, column in
                queue.run { await model.select(ids, inColumn: column) }
            },
            setSelection: { ids in model.selection = ids },
            descend: { entry in
                queue.run {
                    guard await model.open(entry) else { return }
                    let current = model.currentPath
                    await model.prefetch(current)
                    if let first = model.sortedListing(for: current).first {
                        model.selection = [first.id]
                    }
                }
            },
            materialize: { entry in
                let promise = dragPromise(entry)
                return try await promise.transfers.materialize(entry, pool: promise.pool)
            },
            thumbnail: { entry in
                await thumbnails.image(for: entry, provider: model.provider)
            }
        )
    }
}

/// Runs navigation steps one after another.
@MainActor
final class NavigationQueue {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }
}

/// Pictures of image files for the preview column.
///
/// Only small images are fetched — a preview is worth a short read, not a
/// download — and the last few are kept, so arrowing back is instant.
@MainActor
final class ThumbnailCache {
    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private static let limit = 40
    private static let maxBytes = 6 * 1024 * 1024

    func image(for entry: RemoteEntry, provider: SFTPProvider) async -> NSImage? {
        guard entry.kind == .file,
              entry.size > 0, entry.size <= Int64(Self.maxBytes),
              let type = UTType(filenameExtension: entry.fileExtension),
              type.conforms(to: .image)
        else { return nil }

        let key = "\(entry.path)|\(entry.size)|\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)"
        if let cached = images[key] { return cached }

        guard let data = try? await provider.read(entry.path, maxBytes: Self.maxBytes),
              let image = NSImage(data: data), image.isValid
        else { return nil }

        images[key] = image
        order.append(key)
        if order.count > Self.limit {
            images.removeValue(forKey: order.removeFirst())
        }
        return image
    }
}
