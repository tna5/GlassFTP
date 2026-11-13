import AppKit
import SwiftUI

struct TransfersSettingsTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var store = app.settings

        SettingsForm {
            store.settings.transfers = .init()
        } content: {
            Section {
                LabeledContent("Simultaneous transfers") {
                    Stepper(
                        value: $store.settings.transfers.maxConcurrent,
                        in: AppSettings.Transfers.concurrencyRange
                    ) {
                        Text("\(store.settings.transfers.maxConcurrent)")
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                }
            } header: {
                Text("Speed")
            } footer: {
                SettingsFooter("Each transfer gets its own connection to the server, so many small files move in parallel instead of one after another. Some servers limit connections per user — lower this if transfers start failing to connect.")
            }

            Section {
                Toggle("Ask where to save each download", isOn: $store.settings.transfers.askForDownloadFolder)
                if !store.settings.transfers.askForDownloadFolder {
                    LabeledContent("Save downloads to") {
                        HStack {
                            Text((store.settings.transfers.downloadFolder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Button("Choose…") { chooseFolder(store) }
                        }
                    }
                }
            } header: {
                Text("Downloads")
            }

            Section {
                Picker("When a downloaded file exists", selection: $store.settings.transfers.whenDownloadExists) {
                    actions
                }
                Picker("When an uploaded file exists", selection: $store.settings.transfers.whenUploadExists) {
                    actions
                }
            } header: {
                Text("Existing Files")
            } footer: {
                SettingsFooter("“Resume” continues a file that stopped partway, sending only what is missing. “Keep both” adds a number to the new file's name.")
            }

            Section {
                Toggle("Keep modification dates", isOn: $store.settings.transfers.preserveModificationTime)
                Toggle("Keep partially downloaded files", isOn: $store.settings.transfers.keepPartialDownloads)
                Toggle("Upload hidden files", isOn: $store.settings.transfers.uploadHiddenFiles)
            } header: {
                Text("Files")
            } footer: {
                SettingsFooter("A partial file can be resumed later instead of starting over. Hidden files, like .DS_Store, are skipped when uploading a folder unless included here.")
            }

            Section {
                Stepper(
                    "Retry failed files: \(retryLabel(store.settings.transfers.retries))",
                    value: $store.settings.transfers.retries,
                    in: AppSettings.Transfers.retryRange
                )
                Stepper(
                    "Wait between attempts: \(store.settings.transfers.retryDelaySeconds) s",
                    value: $store.settings.transfers.retryDelaySeconds,
                    in: 0...60
                )
                .disabled(store.settings.transfers.retries == 0)
            } header: {
                Text("Errors")
            } footer: {
                SettingsFooter("A retry opens a fresh connection and resumes where the file stopped. Missing files and permission errors are not retried.")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        ForEach(FileExistsAction.allCases, id: \.self) { action in
            Text(action.label).tag(action)
            if action == .ask { Divider() }
        }
    }

    private func retryLabel(_ count: Int) -> String {
        switch count {
        case 0: return "never"
        case 1: return "once"
        default: return "\(count) times"
        }
    }

    private func chooseFolder(_ store: SettingsStore) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.settings.transfers.downloadFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.transfers.downloadFolder = url.path
    }
}
