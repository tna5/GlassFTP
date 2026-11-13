import AppKit
import SwiftUI

struct AdvancedSettingsTab: View {
    @Environment(AppState.self) private var app

    @State private var forgetHost = ""
    @State private var forgetResult: String?
    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var store = app.settings

        SettingsForm {
            store.settings.advanced = .init()
        } content: {
            Section {
                Picker("Chunk size", selection: $store.settings.advanced.chunkSize) {
                    ForEach(AppSettings.Advanced.chunkSizes, id: \.self) { size in
                        Text("\(size / 1024) KB\(size == 32_768 ? " (recommended)" : "")").tag(size)
                    }
                }
                LabeledContent("Requests in flight per file") {
                    Stepper(
                        value: $store.settings.advanced.pipelineDepth,
                        in: AppSettings.Advanced.pipelineRange
                    ) {
                        Text("\(store.settings.advanced.pipelineDepth)")
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                }
            } header: {
                Text("Transfer Tuning")
            } footer: {
                SettingsFooter("A file is read and written in chunks, several at once. More requests in flight help on high-latency links; larger chunks are refused by some servers. Applies to the next connection.")
            }

            Section {
                HStack {
                    TextField("Host", text: $forgetHost, prompt: Text("example.com or example.com:2222"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(forgetHostKey)
                    Button("Forget Host Key", action: forgetHostKey)
                        .disabled(forgetHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let forgetResult {
                    Text(forgetResult)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Show known_hosts in Finder") {
                    let url = KnownHostsStore().fileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        forgetResult = "~/.ssh/known_hosts does not exist yet."
                    }
                }
            } header: {
                Text("Host Keys")
            } footer: {
                SettingsFooter("Host keys are shared with Terminal's ssh in ~/.ssh/known_hosts. Forget a key only when you know the server was reinstalled — a changed key can also mean the connection is being intercepted.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { isConfirmingReset = true }
                }
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                app.settings.settings = AppSettings()
            }
        } message: {
            Text("Every tab returns to its defaults. Saved connections, passwords and shortcuts are not affected.")
        }
    }

    /// Accepts `host`, `host:port` and `[host]:port`, as people paste them.
    private func forgetHostKey() {
        var text = forgetHost.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var port = 22

        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let parsed = Int(rest.dropFirst()) { port = parsed }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":"),
                  let parsed = Int(text[text.index(after: colon)...]) {
            port = parsed
            text = String(text[..<colon])
        }

        do {
            let removed = try KnownHostsStore().removeEntries(host: text, port: port)
            forgetResult = removed == 0
                ? "No pinned key for \(KnownHostsStore.hostPattern(host: text, port: port))."
                : "Removed \(removed) key\(removed == 1 ? "" : "s"). The next connection will ask you to trust the server again."
            if removed > 0 { forgetHost = "" }
        } catch {
            forgetResult = "Could not update known_hosts: \(error.localizedDescription)"
        }
    }
}
