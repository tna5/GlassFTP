import AppKit
import SwiftUI

/// Clears the drag pasteboard on quit.
///
/// A remote file dragged anywhere leaves a promise on that pasteboard — "the
/// bytes, when asked". At termination AppKit asks for every outstanding
/// promise at once, which meant starting a download from inside the quit
/// itself: the download needs the main thread, the main thread was waiting on
/// the download, and the app hung with the spinning wheel. Giving up ownership
/// first leaves nothing to resolve.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSPasteboard(name: .drag).clearContents()
        return .terminateNow
    }
}

@main
struct GlassFTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()
    @AppStorage("viewMode") private var viewMode: BrowseViewMode = .list
    @AppStorage("showPathBar") private var showPathBar = true

    // Runs before any scene is built. Taking over the process from a custom
    // `@main` type instead left the window without a backing store, so the
    // self-test hook lives here.
    init() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        // Started by an AI agent as its MCP server: no window, see `MCPServer`.
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onAppear { installControlFShortcut() }
        }
        .defaultSize(width: 1080, height: 680)
        .commands { commands }

        Settings {
            SettingsView()
                .environment(app)
                .symbolVariant(.fill)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                app.isEditingNewConnection = true
                app.editingConnection = Connection()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find") { app.isSearchPresented = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(app.session == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(BrowseViewMode.allCases) { mode in
                Button(mode.label) { viewMode = mode }
                    .keyboardShortcut(mode.shortcut, modifiers: .command)
                    .disabled(app.session == nil)
            }
            Divider()
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Back") { Task { await app.session?.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(app.session?.canGoBack != true)
            Button("Forward") { Task { await app.session?.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(app.session?.canGoForward != true)
            Button("Enclosing Folder") { Task { await app.session?.goUp() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(app.session?.canGoUp != true)
            Button("Go to Folder…") { app.isGoToFolderPresented = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(app.session == nil)
            Button("Edit Path") { app.isEditingPath = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(app.session == nil)
            Divider()
            Button("Add to Shortcuts") {
                guard let path = app.session?.currentPath else { return }
                app.addShortcut(for: path)
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(app.session.map { !app.canAddShortcut(for: $0.currentPath) } ?? true)
            Divider()
            Button("Show Transfers") { app.isShowingTransfers.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }

        CommandGroup(after: .toolbar) {
            // The Finder's item, same place and shortcut.
            Button(showPathBar ? "Hide Path Bar" : "Show Path Bar") { showPathBar.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Refresh") { Task { await app.session?.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.session == nil)
            Button("Disconnect") { Task { await app.disconnect() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.session == nil)
        }
    }

    /// Control-F opens the search field, alongside the menu's Command-F.
    ///
    /// It cannot be a second menu item — a command carries only one shortcut,
    /// and a duplicate "Find" entry to hold the other one reads as a bug. A
    /// local event monitor is the reliable way to bind the extra key.
    private func installControlFShortcut() {
        guard !Self.controlFInstalled else { return }
        Self.controlFInstalled = true

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "f",
                  app.session != nil
            else { return event }

            // Control-F is "move forward one character" while editing text.
            // Stealing it there would break the search field itself.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

            app.isSearchPresented = true
            return nil
        }
    }

    /// The window can be rebuilt; the monitor must not be installed twice.
    @MainActor private static var controlFInstalled = false
}
