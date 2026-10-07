import Foundation

/// What one synchronization cycle did.
public struct SyncReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Push and pull both ran (individual operations may still have been retried or rejected).
        case completed
        /// No connection. Nothing was lost; the next cycle picks up where this one stopped.
        case offline
        /// There is no valid session. Synchronization is paused until the user signs in again.
        case unauthenticated
        /// The signed-in account differs from the one this database was synchronized with.
        case accountMismatch
        case failed(String)
    }

    public var outcome: Outcome = .completed
    /// Operations acknowledged by the backend.
    public var pushed = 0
    /// Operations that failed transiently and were scheduled for a retry.
    public var retrying = 0
    /// Operations the backend will never accept.
    public var rejected = 0
    /// Conflicts detected while pushing.
    public var conflicts = 0
    /// Conflicts the engine resolved by itself (`ConflictPolicy.remoteWins`).
    public var resolved = 0
    /// Remote rows that changed the local database.
    public var pulled = 0
    /// When the earliest retry becomes due, so a scheduler can sleep until then.
    public var nextRetryAt: Date?

    public init() {}

    fileprivate mutating func absorb(_ later: SyncReport) {
        outcome = later.outcome
        pushed += later.pushed
        retrying += later.retrying
        rejected += later.rejected
        conflicts += later.conflicts
        resolved += later.resolved
        pulled += later.pulled
        nextRetryAt = later.nextRetryAt
    }
}

