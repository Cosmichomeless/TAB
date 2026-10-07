import Foundation

/// The one-line answer to "is my data safe and where does it stand?", derived from the scheduler phase and
/// the outbox counters. The UI only maps each case to wording and an icon.
public enum SyncHeadline: Sendable, Equatable {
    /// No backend in this build: changes stay on the device and nothing is expected to sync.
    case localOnly
    case syncing
    /// There is no session; `waiting` changes are saved on the device until the user signs in.
    case needsSignIn(waiting: Int)
    case accountMismatch
    case conflicts(Int)
    case failed(Int)
    /// The device cannot reach the backend; `waiting` changes are saved locally.
    case offline(waiting: Int)
    case error(String)
    case waiting(Int)
    case synced
}

public struct SyncOverview: Sendable, Equatable {
    public let headline: SyncHeadline

    /// Most severe condition first, so that a problem is never hidden behind a progress message
    /// (except while a cycle is running, which is a transient state).
    public init(phase: SyncPhase, summary: SyncSummary) {
        let waiting = summary.pending + summary.failed + summary.conflicts
        switch phase {
        case .localOnly: headline = .localOnly
        case .syncing: headline = .syncing
        case .needsSignIn: headline = .needsSignIn(waiting: waiting)
        case .accountMismatch: headline = .accountMismatch
        case .offline: headline = .offline(waiting: waiting)
        case .idle, .failed:
            if summary.conflicts > 0 {
                headline = .conflicts(summary.conflicts)
            } else if summary.failed > 0 {
                headline = .failed(summary.failed)
            } else if case .failed(let message) = phase {
                headline = .error(message)
            } else if summary.pending > 0 {
                headline = .waiting(summary.pending)
            } else {
                headline = .synced
            }
        }
    }
}
