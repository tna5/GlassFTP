import Foundation
import Observation

/// A destination that already exists, waiting on the user's decision.
struct TransferConflict: Identifiable, Sendable {
    let id = UUID()
    let jobID: UUID
    let direction: TransferJob.Direction
    let name: String
    /// Where the existing file is, for display.
    let destination: String
    let source: TransferPlanner.FileFacts
    let existing: TransferPlanner.FileFacts
}

/// Bridges "file already exists" from the transfer workers to a sheet.
///
/// Like `HostKeyPrompter`, but several workers can hit a conflict at once, so
/// questions queue and are shown one at a time. "Apply to all" answers every
/// queued question from the same job, and the job remembers it for the files
/// still to come.
@MainActor
@Observable
final class ConflictPrompter {
    struct Answer: Sendable {
        var action: FileExistsAction
        var applyToAll: Bool
    }

    private struct Waiting {
        let conflict: TransferConflict
        let continuation: CheckedContinuation<Answer, Never>
    }

    private var queue: [Waiting] = []

    /// The question on screen.
    var pending: TransferConflict? { queue.first?.conflict }
    var remainingCount: Int { queue.count }

    func ask(_ conflict: TransferConflict) async -> Answer {
        await withCheckedContinuation { continuation in
            queue.append(Waiting(conflict: conflict, continuation: continuation))
        }
    }

    func respond(_ answer: Answer) {
        guard let first = queue.first else { return }
        queue.removeFirst()
        first.continuation.resume(returning: answer)

        guard answer.applyToAll else { return }
        let jobID = first.conflict.jobID
        let matching = queue.filter { $0.conflict.jobID == jobID }
        queue.removeAll { $0.conflict.jobID == jobID }
        matching.forEach { $0.continuation.resume(returning: answer) }
    }

    /// Answers everything a cancelled job was waiting on with "skip", so its
    /// workers can unwind.
    func dismiss(jobID: UUID) {
        let matching = queue.filter { $0.conflict.jobID == jobID }
        queue.removeAll { $0.conflict.jobID == jobID }
        matching.forEach { $0.continuation.resume(returning: Answer(action: .skip, applyToAll: true)) }
    }
}
