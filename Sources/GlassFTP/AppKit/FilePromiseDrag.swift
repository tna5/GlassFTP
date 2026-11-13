import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Makes a remote file draggable to the Finder.
///
/// The file does not exist locally when the drag starts, so exporting is async:
/// it downloads into a temporary directory and hands back the URL. macOS shows
/// a placeholder at the drop location and fills it in when we finish, and the
/// same download appears in our own transfers panel.
struct FilePromise: Transferable, Sendable {
    let entry: RemoteEntry
    let pool: TransferPool
    let transfers: TransferManager
    /// Everything being dragged, for drops inside the app. Usually the whole
    /// selection when `entry` is part of it.
    let payload: RemoteDragPayload

    @MainActor
    init(entry: RemoteEntry, paths: [String], session: BrowserModel, transfers: TransferManager) {
        self.entry = entry
        self.pool = session.transferPool
        self.transfers = transfers
        self.payload = RemoteDragPayload(connectionID: session.connection.id, paths: paths)
    }

    static var transferRepresentation: some TransferRepresentation {
        // Listed first so a drop inside the app finds it before the file,
        // and moves on the server instead of downloading.
        ProxyRepresentation(exporting: \.payload)
        FileRepresentation(exportedContentType: .data) { promise in
            let url = try await promise.transfers.materialize(promise.entry, pool: promise.pool)
            // The temporary copy is ours to hand over; the receiver may move it.
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.entry.name }
    }
}
