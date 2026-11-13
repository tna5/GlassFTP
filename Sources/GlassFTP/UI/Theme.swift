import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared visual constants, so the glass surfaces stay consistent instead of
/// each view inventing its own radius.
enum Theme {
    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let rowIconSize: CGFloat = 16
    static let panelWidth: CGFloat = 340
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 240
}

/// Real Finder icons for remote files.
///
/// The files are on a server, so `NSWorkspace.icon(forFile:)` is out — we map
/// the extension to a `UTType` and ask for that type's icon instead. This is
/// what makes the list read as a Finder window rather than a table of glyphs.
@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]
    private static var sizedCache: [String: NSImage] = [:]

    /// The icon prepared for drawing at `points`.
    ///
    /// Workspace icons come back with a nominal size of 32 pt; scaled up in
    /// SwiftUI they were rasterised at that size and stretched, which is what
    /// made the icon view blurry. Setting the size first lets AppKit pick the
    /// matching representation (512 px and up) for the screen's scale.
    static func image(for entry: RemoteEntry, size points: CGFloat) -> NSImage {
        sized(image(for: entry), points)
    }

    /// A folder, for the path bar.
    static func folder(size points: CGFloat) -> NSImage {
        sized(cached("public.folder") { NSWorkspace.shared.icon(for: .folder) }, points)
    }

    /// A disk, standing for the server at the root of the path bar — the
    /// Finder starts its trail with the volume the same way.
    static func volume(size points: CGFloat) -> NSImage {
        sized(cached("public.volume") { NSWorkspace.shared.icon(for: .volume) }, points)
    }

    static func image(for entry: RemoteEntry) -> NSImage {
        switch entry.kind {
        case .directory:
            return cached("public.folder") { NSWorkspace.shared.icon(for: .folder) }
        case .symlink:
            return cached("public.symlink") { NSWorkspace.shared.icon(for: .symbolicLink) }
        case .file:
            let ext = entry.fileExtension
            return cached(ext.isEmpty ? "public.data" : ext) {
                let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
                return NSWorkspace.shared.icon(for: type)
            }
        }
    }

    private static func sized(_ base: NSImage, _ points: CGFloat) -> NSImage {
        let key = "\(ObjectIdentifier(base).hashValue)@\(Int(points.rounded()))"
        if let existing = sizedCache[key] { return existing }
        let sized = (base.copy() as? NSImage) ?? base
        sized.size = NSSize(width: points, height: points)
        sizedCache[key] = sized
        return sized
    }

    private static func cached(_ key: String, make: () -> NSImage) -> NSImage {
        if let existing = cache[key] { return existing }
        let image = make()
        cache[key] = image
        return image
    }
}

extension RemoteEntry {
    /// Non-optional sort key so the column can use `KeyPathComparator`.
    var modifiedSortKey: Date { modifiedAt ?? .distantPast }

    var displaySize: String {
        guard kind != .directory else { return "--" }
        return size.formatted(.byteCount(style: .file))
    }

    var displayModified: String {
        guard let modifiedAt else { return "--" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// `rwxr-xr-x` style string, as shown in the inspector.
    var displayPermissions: String {
        guard let permissions else { return "--" }
        let flags = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let triad = (permissions >> UInt16(shift)) & 0b111
            for (index, flag) in flags.enumerated() {
                result += (triad & (0b100 >> UInt16(index))) != 0 ? flag : "-"
            }
        }
        return result
    }

    var octalPermissions: String {
        guard let permissions else { return "---" }
        return String(permissions & 0o777, radix: 8)
    }
}