/// The only component that talks to the backend. It drains the outbox (push) and then fetches what other
/// devices changed (pull). Local screens never wait for it: they read SQLite, which the engine updates.
///
/// Calls to `sync()` made while a cycle is running are coalesced into one extra cycle after it, so triggering
/// it from many places (a write, a reconnection, the app becoming active) is safe and cheap.
public actor SyncEngine {
    private let database: Database
    private let backend: any RemoteBackend
    private let outbox: OutboxStore
    private let resolver: ConflictResolver
    private let conflictPolicy: ConflictPolicy
    private let now: @Sendable () -> Date
    private let batchSize: Int
    private let pageSize: Int
    private let cursorOverlap: Int64

    private var running: Task<SyncReport, Never>?
    private var rerunRequested = false

    /// - Parameters:
    ///   - pageSize: rows requested per pull call.
    ///   - cursorOverlap: `server_seq` is assigned when a row is written, not when it commits, so a row can
    ///     become visible after a later one. Pulling from `cursor - overlap` and applying idempotently catches those.
    ///   - conflictPolicy: what to do with a concurrent edit of the same expense (see `ConflictPolicy`).
    public init(
        database: Database,
        backend: any RemoteBackend,
        retryPolicy: RetryPolicy = .standard,
        batchSize: Int = 20,
        pageSize: Int = 500,
        cursorOverlap: Int64 = 1000,
        conflictPolicy: ConflictPolicy = .remoteWins,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.backend = backend
        self.outbox = OutboxStore(database: database, retryPolicy: retryPolicy)
        self.resolver = ConflictResolver(database: database)
        self.conflictPolicy = conflictPolicy
        self.batchSize = batchSize
        self.pageSize = pageSize
        self.cursorOverlap = cursorOverlap
        self.now = now
    }

    /// Runs a cycle (push, then pull) and returns what happened. Never throws: every failure is reported
    /// in the outcome and leaves the outbox in a state the next cycle can continue from.
    @discardableResult
    public func sync() async -> SyncReport {
        if let running {
            rerunRequested = true
            return await running.value
        }
        let task = Task { await self.runCycles() }
        running = task
        return await task.value
    }

    private func runCycles() async -> SyncReport {
        var report = await cycle()
        while rerunRequested, report.outcome == .completed {
            rerunRequested = false
            report.absorb(await cycle())
        }
        // No suspension point between the last check and this reset, so a request cannot be lost.
        rerunRequested = false
        running = nil
        return report
    }

    // MARK: - One cycle

    private func cycle() async -> SyncReport {
        var report = SyncReport()
        do {
            try await outbox.recoverInterrupted()

            let account = try await backend.accountID()
            guard try await bind(to: account) else {
                report.outcome = .accountMismatch
                return report
            }
            try await push(&report)
            if report.outcome == .completed, try await resolveConflicts(&report) > 0 {
                // Resolving releases the operations the conflict was holding back in its group.
                try await push(&report)
            }
            if report.outcome == .completed {
                try await pull(&report)
            }
            if report.outcome == .completed {
                try await recordSuccess(pushed: report.pushed > 0)
            }
        } catch {
            report.outcome = Self.outcome(for: error)
            await recordFailure(report.outcome)
        }
        report.nextRetryAt = try? await outbox.nextRetryDate()
        return report
    }

    /// A database belongs to one account. Mixing two would upload one person's data into another's.
    private func bind(to account: String) async throws -> Bool {
        let stored = try await database.query("SELECT account_id FROM sync_state WHERE id = 1").first?.optionalText("account_id")
        if let stored { return stored == account }
        try await database.execute("UPDATE sync_state SET account_id = ? WHERE id = 1", [.text(account)])
        return true
    }

    // MARK: - Push

    private func push(_ report: inout SyncReport) async throws {
        var attempted = Set<UUID>()
        while true {
            let batch = try await outbox.nextBatch(limit: batchSize, now: now())
                .filter { !attempted.contains($0.id) }
            if batch.isEmpty { return }
            for operation in batch {
                attempted.insert(operation.id)
                guard try await deliver(operation, &report) else { return }
            }
        }
    }

    /// Sends one operation. Returns `false` when the whole cycle should stop (no connection, no session).
    private func deliver(_ operation: PendingOperation, _ report: inout SyncReport) async throws -> Bool {
        try await outbox.markSending(operation.id)
        let ack: RemoteAck
        do {
            let base = try await baseVersion(of: operation)
            ack = try await backend.send(operation, baseVersion: base)
        } catch RemoteError.offline {
            try await outbox.markOffline(operation.id)
            report.outcome = .offline
            return false
        } catch let error as RemoteError {
            return try await handle(error, for: operation, &report)
        } catch is CancellationError {
            try await outbox.markOffline(operation.id)
            throw CancellationError()
        } catch {
            // Unknown failures are transient on purpose: retrying is cheap, losing the operation is not.
            try await outbox.markFailed(operation.id, error: String(describing: error), now: now())
            report.retrying += 1
            return true
        }
        try await outbox.markDone(operation, ack: ack)
        report.pushed += 1
        return true
    }

    private func handle(_ error: RemoteError, for operation: PendingOperation, _ report: inout SyncReport) async throws -> Bool {
        guard case .server(let sqlState, let status, let message) = error else { return true }
        switch FailureClass.classify(sqlState: sqlState, httpStatus: status) {
        case .retry:
            try await outbox.markFailed(operation.id, error: message, now: now())
            report.retrying += 1
        case .unauthenticated:
            try await outbox.markUnauthenticated(operation.id)
            report.outcome = .unauthenticated
            return false
        case .permanent:
            try await outbox.markRejected(operation.id, error: message)
            report.rejected += 1
        case .conflict:
            try await outbox.markConflict(operation, remoteVersion: error.currentVersion, error: message)
            report.conflicts += 1
        }
        return true
    }

    /// The version of the entity the device last saw. Only expense updates are checked by the backend.
    private func baseVersion(of operation: PendingOperation) async throws -> Int64 {
        guard operation.kind == .upsertExpense else { return 0 }
        return try await database.query("SELECT version FROM expenses WHERE id = ?", [.text(operation.entityID.uuidString)])
            .first?.int("version") ?? 0
    }

    // MARK: - Pull

    private func pull(_ report: inout SyncReport) async throws {
        let cursor = try await database.query("SELECT cursor FROM sync_state WHERE id = 1").first?.int("cursor") ?? 0
        let since = max(0, cursor - cursorOverlap)

        // Every page is fetched before anything is written, so the single transaction below sees parents and
        // children together, and an interrupted pull changes nothing.
        let fetched = try await fetchChanges(since: since, groupID: nil)
        let newCursor = max(cursor, fetched.map(\.serverSeq).max() ?? cursor)
        let stamp = now().millisecondsSince1970
        report.pulled += try await database.transaction { db in
            let applied = try RemoteApplier.apply(fetched, in: db)
            try db.execute("UPDATE sync_state SET cursor = ?, last_pulled_at = ? WHERE id = 1", [.int(newCursor), .int(stamp)])
            return applied
        }
    }

    private func fetchChanges(since start: Int64, groupID: UUID?) async throws -> [RemoteChange] {
        var since = start
        var changes: [RemoteChange] = []
        while true {
            let page = try await backend.pull(since: since, limit: pageSize, groupID: groupID)
            changes += page
            guard page.count >= pageSize, let last = page.last?.serverSeq, last > since else { return changes }
            since = last
        }
    }

    // MARK: - Conflicts

    /// Looks at the open conflicts, fetches the server's copy of each affected group and applies the policy.
    /// Returns how many conflicts were resolved. Runs between push and pull: the pull would skip these
    /// entities anyway because they still have unfinished operations.
    private func resolveConflicts(_ report: inout SyncReport) async throws -> Int {
        let policy = conflictPolicy
        // Under `.manual` the server's copy is fetched once, to record it, not on every cycle.
        let open = try await resolver.conflicts(status: .open).filter { policy == .remoteWins || $0.remote == nil }
        let byGroup = Dictionary(grouping: open.compactMap { conflict in conflict.groupID.map { ($0, conflict) } }, by: \.0)

        var resolved = 0
        for groupID in byGroup.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let snapshot = try await fetchChanges(since: 0, groupID: groupID)
            resolved += try await resolver.process((byGroup[groupID] ?? []).map(\.1), snapshot: snapshot, policy: policy)
        }
        report.resolved += resolved
        return resolved
    }

    // MARK: - Bookkeeping

    private func recordSuccess(pushed: Bool) async throws {
        try await database.execute(
            "UPDATE sync_state SET last_error = NULL, last_pushed_at = CASE WHEN ? THEN ? ELSE last_pushed_at END WHERE id = 1",
            [.int(pushed ? 1 : 0), .int(now().millisecondsSince1970)]
        )
    }

    private func recordFailure(_ outcome: SyncReport.Outcome) async {
        guard case .failed(let message) = outcome else { return }
        try? await database.execute("UPDATE sync_state SET last_error = ? WHERE id = 1", [.text(message)])
    }

    private static func outcome(for error: Error) -> SyncReport.Outcome {
        switch error {
        case RemoteError.offline:
            return .offline
        case RemoteError.server(let sqlState, let status, let message):
            return FailureClass.classify(sqlState: sqlState, httpStatus: status) == .unauthenticated
                ? .unauthenticated : .failed(message)
        default:
            return .failed(String(describing: error))
        }
    }
}
