import SwiftUI

struct ConnectionSettingsTab: View {
    @Environment(AppState.self) private var app

    /// Steps offered for the listing cache, in entries.
    private static let cacheSizes = [50_000, 100_000, 200_000, 500_000, 1_000_000]

    var body: some View {
        @Bindable var store = app.settings

        SettingsForm {
            store.settings.connection = .init()
        } content: {
            Section {
                Stepper(
                    "Give up connecting after \(store.settings.connection.connectTimeoutSeconds) s",
                    value: $store.settings.connection.connectTimeoutSeconds,
                    in: 5...120,
                    step: 5
                )
            } header: {
                Text("Connecting")
            } footer: {
                SettingsFooter("Applies to the connection to the server or, when a proxy is used, to the proxy.")
            }

            Section {
                Toggle("Load folders when the pointer rests on them", isOn: $store.settings.connection.warmOnHover)
                Toggle("Load subfolders in the background", isOn: $store.settings.connection.prefetchChildFolders)
                Picker("Remember up to", selection: $store.settings.connection.listingCacheBudget) {
                    ForEach(Self.cacheSizes, id: \.self) { size in
                        Text("\(size.formatted()) items").tag(size)
                    }
                }
            } header: {
                Text("Speed")
            } footer: {
                SettingsFooter("Folders already loaded open instantly and are refreshed behind the scenes. Loading ahead makes navigation feel immediate on slow links but adds requests to the server; turn it off on metered or rate-limited servers. A larger memory uses roughly 200 bytes per item.")
            }
        }
    }
}
