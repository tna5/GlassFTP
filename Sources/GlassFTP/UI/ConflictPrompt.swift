import SwiftUI

/// "A file with this name already exists" — both sides side by side, the
/// choices from Settings › Transfers, and "apply to all" for the rest of the
/// job.
struct ConflictPrompt: View {
    let conflict: TransferConflict
    let remaining: Int
    let onAnswer: (ConflictPrompter.Answer) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(conflict.name)” already exists")
                        .font(.headline)
                        .lineLimit(2)
                    Text(conflict.direction == .download
                         ? "A file with this name is already in \(conflict.destination) on this Mac."
                         : "A file with this name is already in \(conflict.destination) on the server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                side(
                    title: conflict.direction == .download ? "On the server" : "On this Mac",
                    symbol: conflict.direction == .download ? "externaldrive.fill" : "laptopcomputer",
                    facts: conflict.source,
                    highlight: isNewer(conflict.source, than: conflict.existing)
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                side(
                    title: "Existing",
                    symbol: "doc.fill",
                    facts: conflict.existing,
                    highlight: isNewer(conflict.existing, than: conflict.source)
                )
            }

            Toggle(isOn: $applyToAll) {
                Text(remaining > 1
                     ? "Apply to all conflicts in this transfer (\(remaining - 1) more waiting)"
                     : "Apply to all conflicts in this transfer")
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Skip") { answer(.skip) }
                    .keyboardShortcut(.cancelAction)
                Menu("More") {
                    Button(FileExistsAction.overwriteIfNewer.label) { answer(.overwriteIfNewer) }
                    Button(FileExistsAction.overwriteIfSizeDiffers.label) { answer(.overwriteIfSizeDiffers) }
                    if canResume {
                        Button(FileExistsAction.resume.label) { answer(.resume) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Keep Both") { answer(.rename) }
                if canResume {
                    Button("Resume") { answer(.resume) }
                }
                Button("Replace") { answer(.overwrite) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Resuming only makes sense when the existing file could be the head of
    /// the source.
    private var canResume: Bool {
        conflict.existing.size > 0 && conflict.existing.size < conflict.source.size
    }

    private func answer(_ action: FileExistsAction) {
        onAnswer(.init(action: action, applyToAll: applyToAll))
        applyToAll = false
    }

    private func isNewer(_ lhs: TransferPlanner.FileFacts, than rhs: TransferPlanner.FileFacts) -> Bool {
        guard let left = lhs.modifiedAt, let right = rhs.modifiedAt else { return false }
        return left.timeIntervalSince(right) > 1
    }

    private func side(title: String, symbol: String, facts: TransferPlanner.FileFacts, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(facts.size.formatted(.byteCount(style: .file)))
                .font(.callout.monospacedDigit())
            HStack(spacing: 4) {
                Text(facts.modifiedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if highlight {
                    Text("Newer")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
