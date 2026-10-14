import Foundation

/// Moves groups in and out of the local database as snapshots and backups.
///
/// Imports and restores write straight to the local tables and do not enter the sync outbox: they are copies of
/// data the user chose to bring in, not edits to be pushed to a backend.
public struct GroupArchive: Sendable {
    public enum ImportMode: Sendable, Equatable {
        /// Keep the ids in the file. If the group is already here its expenses are replaced by the file's.
        case updateExisting
        /// Always create a new group with fresh ids, leaving any existing one alone.
        case addAsCopy
    }

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Export

    /// The group as it is now. Deleted expenses are not included.
    public func snapshot(of groupID: UUID) async throws -> GroupSnapshot {
        try await database.read { db in
            var snapshot = try Self.fetchSnapshot(groupID: groupID, in: db)
            snapshot.balances = snapshot.computedBalances()
            return snapshot
        }
    }

    /// The local group a snapshot would update, if there is one.
    public func existingGroup(matching snapshot: GroupSnapshot) async throws -> Group? {
        try await database.read { db in
            try db.query("SELECT * FROM groups WHERE id = ?", [.text(snapshot.group.id.uuidString)]).first.map {
                Group(
                    id: $0.uuid("id"), name: $0.text("name"), currency: Currency(code: $0.text("currency")) ?? .eur,
                    createdBy: $0.uuid("created_by"), createdAt: $0.date("created_at")
                )
            }
        }
    }

    public func backup(me userID: UUID) async throws -> BackupFile {
        try await database.read { db in
            guard let row = try db.query("SELECT * FROM users WHERE id = ?", [.text(userID.uuidString)]).first else {
                throw DomainError.userNotFound(userID)
            }
            let me = GroupSnapshot.Participant(
                id: row.uuid("id"), name: row.text("name"), email: row.optionalText("email"),
                createdAt: row.int("created_at")
            )
            let ids = try db.query("SELECT id FROM groups ORDER BY created_at, rowid").map { $0.uuid("id") }
            var groups: [GroupSnapshot] = []
            for id in ids {
                var snapshot = try Self.fetchSnapshot(groupID: id, in: db)
                snapshot.balances = snapshot.computedBalances()
                groups.append(snapshot)
            }
            return BackupFile(exportedAt: Date().millisecondsSince1970, me: me, groups: groups)
        }
    }

    // MARK: - Import

    /// Brings a group into the local database and returns its id.
    ///
    /// - Parameters:
    ///   - me: The local profile. It always ends up as a member of the imported group.
    ///   - asParticipant: The person in the file who is the user, if they are in it. Their entries are attributed
    ///     to `me`, so the balances read correctly on this iPhone.
    @discardableResult
    public func importGroup(
        _ snapshot: GroupSnapshot, mode: ImportMode, me: UUID, asParticipant: UUID? = nil
    ) async throws -> UUID {
        try snapshot.validate()
        if let asParticipant, !snapshot.participants.contains(where: { $0.id == asParticipant }) {
            throw SnapshotError.unknownParticipant(asParticipant)
        }
        return try await database.transaction { db in
            guard !(try db.query("SELECT 1 FROM users WHERE id = ?", [.text(me.uuidString)])).isEmpty else {
                throw DomainError.userNotFound(me)
            }
            let existing = try db.query("SELECT * FROM groups WHERE id = ?", [.text(snapshot.group.id.uuidString)]).first
            let replacing = mode == .updateExisting && existing != nil
            if let existing, replacing,
                Currency(code: existing.text("currency")) != snapshot.group.currency
            {
                throw SnapshotError.currencyMismatch
            }

            // Who each person in the file is on this iPhone.
            var identity: [UUID: UUID] = [:]
            for participant in snapshot.participants {
                if participant.id == me || participant.id == asParticipant {
                    identity[participant.id] = me
                } else {
                    identity[participant.id] = mode == .addAsCopy ? UUID() : participant.id
                }
            }
            let groupID = mode == .addAsCopy ? UUID() : snapshot.group.id
            let now = Date().millisecondsSince1970

            for participant in snapshot.participants {
                guard let id = identity[participant.id] else { continue }
                try Self.insertUserIfMissing(id: id, participant: participant, in: db)
            }
            if replacing {
                try db.execute("UPDATE groups SET name = ? WHERE id = ?", [.text(snapshot.group.name), .text(groupID.uuidString)])
                try Self.deleteExpenses(of: groupID, in: db)
            } else {
                try db.execute(
                    "INSERT INTO groups (id, name, currency, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
                    [
                        .text(groupID.uuidString), .text(snapshot.group.name), .text(snapshot.group.currency.code),
                        .text((identity[snapshot.group.createdBy] ?? me).uuidString),
                        .int(mode == .addAsCopy ? now : snapshot.group.createdAt),
                    ]
                )
            }
            for participant in snapshot.participants {
                guard let id = identity[participant.id] else { continue }
                try Self.insertMemberIfMissing(userID: id, groupID: groupID, now: now, in: db)
            }
            try Self.insertMemberIfMissing(userID: me, groupID: groupID, now: now, in: db)

            for expense in snapshot.expenses {
                var id = mode == .addAsCopy ? UUID() : expense.id
                // An id already used by another group's expense would clash; give this one a fresh id.
                if !(try db.query("SELECT 1 FROM expenses WHERE id = ?", [.text(id.uuidString)])).isEmpty { id = UUID() }
                try Self.insert(expense, as: id, groupID: groupID, currency: snapshot.group.currency, identity: identity, in: db)
            }
            return groupID
        }
    }

