import Foundation

/// What the sync status bar should say. Derived, never stored.
public enum SyncPhase: Sendable, Equatable {
    /// No backend configured in this build: everything stays on the device.
    case localOnly
    case idle
    case syncing
    case offline
    /// There is no valid session, so nothing can be sent yet.
    case needsSignIn
    /// The database belongs to another account.
    case accountMismatch
    case failed(String)

    public init(_ outcome: SyncReport.Outcome) {
        switch outcome {
        case .completed: self = .idle
        case .offline: self = .offline
        case .unauthenticated: self = .needsSignIn
        case .accountMismatch: self = .accountMismatch
        case .failed(let message): self = .failed(message)
        }
    }
}

/// Decides *when* to run the sync engine so that nobody else has to: after local writes, when connectivity or
/// the session comes back, when a backoff expires, and as a slow fallback while offline or failing.
///
/// It never observes the database: a cycle writes to the database, which would trigger another cycle.
/// Callers ask explicitly with `requestSync()`.
public actor SyncScheduler {
    public enum Event: Sendable, Equatable {
        case started
        case finished(SyncReport)
    }

    private let engine: SyncEngine
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let fallbackDelay: TimeInterval
    private var wakeUp: Task<Void, Never>?
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    /// - Parameter fallbackDelay: how long to wait before trying again after being offline or after an
    ///   unexpected failure, in case the system never reports that the connection came back.
    public init(
        engine: SyncEngine,
        fallbackDelay: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.engine = engine
        self.fallbackDelay = fallbackDelay
        self.now = now
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Asks for a cycle and returns immediately. Many requests collapse into few cycles (see `SyncEngine.sync`).
    public nonisolated func requestSync() {
        Task { await self.run() }
    }

    public nonisolated func connectivityRestored() { requestSync() }
    public nonisolated func sessionChanged() { requestSync() }

    /// Cancels the pending wake-up and ends the event stream.
    public func stop() {
        wakeUp?.cancel()
        wakeUp = nil
        continuation.finish()
    }

    private func run() async {
        wakeUp?.cancel()
        wakeUp = nil
        continuation.yield(.started)
        let report = await engine.sync()
        continuation.yield(.finished(report))

        switch report.outcome {
        case .completed:
            if let next = report.nextRetryAt { scheduleWake(after: max(0, next.timeIntervalSince(now()))) }
        case .offline, .failed:
            scheduleWake(after: fallbackDelay)
        case .unauthenticated, .accountMismatch:
            break // only a new session (or the user) can fix these
        }
    }

    private func scheduleWake(after delay: TimeInterval) {
        wakeUp?.cancel()
        let sleep = self.sleep
        wakeUp = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }
}
