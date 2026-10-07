import Foundation

/// What the sync engine does when the backend reports that an expense changed on another device while this
/// device was editing it (`40001`, see `docs/architecture/conflict-policy.md`).
public enum ConflictPolicy: Sendable, Equatable {
    /// The server's version wins, because the server's order is the only order every device agrees on. The
    /// local change is not discarded: it stays in the `conflict` table and `ConflictResolver.restoreLocal`
    /// re-applies it on top of the server's version.
    case remoteWins
    /// Nothing is resolved automatically. The conflict stays open, holding back its group, with both versions
    /// recorded, until `keepLocal` or `restoreLocal` is called.
    case manual
}

public enum ConflictResolution: String, Sendable, Equatable {
    /// The server's version replaced the local one and the local operations were retired.
    case remoteWins
    /// The local operation was re-sent on top of the server's version, overwriting it.
    case keepLocal
    /// After `remoteWins`, the local change was re-applied as a new operation.
    case restored
}

public enum ConflictError: Error, Equatable {
    case notFound
    /// The conflict was already resolved.
    case notOpen
    /// Only a conflict resolved with `remoteWins` can be restored, once.
    case notRestorable
    /// The server's version was never fetched, so the local copy cannot be rebased onto it.
    case remoteVersionUnknown
    /// The operation that conflicted is no longer in the outbox.
    case operationGone
    /// The expense no longer exists locally.
    case entityGone
}

/// One detected concurrent edit, with what each side had. Rows are kept after they are resolved: they are the
/// record that lets a change that lost be recovered.
public struct Conflict: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case open, resolved
    }

    public let id: UUID
    public let operationID: UUID
    public let entityType: String
    public let entityID: UUID
    /// The user's latest intent for the entity when the conflict was detected or resolved.
    public let local: UpsertExpensePayload?
    /// The server's copy. `nil` until the engine has fetched it.
    public let remote: UpsertExpensePayload?
    public let remoteVersion: Int64?
    public let status: Status
    public let resolution: ConflictResolution?
    public let createdAt: Date
    public let resolvedAt: Date?

    var groupID: UUID? { local?.groupID ?? remote?.groupID }
}

