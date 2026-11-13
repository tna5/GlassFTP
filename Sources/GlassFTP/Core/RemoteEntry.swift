import Foundation
import UniformTypeIdentifiers

/// A single entry in a remote directory.
///
/// This is the only file-description type that crosses from a provider into the
/// UI. Keeping it free of any protocol-specific types is what lets a second
/// protocol be added later without touching the views.
///
/// The last three fields are derived from `name` and cached at construction.
/// They exist because the browser sorts and filters on them: recomputing a
/// locale-aware comparison or a `UTType` lookup inside a sort loop is what makes
/// a folder of fifty thousand files unusable.
struct RemoteEntry: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case file
        case directory
        case symlink
    }

    let name: String
    let path: String
    let kind: Kind
    let size: Int64
    let modifiedAt: Date?
    /// POSIX mode bits, permissions only (the file-type bits are in `kind`).
    let permissions: UInt16?

    /// Natural-order sort key: lowercased, with digit runs zero-padded so a
    /// plain `<` orders `file2` before `file10`.
    let sortKey: String
    /// Lowercased name, for substring search without per-keystroke folding.
    let searchKey: String
    /// Human-readable type, as shown in the Kind column.
    let kindLabel: String
    /// A dotfile. Stored so hiding them is a flag test, not a string scan.
    let isHidden: Bool

    var id: String { path }

    var isDirectory: Bool { kind == .directory }

    init(
        name: String,
        path: String,
        kind: Kind,
        size: Int64,
        modifiedAt: Date?,
        permissions: UInt16?
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions

        let lowercased = name.lowercased()
        self.searchKey = lowercased
        self.sortKey = Self.naturalSortKey(fromLowercased: lowercased)
        self.kindLabel = KindLabels.label(for: kind, fileExtension: Self.fileExtension(of: name))
        self.isHidden = name.hasPrefix(".")
    }

    /// Extension without the dot, lowercased. Empty for dotfiles and for names
    /// with no extension.
    var fileExtension: String { Self.fileExtension(of: name) }

    private static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    // MARK: - Sort key

    /// Widest run of digits we pad to. Twenty covers any `UInt64`; longer runs
    /// are left alone, which orders them oddly but is vanishingly rare in a
    /// file name.
    private static let digitFieldWidth = 20

    static func naturalSortKey(for name: String) -> String {
        naturalSortKey(fromLowercased: name.lowercased())
    }

    private static func naturalSortKey(fromLowercased name: String) -> String {
        // Skip the whole transformation when there is nothing to pad, which is
        // the common case and avoids allocating a second string per entry.
        guard name.contains(where: \.isASCIIDigit) else { return name }

        var result = ""
        result.reserveCapacity(name.count + digitFieldWidth)
        var digits = ""

        for character in name {
            if character.isASCIIDigit {
                digits.append(character)
            } else {
                if !digits.isEmpty {
                    result += padded(digits)
                    digits.removeAll(keepingCapacity: true)
                }
                result.append(character)
            }
        }
        if !digits.isEmpty { result += padded(digits) }
        return result
    }

    private static func padded(_ digits: String) -> String {
        // Leading zeros carry no numeric weight, so drop them before padding —
        // otherwise "007" and "7" would sort apart.
        let significant = digits.drop(while: { $0 == "0" })
        let body = significant.isEmpty ? "0" : String(significant)
        guard body.count < digitFieldWidth else { return body }
        return String(repeating: "0", count: digitFieldWidth - body.count) + body
    }
}

private extension Character {
    /// Deliberately ASCII-only: `isNumber` also matches other numeral systems,
    /// which we must not fold into a decimal field.
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

/// Type labels, memoised by extension.
///
/// A `UTType` lookup plus `localizedDescription` is far too slow to run per
/// entry, let alone per sort comparison. Distinct extensions in a folder number
/// in the dozens, so the cache stays tiny.
enum KindLabels {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String] = [:]

    static func label(for kind: RemoteEntry.Kind, fileExtension: String) -> String {
        switch kind {
        case .directory: return "Folder"
        case .symlink: return "Alias"
        case .file: return fileLabel(for: fileExtension)
        }
    }

    private static func fileLabel(for fileExtension: String) -> String {
        guard !fileExtension.isEmpty else { return "Document" }

        lock.lock()
        if let cached = cache[fileExtension] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let label = UTType(filenameExtension: fileExtension)?.localizedDescription ?? "Document"

        lock.lock()
        cache[fileExtension] = label
        lock.unlock()
        return label
    }
}
