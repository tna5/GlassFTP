import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var promptPassword = ""
    @State private var shortcutName = ""
    @AppStorage("showPathBar") private var showPathBar = true

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .overlay(alignment: .bottomTrailing) {
                    if app.transfers.hasTransfers || app.isShowingTransfers {
                        TransfersPanel()
                            // Above the path and status bars, not over them.
                            .padding(.bottom, isBrowsing ? PathBar.height(showingPath: showPathBar) : 0)
                    }
                }
        }
        // On the split view rather than the detail, so it centres on the whole
        // window, sidebar included, as the Finder's does.
        .overlay(alignment: .top) { goToFolder }
        .frame(minWidth: 820, minHeight: 480)
        // Solid symbols throughout, as in the Finder's sidebar and toolbar.
        // Symbols with no filled form (chevrons, xmark) are left as they are.
        .symbolVariant(.fill)
        .modifier(RootSheets(promptPassword: $promptPassword, shortcutName: $shortcutName))
        .onChange(of: app.sidebarSelection) { _, item in
            Task { await app.handleSidebarSelection(item) }
        }
        .onChange(of: app.settings.settings) { _, _ in
            app.applySettings()
        }
        .task { app.reconnectIfWanted() }
    }

    private var isBrowsing: Bool {
        app.session?.status == .connected
    }

    /// ⌘⇧G: drops down from the top of the window with a fade, and goes back
    /// up the same way. A click anywhere else dismisses it.
    private var goToFolder: some View {
        ZStack(alignment: .top) {
            if app.isGoToFolderPresented, let session = app.session, isBrowsing {
                // A light veil over the window, as behind the Finder's panel.
                Color.black.opacity(0.22)
                    .contentShape(.rect)
                    .ignoresSafeArea()
                    .onTapGesture { app.isGoToFolderPresented = false }
                    .transition(.opacity)

                GoToFolderPanel(model: session) { app.isGoToFolderPresented = false }
                    .padding(.top, 40)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: -90).combined(with: .opacity),
                            removal: .offset(y: -90).combined(with: .opacity)
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.28), value: app.isGoToFolderPresented)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = app.session, session.status == .connected {
            FileBrowserView(model: session)
        } else if let session = app.session, session.status == .connecting {
            connecting(to: session.connection)
        } else {
            welcome
        }
    }

    private func connecting(to connection: Connection) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(connection.host)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        WelcomeView()
    }
}

/// Every sheet and alert hung off the root, kept out of `RootView.body` so the
/// type checker does not have to solve one enormous expression.
private struct RootSheets: ViewModifier {
    @Environment(AppState.self) private var app
    @Binding var promptPassword: String
    @Binding var shortcutName: String

    func body(content: Content) -> some View {
        @Bindable var app = app

        return content
            .sheet(item: $app.editingConnection) { connection in
                ConnectionEditor(
                    connection: connection,
                    isNew: app.isEditingNewConnection,
                    existingSecrets: app.isEditingNewConnection ? .init() : .init(
                        password: app.connections.password(for: connection) ?? "",
                        passphrase: app.connections.passphrase(for: connection) ?? "",
                        proxyPassword: app.connections.proxyPassword(for: connection) ?? ""
                    )
                ) { edited, secrets in
                    if app.isEditingNewConnection {
                        app.connections.add(edited, password: secrets.password ?? "")
                    } else {
                        app.connections.update(edited, password: secrets.password)
                    }
                    if let passphrase = secrets.passphrase {
                        app.connections.setPassphrase(passphrase, for: edited)
                    }
                    if let proxyPassword = secrets.proxyPassword {
                        app.connections.setProxyPassword(proxyPassword, for: edited)
                    }
                    app.editingConnection = nil
                } onCancel: {
                    app.editingConnection = nil
                }
            }
            .sheet(item: .init(get: { app.hostKeyPrompter.pending }, set: { _ in })) { challenge in
                HostKeyPrompt(challenge: challenge) { accepted in
                    app.hostKeyPrompter.respond(accepted: accepted)
                }
            }
            .sheet(item: .init(get: { app.transfers.conflicts.pending }, set: { _ in })) { conflict in
                ConflictPrompt(conflict: conflict, remaining: app.transfers.conflicts.remainingCount) { answer in
                    app.transfers.conflicts.respond(answer)
                }
                .interactiveDismissDisabled()
            }
            .sheet(item: $app.passwordPrompt) { request in
                passwordSheet(for: request)
            }
            .sheet(item: $app.inspectorEntry) { entry in
                InfoInspector(entry: entry) { mode in
                    app.inspectorEntry = nil
                    Task { await app.session?.setPermissions(mode, on: entry) }
                } onClose: {
                    app.inspectorEntry = nil
                }
            }
            .alert("Rename Shortcut", isPresented: renamingShortcutBinding) {
                TextField("Name", text: $shortcutName)
                Button("Cancel", role: .cancel) { app.renamingShortcut = nil }
                Button("Rename") {
                    guard let shortcut = app.renamingShortcut else { return }
                    app.renamingShortcut = nil
                    let name = shortcutName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    app.shortcuts.rename(shortcut, to: name)
                }
            }
            .onChange(of: app.renamingShortcut?.id) { _, _ in
                shortcutName = app.renamingShortcut?.name ?? ""
            }
            .alert(
                "Could not connect",
                isPresented: .init(get: { app.connectionError != nil }, set: { if !$0 { app.connectionError = nil } })
            ) {
                Button("OK") { app.connectionError = nil }
            } message: {
                Text(app.connectionError ?? "")
            }
    }

    private var renamingShortcutBinding: Binding<Bool> {
        Binding(
            get: { app.renamingShortcut != nil },
            set: { if !$0 { app.renamingShortcut = nil } }
        )
    }

    private func passwordSheet(for request: AppState.PasswordRequest) -> some View {
        let connection = request.connection

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Password required")
                    .font(.headline)
                Text("Enter the password for \(connection.username)@\(connection.host).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("Password", text: $promptPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit(request) }

            HStack {
                Button("Cancel", role: .cancel) {
                    promptPassword = ""
                    app.passwordPrompt = nil
                    app.sidebarSelection = app.session.map { .connection($0.connection.id) }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { submit(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(promptPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit(_ request: AppState.PasswordRequest) {
        let password = promptPassword
        guard !password.isEmpty else { return }
        promptPassword = ""
        app.passwordPrompt = nil
        // Remember it so the next connect does not ask again.
        app.connections.update(request.connection, password: password)
        Task {
            await app.connect(to: request.connection, password: password, destination: request.destination)
        }
    }
}
