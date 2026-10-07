import Foundation

/// The durable outbox and its state machine. Repositories append operations inside their own write
/// transaction (`enqueue(... in:)`); the sync engine drives the rest.
public struct OutboxStore: Sendable {
    private let database: Database
    private let policy: RetryPolicy

    public init(database: Database, retryPolicy: RetryPolicy = .standard) {
        self.database = database
        self.policy = retryPolicy
    }

    // MARK: - Writing (used by repositories, inside their transaction)

    static func enqueue<Payload: Encodable>(
        _ kind: OperationKind, entityID: UUID, groupID: UUID?, payload: Payload, in db: isolated Database
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let now = Date().millisecondsSince1970
        try db.execute(
            """
            INSERT INTO pending_operation (id, kind, entity_id, group_id, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString), .text(kind.rawValue), .text(entityID.uuidString),
                groupID.map { .text($0.uuidString) } ?? .null, .text(json), .int(now), .int(now),
            ]
        )
    }

    // MARK: - Engine API

    /// Operations that may be sent now, oldest first.
    ///
    /// An operation is eligible when it is `pending`, or `failed` and past its backoff, and **nothing earlier
    /// in its group is still unfinished**. That keeps per-group order (a member before the expense that uses
    /// them), lets other groups continue while one is backing off, and stops a rejected or conflicting
    /// operation from letting later dependent operations overtake it.
    public func nextBatch(limit: Int = 20, now: Date = Date()) async throws -> [PendingOperation] {
        try await database.query(
            """
            SELECT * FROM pending_operation o
            WHERE o.status IN ('pending', 'failed') AND o.next_attempt_at <= ?
              AND NOT EXISTS (
                SELECT 1 FROM pending_operation b
                WHERE b.seq < o.seq AND b.status <> 'done' AND (b.group_id IS o.group_id OR b.group_id IS NULL)
              )
            ORDER BY o.seq LIMIT ?
            """,
            [.int(now.millisecondsSince1970), .int(Int64(limit))]
        ).map(Self.operation)
    }

    public func markSending(_ id: UUID) async throws {
        try await update(id, status: .sending, error: nil, attemptsDelta: 0, nextAttempt: nil)
    }

    /// The backend acknowledged the operation (including an idempotent replay).
    public func markDone(_ id: UUID) async throws {
        try await update(id, status: .done, error: nil, attemptsDelta: 0, nextAttempt: nil)
    }

    /// A transient failure: schedule the next attempt with exponential backoff.
    @discardableResult
    public func markFailed(_ id: UUID, error: String, now: Date = Date()) async throws -> Date {
        let attempts = try await attempts(of: id) + 1
        let next = now.addingTimeInterval(policy.delay(afterFailedAttempts: attempts))
        try await update(id, status: .failed, error: error, attemptsDelta: 1, nextAttempt: next)
        return next
    }

    /// The operation could not be sent because the session expired. It goes back to `pending` without
    /// consuming an attempt or a backoff.
    public func markUnauthenticated(_ id: UUID) async throws {
        try await update(id, status: .pending, error: "not authenticated", attemptsDelta: 0, nextAttempt: nil)
    }

    public func markRejected(_ id: UUID, error: String) async throws {
        try await update(id, status: .rejected, error: error, attemptsDelta: 1, nextAttempt: nil)
    }

    public func markConflict(_ id: UUID, error: String) async throws {
        try await update(id, status: .conflict, error: error, attemptsDelta: 0, nextAttempt: nil)
    }

    /// Puts a `rejected` or `conflict` operation back in the queue (user retry or conflict resolved by resending).
    public func requeue(_ id: UUID) async throws {
        try await update(id, status: .pending, error: nil, attemptsDelta: 0, nextAttempt: Date(timeIntervalSince1970: 0))
    }

    /// Operations left `sending` by a crash or a killed app go back to `pending`. Safe because the backend
    /// is idempotent: if the lost request had been applied, the replay is acknowledged without side effects.
    @discardableResult
    public func recoverInterrupted() async throws -> Int {
        let count = try await database.query("SELECT COUNT(*) AS n FROM pending_operation WHERE status = 'sending'")
            .first?.int("n") ?? 0
        try await database.execute(
            "UPDATE pending_operation SET status = 'pending', updated_at = ? WHERE status = 'sending'",
            [.int(Date().millisecondsSince1970)]
        )
        return Int(count)
    }

    /// Drops acknowledged operations that are older than `date`.
    public func purgeDone(before date: Date) async throws {
        try await database.execute(
            "DELETE FROM pending_operation WHERE status = 'done' AND updated_at < ?",
            [.int(date.millisecondsSince1970)]
        )
    }

    // MARK: - Reading (UI and tests)

    public func operations(status: OperationStatus? = nil) async throws -> [PendingOperation] {
        if let status {
            return try await database.query("SELECT * FROM pending_operation WHERE status = ? ORDER BY seq", [.text(status.rawValue)])
                .map(Self.operation)
        }
        return try await database.query("SELECT * FROM pending_operation ORDER BY seq").map(Self.operation)
    }

    /// Statuses of the given entities. Entities without unfinished operations are `synced`.
    public func statuses(of entityIDs: [UUID]) async throws -> [UUID: SyncStatus] {
        var result = Dictionary(uniqueKeysWithValues: entityIDs.map { ($0, SyncStatus.synced) })
        guard !entityIDs.isEmpty else { return result }
        let marks = entityIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query(
            "SELECT entity_id, status FROM pending_operation WHERE status <> 'done' AND entity_id IN (\(marks))",
            entityIDs.map { .text($0.uuidString) }
        )
        for row in rows {
            guard let status = OperationStatus(rawValue: row.text("status")) else { continue }
            result[row.uuid("entity_id"), default: .synced] = max(result[row.uuid("entity_id")] ?? .synced, SyncStatus(operation: status))
        }
        return result
    }

    public func summary() async throws -> SyncSummary {
        let rows = try await database.query(
            "SELECT status, COUNT(*) AS n FROM pending_operation WHERE status <> 'done' GROUP BY status"
        )
        var summary = SyncSummary()
        for row in rows {
            switch OperationStatus(rawValue: row.text("status")) {
            case .pending, .sending: summary.pending += Int(row.int("n"))
            case .failed, .rejected: summary.failed += Int(row.int("n"))
            case .conflict: summary.conflicts += Int(row.int("n"))
            default: break
            }
        }
        return summary
    }

    // MARK: - Internals

    private func attempts(of id: UUID) async throws -> Int {
        Int(try await database.query("SELECT attempts FROM pending_operation WHERE id = ?", [.text(id.uuidString)]).first?.int("attempts") ?? 0)
    }

    private func update(
        _ id: UUID, status: OperationStatus, error: String?, attemptsDelta: Int, nextAttempt: Date?
    ) async throws {
        let now = Date().millisecondsSince1970
        try await database.execute(
            """
            UPDATE pending_operation
            SET status = ?, last_error = ?, attempts = attempts + ?, updated_at = ?,
                next_attempt_at = COALESCE(?, next_attempt_at)
            WHERE id = ?
            """,
            [
                .text(status.rawValue), error.map { .text($0) } ?? .null, .int(Int64(attemptsDelta)), .int(now),
                nextAttempt.map { .int($0.millisecondsSince1970) } ?? .null, .text(id.uuidString),
            ]
        )
    }

    private static func operation(_ row: Row) -> PendingOperation {
        PendingOperation(
            id: row.uuid("id"), seq: row.int("seq"),
            kind: OperationKind(rawValue: row.text("kind")) ?? .upsertExpense,
            entityID: row.uuid("entity_id"),
            groupID: row.optionalText("group_id").flatMap(UUID.init(uuidString:)),
            payload: Data(row.text("payload").utf8),
            status: OperationStatus(rawValue: row.text("status")) ?? .pending,
            attempts: Int(row.int("attempts")),
            nextAttemptAt: row.date("next_attempt_at"),
            lastError: row.optionalText("last_error"),
            createdAt: row.date("created_at")
        )
    }
}

public struct SyncSummary: Sendable, Equatable {
    public var pending = 0
    public var failed = 0
    public var conflicts = 0

    public var isFullySynced: Bool { pending == 0 && failed == 0 && conflicts == 0 }
    public init() {}
}
