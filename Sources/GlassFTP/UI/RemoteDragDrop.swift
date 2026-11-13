import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Remote items dragged inside the app. Declared in Info.plist.
    ///
    /// Without a type of our own, a drag from one folder to another could only
    /// be read as a file URL — which meant downloading the file and uploading
    /// it again, into whatever folder happened to be on screen.
    static let glassftpRemoteItems = UTType(exportedAs: "com.glassftp.remote-items", conformingTo: .data)
}

/// What an in-app drag carries: which server, and which paths on it.
struct RemoteDragPayload: Codable, Sendable, Transferable {
    let connectionID: UUID
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .glassftpRemoteItems)
    }
}

/// The drag in flight, recorded when it starts.
///
/// A drop target is asked whether it accepts the drag on every mouse move,
/// long before the pasteboard data can be read. Knowing the paths up front is
/// what lets a folder refuse a drop onto itself, and lets the highlight show
/// only where the drop would do something.
@MainActor
enum RemoteDragSession {
    static var current: RemoteDragPayload?
}

/// Drag source for one entry.
struct RemoteDragSource: ViewModifier {
    let entry: RemoteEntry
    let makePromise: (RemoteEntry) -> FilePromise

    func body(content: Content) -> some View {
        content.onDrag {
            // Built here rather than in `body`: this closure runs once, at the
            // start of the drag, which is also when the session is recorded.
            let promise = makePromise(entry)
            RemoteDragSession.current = promise.payload
            let provider = NSItemProvider()
            provider.register(promise)
            provider.suggestedName = entry.name
            return provider
        }
    }
}

/// How a drop target shows that it will take the drop.
enum DropHighlightStyle {
    /// A folder row: tinted, as the Finder does.
    case row
    /// A whole column or pane: an outline.
    case area
    /// The caller draws its own.
    case none
}

/// Makes a view accept both in-app moves and uploads from the Finder into
/// `path`, optionally springing open after a hover.
struct RemoteDropTarget: ViewModifier {
    let path: String
    let actions: BrowserActions
    var style: DropHighlightStyle = .area
    /// Called after hovering a drag over the target for a moment — the Finder's
    /// spring-loaded folders.
    var onSpring: (() -> Void)?
    var isTargeted: Binding<Bool>?

    @State private var targeted = false

    private static let springDelay = Duration.milliseconds(900)

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: [.glassftpRemoteItems, .fileURL],
                delegate: RemoteDropDelegate(
                    destination: path,
                    actions: actions,
                    isTargeted: Binding {
                        targeted
                    } set: {
                        targeted = $0
                        isTargeted?.wrappedValue = $0
                    }
                )
            )
            .overlay { highlight }
            .task(id: targeted) {
                guard targeted, let onSpring else { return }
                try? await Task.sleep(for: Self.springDelay)
                guard !Task.isCancelled, targeted else { return }
                onSpring()
            }
    }

    @ViewBuilder
    private var highlight: some View {
        if targeted {
            switch style {
            case .row:
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint.opacity(0.22))
                    .strokeBorder(.tint, lineWidth: 1.5)
                    .padding(.horizontal, -4)
                    .allowsHitTesting(false)
            case .area:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            case .none:
                EmptyView()
            }
        }
    }
}

extension View {
    func remoteDragSource(_ entry: RemoteEntry, promise: @escaping (RemoteEntry) -> FilePromise) -> some View {
        modifier(RemoteDragSource(entry: entry, makePromise: promise))
    }

    /// Drop target for a folder. Does nothing for files, so a drop on a file
    /// row falls through to the folder around it.
    @ViewBuilder
    func remoteDropTarget(
        for entry: RemoteEntry,
        actions: BrowserActions,
        onSpring: (() -> Void)? = nil
    ) -> some View {
        if entry.isDirectory {
            modifier(RemoteDropTarget(path: entry.path, actions: actions, style: .row, onSpring: onSpring))
        } else {
            self
        }
    }

    func remoteDropTarget(
        path: String,
        actions: BrowserActions,
        style: DropHighlightStyle = .area,
        isTargeted: Binding<Bool>? = nil
    ) -> some View {
        modifier(RemoteDropTarget(path: path, actions: actions, style: style, isTargeted: isTargeted))
    }
}

/// Decides, per hover, between a move (our own items, same server) and a copy
/// (files from the Finder), and refuses drops that would do nothing.
private struct RemoteDropDelegate: DropDelegate {
    let destination: String
    let actions: BrowserActions
    @Binding var isTargeted: Bool

    private enum Operation {
        case move([String])
        case upload
    }

    private func operation(for info: DropInfo) -> Operation? {
        if info.hasItemsConforming(to: [.glassftpRemoteItems]) {
            // Our own drag. Items on another server cannot be renamed across;
            // refusing beats silently downloading and re-uploading them.
            guard let payload = RemoteDragSession.current,
                  payload.connectionID == actions.connectionID,
                  BrowserModel.canMove(payload.paths, into: destination)
            else { return nil }
            return .move(payload.paths)
        }
        if info.hasItemsConforming(to: [.fileURL]) {
            return .upload
        }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        operation(for: info) != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = operation(for: info) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch operation(for: info) {
        case .move:
            isTargeted = true
            return DropProposal(operation: .move)
        case .upload:
            isTargeted = true
            return DropProposal(operation: .copy)
        case nil:
            isTargeted = false
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        switch operation(for: info) {
        case .move(let paths):
            RemoteDragSession.current = nil
            actions.move(paths, destination)
            return true
        case .upload:
            let providers = info.itemProviders(for: [.fileURL])
            let destination = destination
            let upload = actions.uploadInto
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.fileURL(from: provider) { urls.append(url) }
                }
                upload(urls, destination)
            }
            return true
        case nil:
            return false
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
