import Foundation

/// Writes what a pull returned into the local tables. Runs inside one transaction, so a half-applied pull
/// is impossible, and is idempotent: a row is only applied when it is newer than the local copy, which makes
/// re-pulling a range (the cursor overlap) harmless.
///
/// A row whose entity still has unfinished local operations is skipped: the user's pending change is the
/// newer intent, and sending it will either succeed or surface a conflict (see `docs/architecture/sync-protocol.md`).
enum RemoteApplier {
    /// Returns how many rows changed the local database.
    static func apply(_ changes: [RemoteChange], in db: isolated Database) throws -> Int {
        var applied = 0
        // Parents before children, so foreign keys hold even when everything arrives in one pull.
        for case .user(let row) in changes where try apply(row, in: db) { applied += 1 }
        for case .group(let row) in changes where try apply(row, in: db) { applied += 1 }
        for case .member(let row) in changes where try apply(row, in: db) { applied += 1 }
        for case .expense(let row) in changes where try apply(row, in: db) { applied += 1 }
        return applied
    }

    private static func apply(_ row: RemoteUser, in db: isolated Database) throws -> Bool {
        guard try isNewer(row.version, table: "users", id: row.id, in: db) else { return false }
        try db.execute(
            """
            INSERT INTO users (id, name, email, created_at, version, server_seq) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, email = excluded.email,
                version = excluded.version, server_seq = excluded.server_seq
            """,
            [
                .text(row.id.uuidString), .text(row.name), row.email.map { .text($0) } ?? .null,
                .int(row.createdAt.millisecondsSince1970), .int(row.version), .int(row.serverSeq),
            ]
        )
        return true
    }

    private static func apply(_ row: RemoteGroup, in db: isolated Database) throws -> Bool {
        guard try isNewer(row.version, table: "groups", id: row.id, in: db) else { return false }
        try db.execute(
            """
            INSERT INTO groups (id, name, currency, created_by, created_at, invite_code, version, server_seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, invite_code = excluded.invite_code,
                version = excluded.version, server_seq = excluded.server_seq
            """,
            [
                .text(row.id.uuidString), .text(row.name), .text(row.currency), .text(row.createdBy.uuidString),
                .int(row.createdAt.millisecondsSince1970), row.inviteCode.map { .text($0.uuidString) } ?? .null,
                .int(row.version), .int(row.serverSeq),
            ]
        )
        return true
    }

    private static func apply(_ row: RemoteMember, in db: isolated Database) throws -> Bool {
        guard try isNewer(row.version, table: "group_members", id: row.id, in: db) else { return false }
        // The same person can already be a member locally under another membership id (two devices added them).
        // The server's row is the truth unless the local one is still being sent.
        let clash = try db.query(
            "SELECT id FROM group_members WHERE group_id = ? AND user_id = ? AND id <> ?",
            [.text(row.groupID.uuidString), .text(row.userID.uuidString), .text(row.id.uuidString)]
        ).first?.uuid("id")
        if let clash {
            if try hasUnfinishedOperations(for: clash, in: db) { return false }
            try db.execute("DELETE FROM group_members WHERE id = ?", [.text(clash.uuidString)])
        }
        try db.execute(
            """
            INSERT INTO group_members (id, group_id, user_id, created_at, version, server_seq) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET version = excluded.version, server_seq = excluded.server_seq
            """,
            [
                .text(row.id.uuidString), .text(row.groupID.uuidString), .text(row.userID.uuidString),
                .int(row.createdAt.millisecondsSince1970), .int(row.version), .int(row.serverSeq),
            ]
        )
        return true
    }

    private static func apply(_ row: RemoteExpense, in db: isolated Database) throws -> Bool {
        guard try isNewer(row.version, table: "expenses", id: row.id, in: db) else { return false }
        try db.execute(
            """
            INSERT INTO expenses (id, group_id, paid_by, title, amount_minor, currency, created_at, updated_at, deleted_at,
                                  version, server_seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET paid_by = excluded.paid_by, title = excluded.title,
                amount_minor = excluded.amount_minor, updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at, version = excluded.version, server_seq = excluded.server_seq
            """,
            [
                .text(row.id.uuidString), .text(row.groupID.uuidString), .text(row.paidBy.uuidString), .text(row.title),
                .int(row.amountMinor), .text(row.currency), .int(row.createdAt.millisecondsSince1970),
                .int(row.updatedAt.millisecondsSince1970), row.deletedAt.map { .int($0.millisecondsSince1970) } ?? .null,
                .int(row.version), .int(row.serverSeq),
            ]
        )
        // Splits have no version of their own: they are replaced together with their expense.
        try db.execute("DELETE FROM expense_splits WHERE expense_id = ?", [.text(row.id.uuidString)])
        for split in row.splits {
            try db.execute(
                "INSERT INTO expense_splits (id, expense_id, user_id, amount_minor) VALUES (?, ?, ?, ?)",
                [.text(split.id.uuidString), .text(row.id.uuidString), .text(split.userID.uuidString), .int(split.amountMinor)]
            )
        }
        return true
    }

    /// True when the row is newer than the local copy and the entity has no pending local change.
    private static func isNewer(_ version: Int64, table: String, id: UUID, in db: isolated Database) throws -> Bool {
        if try hasUnfinishedOperations(for: id, in: db) { return false }
        let local = try db.query("SELECT version FROM \(table) WHERE id = ?", [.text(id.uuidString)]).first?.int("version")
        return local.map { version > $0 } ?? true
    }

    private static func hasUnfinishedOperations(for entityID: UUID, in db: isolated Database) throws -> Bool {
        !(try db.query(
            "SELECT 1 FROM pending_operation WHERE entity_id = ? AND status <> 'done' LIMIT 1", [.text(entityID.uuidString)]
        )).isEmpty
    }
}
