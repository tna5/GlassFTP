import SwiftUI

/// Floating transfer queue.
///
/// Uses a `GlassEffectContainer` so the collapsed pill and the expanded panel
/// share one glass surface and morph between the two rather than cross-fading.
struct TransfersPanel: View {
    @Environment(AppState.self) private var app
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            Group {
                if app.isShowingTransfers {
                    expanded
                } else {
                    collapsed
                }
            }
        }
        .padding(16)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: app.isShowingTransfers)
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        Button {
            app.isShowingTransfers = true
        } label: {
            HStack(spacing: 8) {
                progressIndicator
                Text(collapsedLabel)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("transfers", in: glassNamespace)
    }

    private var progressIndicator: some View {
        Group {
            if let fraction = app.transfers.overallFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else if app.transfers.activeCount > 0 {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill")
            }
        }
        .frame(width: 16, height: 16)
    }

    private var collapsedLabel: String {
        let active = app.transfers.activeCount
        if active == 0 { return "Transfers" }
        let count = active == 1 ? "1 transfer" : "\(active) transfers"
        let speed = app.transfers.overallBytesPerSecond
        guard speed > 0 else { return count }
        return "\(count) · \(TransferFormat.speed(speed))"
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if app.transfers.jobs.isEmpty {
                Text("No transfers yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(app.transfers.jobs) { job in
                            TransferRow(job: job) {
                                app.transfers.remove(job)
                            }
                            if job.id != app.transfers.jobs.last?.id {
                                Divider().opacity(0.3).padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: Theme.panelWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelRadius))
        .glassEffectID("transfers", in: glassNamespace)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Transfers")
                    .font(.headline)
                if app.transfers.activeCount > 0 {
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer()
            if app.transfers.jobs.contains(where: { !$0.state.isActive }) {
                Button("Clear") { app.transfers.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                app.isShowingTransfers = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerDetail: String {
        let transfers = app.transfers
        var parts = ["\(transfers.filesInFlight) of \(transfers.options.clampedConcurrency) connections busy"]
        if transfers.overallBytesPerSecond > 0 {
            parts.append(TransferFormat.speed(transfers.overallBytesPerSecond))
        }
        return parts.joined(separator: " · ")
    }
}

enum TransferFormat {
    static func speed(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        if seconds < 60 { return "\(max(Int(seconds), 1)) s left" }
        let duration = Duration.seconds(Int64(seconds))
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)) + " left"
    }
}

/// One job: a file, or a whole folder with aggregate progress.
private struct TransferRow: View {
    @Bindable var job: TransferJob
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if job.state.isActive {
                    ProgressView(value: job.fraction ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        // An unknown total shows an indeterminate bar rather
                        // than one frozen at zero.
                        .opacity(job.fraction == nil ? 0.4 : 1)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The files moving right now, one line each — with several
                // connections busy, "the current file" is no longer one name.
                if job.state.isActive, job.filesTotal > 1, !job.inFlight.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(inFlightRows, id: \.key) { row in
                            InFlightLine(file: row.value)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                if job.state.isActive { job.cancel() } else { onRemove() }
            } label: {
                Image(systemName: job.state.isActive ? "xmark.circle.fill" : "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// At most four lines, so a job with ten connections does not swallow
    /// the panel.
    private var inFlightRows: [(key: UUID, value: TransferJob.InFlight)] {
        Array(job.inFlight.sorted { $0.value.name < $1.value.name }.prefix(4))
    }

    private var iconColor: Color {
        switch job.state {
        case .failed: return .red
        case .cancelled: return .secondary
        case .finished: return .green
        default: return .accentColor
        }
    }

    private var detail: String {
        switch job.state {
        case .waiting:
            return "Waiting…"

        case .discovering, .running:
            var parts: [String] = []
            if job.filesTotal > 1 || job.isCountProvisional {
                // A trailing "+" while the walk is still running: the total is
                // discovered as folders are listed, not known up front.
                let total = job.isCountProvisional ? "\(job.filesTotal)+" : "\(job.filesTotal)"
                parts.append("\(job.filesCompleted) of \(total) files")
            }
            if job.bytesTotal > 0 {
                parts.append(
                    "\(job.bytesTransferred.formatted(.byteCount(style: .file))) of "
                        + job.bytesTotal.formatted(.byteCount(style: .file))
                )
            }
            if job.bytesPerSecond > 0 {
                parts.append(TransferFormat.speed(job.bytesPerSecond))
            }
            if let remaining = job.estimatedSecondsRemaining {
                parts.append(TransferFormat.remaining(remaining))
            }
            if job.filesSkipped > 0 {
                parts.append("\(job.filesSkipped) skipped")
            }
            return parts.isEmpty ? "Preparing…" : parts.joined(separator: " · ")

        case .finished:
            let size = job.bytesTotal.formatted(.byteCount(style: .file))
            var text = job.filesTotal > 1 ? "\(job.filesCompleted) files · \(size)" : size
            if job.filesSkipped > 0 {
                text += job.filesTotal == 1 ? " · skipped" : " · \(job.filesSkipped) skipped"
            }
            return text

        case .cancelled:
            return "Cancelled"

        case .failed(let message):
            return message
        }
    }
}

/// One file in flight inside a job row: name and a thin progress bar.
private struct InFlightLine: View {
    let file: TransferJob.InFlight

    var body: some View {
        HStack(spacing: 6) {
            Text(file.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 60)
        }
    }

    private var fraction: Double {
        guard file.size > 0 else { return 0 }
        return min(1, Double(file.bytes) / Double(file.size))
    }
}