/// Resolves conflicts recorded by the outbox. The engine uses `process` for the automatic policy; the manual
/// operations are meant for a resolution screen.
public struct ConflictResolver: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func conflicts(status: Conflict.Status? = nil) async throws -> [Conflict] {
        let rows: [Row]
        if let status {
            rows = try await database.query(
                "SELECT * FROM conflict WHERE status = ? ORDER BY created_at, id", [.text(status.rawValue)]
            )
        } else {
            rows = try await database.query("SELECT * FROM conflict ORDER BY created_at, id")
        }
        return rows.map(Self.conflict)
    }

    // MARK: - Automatic (sync engine)

    /// Records the server's copy on every open conflict it covers and, under `.remoteWins`, resolves them:
    /// the unfinished local operations of the entity are retired (the latest one is kept on the conflict row)
    /// and the server's rows are written locally, all in one transaction. A server row that is not newer than
    /// the local copy is not a conflict this device can resolve, so it is left open.
    /// Returns how many conflicts were resolved.
    func process(_ conflicts: [Conflict], snapshot: [RemoteChange], policy: ConflictPolicy) async throws -> Int {
        let remotes: [UUID: RemoteExpense] = snapshot.reduce(into: [:]) { result, change in
            if case .expense(let row) = change { result[row.id] = row }
        }
        let stamp = Date().millisecondsSince1970

        return try await database.transaction { db in
            var resolved = 0
            for conflict in conflicts {
                guard let remote = remotes[conflict.entityID],
                    try !db.query("SELECT 1 FROM conflict WHERE id = ? AND status = 'open'", [.text(conflict.id.uuidString)]).isEmpty
                else { continue }
                let remotePayload = try Self.encode(UpsertExpensePayload(remote: remote))
                let localVersion = try db.query(
                    "SELECT version FROM expenses WHERE id = ?", [.text(conflict.entityID.uuidString)]
                ).first?.int("version") ?? 0

                guard policy == .remoteWins, remote.version > localVersion else {
                    try db.execute(
                        "UPDATE conflict SET remote_payload = ?, remote_version = ? WHERE id = ?",
                        [.text(remotePayload), .int(remote.version), .text(conflict.id.uuidString)]
                    )
                    continue
                }

                let entity = [SQLValue.text(conflict.entityID.uuidString)]
                let latest = try db.query(
                    "SELECT payload FROM pending_operation WHERE entity_id = ? AND status <> 'done' ORDER BY seq DESC LIMIT 1",
                    entity
                ).first?.text("payload")
                try db.execute("DELETE FROM pending_operation WHERE entity_id = ? AND status <> 'done'", entity)
                try db.execute(
                    """
                    UPDATE conflict SET local_payload = COALESCE(?, local_payload), remote_payload = ?, remote_version = ?,
                        status = 'resolved', resolution = ?, resolved_at = ?
                    WHERE entity_id = ? AND status = 'open'
                    """,
                    [
                        latest.map { .text($0) } ?? .null, .text(remotePayload), .int(remote.version),
                        .text(ConflictResolution.remoteWins.rawValue), .int(stamp), .text(conflict.entityID.uuidString),
                    ]
                )
                resolved += 1
            }
            // The whole snapshot goes in: it brings the parents (a payer added elsewhere) the expense needs.
            // The applier is idempotent and skips entities that still have local operations.
            if resolved > 0 { _ = try RemoteApplier.apply(snapshot, in: db) }
            return resolved
        }
    }

    // MARK: - Manual

    /// Sends the local change anyway. The local copy is rebased onto the server's version, so the backend
    /// accepts it and overwrites what the other device did (which stays recorded as `remote` on the conflict).
    public func keepLocal(_ id: UUID) async throws {
        let stamp = Date().millisecondsSince1970
        try await database.transaction { db in
            let conflict = try Self.load(id, in: db)
            guard conflict.status == .open else { throw ConflictError.notOpen }
            guard let remoteVersion = conflict.remoteVersion else { throw ConflictError.remoteVersionUnknown }
            guard try !db.query(
                "SELECT 1 FROM pending_operation WHERE id = ? AND status = 'conflict'", [.text(conflict.operationID.uuidString)]
            ).isEmpty else { throw ConflictError.operationGone }

            try db.execute(
                "UPDATE expenses SET version = max(version, ?) WHERE id = ?",
                [.int(remoteVersion), .text(conflict.entityID.uuidString)]
            )
            try OutboxStore.setStatus(
                conflict.operationID, .pending, error: nil, attemptsDelta: 0,
                nextAttempt: Date(timeIntervalSince1970: 0), in: db
            )
            try db.execute(
                "UPDATE conflict SET status = 'resolved', resolution = ?, resolved_at = ? WHERE id = ?",
                [.text(ConflictResolution.keepLocal.rawValue), .int(stamp), .text(id.uuidString)]
            )
        }
    }

    /// Re-applies a change that lost to `remoteWins` as a new edit on top of the server's version. The expense
    /// takes the stored local state, and a new operation carries it to the backend.
    public func restoreLocal(_ id: UUID, now: Date = Date()) async throws {
        try await database.transaction { db in
            let conflict = try Self.load(id, in: db)
            guard conflict.status == .resolved, conflict.resolution == .remoteWins, let local = conflict.local else {
                throw ConflictError.notRestorable
            }
            let entity = [SQLValue.text(conflict.entityID.uuidString)]
            guard try !db.query("SELECT 1 FROM expenses WHERE id = ?", entity).isEmpty else { throw ConflictError.entityGone }

            let stamp = now.millisecondsSince1970
            try db.execute(
                "UPDATE expenses SET paid_by = ?, title = ?, amount_minor = ?, updated_at = ?, deleted_at = ? WHERE id = ?",
                [
                    .text(local.paidBy.uuidString), .text(local.title), .int(local.amountMinor), .int(stamp),
                    local.deletedAt.map { .int($0) } ?? .null, .text(conflict.entityID.uuidString),
                ]
            )
            try db.execute("DELETE FROM expense_splits WHERE expense_id = ?", entity)
            for split in local.splits {
                try db.execute(
                    "INSERT INTO expense_splits (id, expense_id, user_id, amount_minor) VALUES (?, ?, ?, ?)",
                    [.text(split.id.uuidString), .text(conflict.entityID.uuidString), .text(split.userID.uuidString), .int(split.amountMinor)]
                )
            }
            let payload = UpsertExpensePayload(
                id: local.id, groupID: local.groupID, paidBy: local.paidBy, title: local.title,
                amountMinor: local.amountMinor, createdAt: local.createdAt, updatedAt: stamp,
                deletedAt: local.deletedAt, splits: local.splits
            )
            try OutboxStore.enqueue(.upsertExpense, entityID: local.id, groupID: local.groupID, payload: payload, in: db)
            try db.execute(
                "UPDATE conflict SET resolution = ? WHERE id = ?",
                [.text(ConflictResolution.restored.rawValue), .text(id.uuidString)]
            )
        }
    }

    // MARK: - Internals

    private static func load(_ id: UUID, in db: isolated Database) throws -> Conflict {
        guard let row = try db.query("SELECT * FROM conflict WHERE id = ?", [.text(id.uuidString)]).first else {
            throw ConflictError.notFound
        }
        return conflict(row)
    }

    private static func encode(_ payload: UpsertExpensePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func decode(_ json: String?) -> UpsertExpensePayload? {
        json.flatMap { try? JSONDecoder().decode(UpsertExpensePayload.self, from: Data($0.utf8)) }
    }

    private static func conflict(_ row: Row) -> Conflict {
        let isExpense = row.text("entity_type") == "expense"
        return Conflict(
            id: row.uuid("id"), operationID: row.uuid("operation_id"), entityType: row.text("entity_type"),
            entityID: row.uuid("entity_id"),
            local: isExpense ? decode(row.text("local_payload")) : nil,
            remote: isExpense ? decode(row.optionalText("remote_payload")) : nil,
            remoteVersion: row.optionalInt("remote_version"),
            status: Conflict.Status(rawValue: row.text("status")) ?? .open,
            resolution: row.optionalText("resolution").flatMap(ConflictResolution.init(rawValue:)),
            createdAt: row.date("created_at"),
            resolvedAt: row.optionalInt("resolved_at").map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }
}
