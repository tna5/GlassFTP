import AppKit
import SwiftUI

/// "A new version is available", shown at launch or from GlassFTP › Check for
/// Updates….
struct UpdateSheet: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let updates = app.updates

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(updates.phase))
                        .font(.headline)
                    Text(detail(updates.phase))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let release = shownRelease(updates.phase), !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }

            buttons(updates)
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isBusy(updates.phase))
    }

    @ViewBuilder
    private func buttons(_ updates: UpdateChecker) -> some View {
        HStack {
            switch updates.phase {
            case .available(let release):
                Button("Skip This Version") { updates.skip(release) }
                Spacer()
                Button("Later") { updates.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") {
                    Task { await updates.install(release) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!UpdateChecker.canInstall)

            case .checking, .installing:
                ProgressView().controlSize(.small)
                Spacer()

            case .failed(_, let release):
                if let release {
                    Button("Download in Browser") {
                        NSWorkspace.shared.open(release.pageURL)
                        updates.dismiss()
                    }
                }
                Spacer()
                Button("Close") { updates.dismiss() }
                    .keyboardShortcut(.defaultAction)

            case .upToDate, .idle:
                Spacer()
                Button("OK") { updates.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func headline(_ phase: UpdateChecker.Phase) -> String {
        switch phase {
        case .available: return "A new version of GlassFTP is available"
        case .installing: return "Installing the update…"
        case .checking: return "Checking for updates…"
        case .upToDate, .idle: return "GlassFTP is up to date"
        case .failed: return "The update did not work"
        }
    }

    private func detail(_ phase: UpdateChecker.Phase) -> String {
        let current = "You have \(UpdateChecker.currentVersion) (build \(UpdateChecker.currentBuild))."
        switch phase {
        case .available(let release):
            return "\(release.title) is out. \(current)"
        case .installing:
            return "Downloading and replacing the app. GlassFTP reopens by itself when it is done; transfers in progress are stopped."
        case .checking, .upToDate, .idle:
            return current
        case .failed(let message, _):
            return message
        }
    }

    private func shownRelease(_ phase: UpdateChecker.Phase) -> UpdateChecker.Release? {
        if case .available(let release) = phase { return release }
        return nil
    }

    private func isBusy(_ phase: UpdateChecker.Phase) -> Bool {
        switch phase {
        case .checking, .installing: return true
        default: return false
        }
    }
}
