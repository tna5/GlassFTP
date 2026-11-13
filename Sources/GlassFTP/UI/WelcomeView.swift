import AppKit
import SwiftUI

/// What the window shows with no server open: the app, a line on what it
/// does, and the saved servers one click away — instead of an empty state
/// that only points at the sidebar.
struct WelcomeView: View {
    @Environment(AppState.self) private var app

    /// Enough to fill the card without turning it into a second sidebar.
    private static let visibleLimit = 6

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                if app.connections.connections.isEmpty {
                    emptyCard
                } else {
                    connectionsCard
                }

                actions
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(backdrop)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            Text("Welcome to GlassFTP")
                .font(.system(size: 26, weight: .bold))

            Text("Browse your servers like a folder on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var connectionsCard: some View {
        let connections = Array(app.connections.connections.prefix(Self.visibleLimit))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Connections")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 {
                        Divider().padding(.leading, 56)
                    }
                    ConnectionCardRow(connection: connection) {
                        // The same path as a sidebar click, so connecting,
                        // password prompts and errors behave identically.
                        app.sidebarSelection = .connection(connection.id)
                    }
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("No servers yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Add one with its address and your login. Passwords and key passphrases are kept in the Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                app.isEditingNewConnection = true
                app.editingConnection = Connection()
            } label: {
                Label("Add Connection", systemImage: "plus")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)

            SettingsLink {
                Label("Settings", systemImage: "gearshape.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }

    /// A faint glow of the accent colour behind the content, so the glass
    /// has something to pick up.
    private var backdrop: some View {
        RadialGradient(
            colors: [Color.accentColor.opacity(0.16), .clear],
            center: .top,
            startRadius: 20,
            endRadius: 520
        )
        .ignoresSafeArea()
    }
}

/// One saved server: icon tile, name, address, and an arrow on hover.
private struct ConnectionCardRow: View {
    @Environment(AppState.self) private var app
    let connection: Connection
    let onConnect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.tint, in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(connection.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if app.session?.connection.id == connection.id, app.session?.status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.primary.opacity(isHovering ? 0.06 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Connect to \(connection.subtitle)")
    }
}
