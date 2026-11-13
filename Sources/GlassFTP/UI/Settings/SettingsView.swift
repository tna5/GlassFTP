import SwiftUI

/// The Settings window (⌘,).
///
/// FileZilla puts a few hundred options in one tree; here they are grouped by
/// what the user is trying to change, every option says what it does in a
/// footer, and each tab can be reset on its own.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, transfers, connection, proxy, advanced
        var id: String { rawValue }
    }

    @AppStorage("settingsTab") private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape.fill") }
                .tag(Tab.general)
            TransfersSettingsTab()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle.fill") }
                .tag(Tab.transfers)
            ConnectionSettingsTab()
                .tabItem { Label("Connection", systemImage: "bolt.horizontal.circle.fill") }
                .tag(Tab.connection)
            ProxySettingsTab()
                .tabItem { Label("Proxy", systemImage: "point.3.filled.connected.trianglepath.dotted") }
                .tag(Tab.proxy)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2.fill") }
                .tag(Tab.advanced)
        }
        // A fixed size, as macOS settings windows are; longer tabs scroll.
        .frame(width: 580, height: 560)
    }
}

/// Shared chrome for one tab: a grouped form plus a "Restore Defaults" row.
struct SettingsForm<Content: View>: View {
    let onRestore: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: onRestore)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A footer in the secondary style every section uses.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
