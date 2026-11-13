import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var app
    @AppStorage("viewMode") private var viewMode: BrowseViewMode = .list

    var body: some View {
        @Bindable var store = app.settings

        SettingsForm {
            store.settings.general = .init()
            viewMode = .list
        } content: {
            Section {
                Picker("Default view", selection: $viewMode) {
                    ForEach(BrowseViewMode.allCases) { mode in
                        Label(mode.label.replacingOccurrences(of: "as ", with: ""), systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
                Toggle("Show hidden files", isOn: $store.settings.general.showHiddenFiles)
                Toggle("Keep folders on top", isOn: $store.settings.general.foldersFirst)
            } header: {
                Text("Browsing")
            } footer: {
                SettingsFooter("Hidden files are those whose name starts with a dot, such as .htaccess or .env. With folders on top, folders are grouped above files whatever the sort column.")
            }

            Section {
                Picker("Double-clicking a file", selection: $store.settings.general.fileOpenAction) {
                    ForEach(AppSettings.General.FileOpenAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
                Toggle("Ask before deleting", isOn: $store.settings.general.confirmBeforeDelete)
            } header: {
                Text("Files")
            } footer: {
                SettingsFooter("Deleting on a server is permanent — there is no Trash. Turn the confirmation off only if you are sure.")
            }

            Section {
                Toggle("Reconnect to the last server at launch", isOn: $store.settings.general.reconnectOnLaunch)
            } header: {
                Text("Startup")
            }
        }
    }
}
