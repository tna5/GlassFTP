import AppKit
import UniformTypeIdentifiers

/// Thin wrappers over the AppKit panels. SwiftUI's `fileImporter` cannot pick
/// "a folder to download into" and files in the same flow, and the panels give
/// us the Downloads default for free.
@MainActor
enum FileDialogs {
    static func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = "Choose where to save the selected items."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseUploads() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload."
        return panel.runModal() == .OK ? panel.urls : []
    }
}