    // MARK: - Restore and delete

    /// Replaces everything on this iPhone with the backup. Returns the profile to continue as.
    @discardableResult
    public func restore(_ backup: BackupFile) async throws -> UUID {
        try backup.validate()
        return try await database.transaction { db in
            try Self.wipe(in: db)
            let now = Date().millisecondsSince1970
            try Self.insertUserIfMissing(id: backup.me.id, participant: backup.me, in: db)
            for snapshot in backup.groups {
                for participant in snapshot.participants {
                    try Self.insertUserIfMissing(id: participant.id, participant: participant, in: db)
                }
                try db.execute(
                    "INSERT INTO groups (id, name, currency, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
                    [
                        .text(snapshot.group.id.uuidString), .text(snapshot.group.name),
                        .text(snapshot.group.currency.code), .text(snapshot.group.createdBy.uuidString),
                        .int(snapshot.group.createdAt),
                    ]
                )
                for participant in snapshot.participants {
                    try Self.insertMemberIfMissing(userID: participant.id, groupID: snapshot.group.id, now: now, in: db)
                }
                let identity = Dictionary(uniqueKeysWithValues: snapshot.participants.map { ($0.id, $0.id) })
                for expense in snapshot.expenses {
                    var id = expense.id
                    if !(try db.query("SELECT 1 FROM expenses WHERE id = ?", [.text(id.uuidString)])).isEmpty { id = UUID() }
                    try Self.insert(
                        expense, as: id, groupID: snapshot.group.id, currency: snapshot.group.currency,
                        identity: identity, in: db
                    )
                }
            }
            return backup.me.id
        }
    }

    /// Removes every group, expense, participant and the profile from this iPhone.
    public func deleteAllData() async throws {
        try await database.transaction { db in try Self.wipe(in: db) }
    }

    // MARK: - Helpers

    private static func wipe(in db: isolated Database) throws {
        for table in ["expense_splits", "expenses", "group_members", "groups", "users", "pending_operation", "conflict"] {
            try db.execute("DELETE FROM \(table)")
        }
    }

    private static func deleteExpenses(of groupID: UUID, in db: isolated Database) throws {
        try db.execute(
            "DELETE FROM expense_splits WHERE expense_id IN (SELECT id FROM expenses WHERE group_id = ?)",
            [.text(groupID.uuidString)]
        )
        try db.execute("DELETE FROM expenses WHERE group_id = ?", [.text(groupID.uuidString)])
    }

    private static func insertUserIfMissing(
        id: UUID, participant: GroupSnapshot.Participant, in db: isolated Database
    ) throws {
        try db.execute(
            "INSERT OR IGNORE INTO users (id, name, email, created_at) VALUES (?, ?, ?, ?)",
            [
                .text(id.uuidString), .text(participant.name.trimmingCharacters(in: .whitespacesAndNewlines)),
                participant.email.flatMap { $0.isEmpty ? nil : $0 }.map(SQLValue.text) ?? .null,
                .int(participant.createdAt),
            ]
        )
    }

    private static func insertMemberIfMissing(
        userID: UUID, groupID: UUID, now: Int64, in db: isolated Database
    ) throws {
        try db.execute(
            "INSERT OR IGNORE INTO group_members (id, group_id, user_id, created_at) VALUES (?, ?, ?, ?)",
            [.text(UUID().uuidString), .text(groupID.uuidString), .text(userID.uuidString), .int(now)]
        )
    }

    private static func insert(
        _ expense: GroupSnapshot.ExpenseEntry, as id: UUID, groupID: UUID, currency: Currency,
        identity: [UUID: UUID], in db: isolated Database
    ) throws {
        guard let payer = identity[expense.paidBy] else { throw SnapshotError.unknownParticipant(expense.paidBy) }
        try db.execute(
            """
            INSERT INTO expenses (id, group_id, paid_by, title, amount_minor, currency, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id.uuidString), .text(groupID.uuidString), .text(payer.uuidString),
                .text(expense.title.trimmingCharacters(in: .whitespacesAndNewlines)), .int(expense.amountMinor),
                .text(currency.code), .int(expense.createdAt), .int(expense.updatedAt),
            ]
        )
        for split in expense.splits {
            guard let user = identity[split.userID] else { throw SnapshotError.unknownParticipant(split.userID) }
            try db.execute(
                "INSERT INTO expense_splits (id, expense_id, user_id, amount_minor) VALUES (?, ?, ?, ?)",
                [.text(UUID().uuidString), .text(id.uuidString), .text(user.uuidString), .int(split.amountMinor)]
            )
        }
    }

    private static func fetchSnapshot(groupID: UUID, in db: isolated Database) throws -> GroupSnapshot {
        let id = SQLValue.text(groupID.uuidString)
        guard let group = try db.query("SELECT * FROM groups WHERE id = ?", [id]).first else {
            throw DomainError.groupNotFound(groupID)
        }
        let participants = try db.query(
            """
            SELECT users.* FROM group_members
            JOIN users ON users.id = group_members.user_id
            WHERE group_members.group_id = ?
            ORDER BY group_members.rowid
            """,
            [id]
        ).map {
            GroupSnapshot.Participant(
                id: $0.uuid("id"), name: $0.text("name"), email: $0.optionalText("email"), createdAt: $0.int("created_at")
            )
        }

        var splitsByExpense: [UUID: [GroupSnapshot.SplitEntry]] = [:]
        let splitRows = try db.query(
            """
            SELECT expense_splits.* FROM expense_splits
            JOIN expenses ON expenses.id = expense_splits.expense_id
            WHERE expenses.group_id = ? AND expenses.deleted_at IS NULL
            ORDER BY expense_splits.rowid
            """,
            [id]
        )
        for row in splitRows {
            splitsByExpense[row.uuid("expense_id"), default: []]
                .append(.init(userID: row.uuid("user_id"), amountMinor: row.int("amount_minor")))
        }
        let expenses = try db.query(
            "SELECT * FROM expenses WHERE group_id = ? AND deleted_at IS NULL ORDER BY created_at, rowid", [id]
        ).map {
            GroupSnapshot.ExpenseEntry(
                id: $0.uuid("id"), paidBy: $0.uuid("paid_by"), title: $0.text("title"),
                amountMinor: $0.int("amount_minor"), createdAt: $0.int("created_at"), updatedAt: $0.int("updated_at"),
                splits: splitsByExpense[$0.uuid("id")] ?? []
            )
        }
        return GroupSnapshot(
            exportedAt: Date().millisecondsSince1970,
            group: .init(
                id: groupID, name: group.text("name"), currency: Currency(code: group.text("currency")) ?? .eur,
                createdBy: group.uuid("created_by"), createdAt: group.int("created_at")
            ),
            participants: participants,
            expenses: expenses
        )
    }
}
