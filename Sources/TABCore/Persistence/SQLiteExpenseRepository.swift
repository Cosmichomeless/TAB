import Foundation

/// Local-first implementation of `ExpenseRepository` on top of SQLite.
public struct SQLiteExpenseRepository: ExpenseRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func createExpense(
        groupID: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        shares: [SplitShare]
    ) async throws -> Expense {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DomainError.emptyTitle }
        guard amountMinor > 0 else { throw DomainError.invalidAmount }
        guard !shares.isEmpty else { throw DomainError.noParticipants }

        var seen = Set<UUID>()
        for share in shares {
            guard seen.insert(share.userID).inserted else { throw DomainError.duplicateParticipant(share.userID) }
            guard share.amountMinor >= 0 else { throw DomainError.invalidAmount }
        }
        let total = shares.reduce(Int64(0)) { $0 + $1.amountMinor }
        guard total == amountMinor else {
            throw DomainError.splitsDoNotMatchAmount(expected: amountMinor, actual: total)
        }

        return try await database.transaction { db in
            guard let groupRow = try db.query(
                "SELECT currency FROM groups WHERE id = ?", [.text(groupID.uuidString)]
            ).first else {
                throw DomainError.groupNotFound(groupID)
            }
            for userID in [paidBy] + shares.map(\.userID) {
                try Self.requireMember(userID, of: groupID, in: db)
            }

            let expense = Expense(
                groupID: groupID,
                paidBy: paidBy,
                title: title,
                amountMinor: amountMinor,
                currency: Currency(code: groupRow.text("currency")) ?? .eur
            )
            try db.execute(
                """
                INSERT INTO expenses (id, group_id, paid_by, title, amount_minor, currency, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(expense.id.uuidString), .text(groupID.uuidString), .text(paidBy.uuidString),
                    .text(expense.title), .int(amountMinor), .text(expense.currency.code),
                    .int(expense.createdAt.millisecondsSince1970), .int(expense.updatedAt.millisecondsSince1970),
                ]
            )
            let splits = shares.map {
                ExpenseSplit(expenseID: expense.id, userID: $0.userID, amountMinor: $0.amountMinor)
            }
            for split in splits {
                try db.execute(
                    "INSERT INTO expense_splits (id, expense_id, user_id, amount_minor) VALUES (?, ?, ?, ?)",
                    [
                        .text(split.id.uuidString), .text(expense.id.uuidString),
                        .text(split.userID.uuidString), .int(split.amountMinor),
                    ]
                )
            }
            try OutboxStore.enqueue(
                .upsertExpense, entityID: expense.id, groupID: groupID,
                payload: UpsertExpensePayload(expense: expense, splits: splits), in: db
            )
            return expense
        }
    }

    public func updateExpense(
        id: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        shares: [SplitShare]
    ) async throws -> Expense {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DomainError.emptyTitle }
        guard amountMinor > 0 else { throw DomainError.invalidAmount }
        guard !shares.isEmpty else { throw DomainError.noParticipants }

        var seen = Set<UUID>()
        for share in shares {
            guard seen.insert(share.userID).inserted else { throw DomainError.duplicateParticipant(share.userID) }
            guard share.amountMinor >= 0 else { throw DomainError.invalidAmount }
        }
        let total = shares.reduce(Int64(0)) { $0 + $1.amountMinor }
        guard total == amountMinor else {
            throw DomainError.splitsDoNotMatchAmount(expected: amountMinor, actual: total)
        }

        return try await database.transaction { db in
            guard let row = try db.query(
                "SELECT * FROM expenses WHERE id = ? AND deleted_at IS NULL", [.text(id.uuidString)]
            ).first else {
                throw DomainError.expenseNotFound(id)
            }
            let groupID = row.uuid("group_id")
            for userID in [paidBy] + shares.map(\.userID) {
                try Self.requireMember(userID, of: groupID, in: db)
            }

            let now = Date().millisecondsSince1970
            try db.execute(
                "UPDATE expenses SET paid_by = ?, title = ?, amount_minor = ?, updated_at = ? WHERE id = ?",
                [.text(paidBy.uuidString), .text(title), .int(amountMinor), .int(now), .text(id.uuidString)]
            )
            // Splits are replaced with their expense; keeping the ids of people who stay in keeps the diff small.
            let previous = try db.query("SELECT * FROM expense_splits WHERE expense_id = ?", [.text(id.uuidString)])
                .map(Self.split)
            try db.execute("DELETE FROM expense_splits WHERE expense_id = ?", [.text(id.uuidString)])
            let splits = shares.map { share in
                ExpenseSplit(
                    id: previous.first { $0.userID == share.userID }?.id ?? UUID(),
                    expenseID: id, userID: share.userID, amountMinor: share.amountMinor
                )
            }
            for split in splits {
                try db.execute(
                    "INSERT INTO expense_splits (id, expense_id, user_id, amount_minor) VALUES (?, ?, ?, ?)",
                    [.text(split.id.uuidString), .text(id.uuidString), .text(split.userID.uuidString), .int(split.amountMinor)]
                )
            }
            let updated = Self.expense(try db.query("SELECT * FROM expenses WHERE id = ?", [.text(id.uuidString)])[0])
            try OutboxStore.enqueue(
                .upsertExpense, entityID: id, groupID: groupID,
                payload: UpsertExpensePayload(expense: updated, splits: splits), in: db
            )
            return updated
        }
    }

    public func expenses(in groupID: UUID) async throws -> [Expense] {
        try await database.query(
            """
            SELECT * FROM expenses
            WHERE group_id = ? AND deleted_at IS NULL
            ORDER BY created_at DESC, rowid DESC
            """,
            [.text(groupID.uuidString)]
        ).map(Self.expense)
    }

    public func splits(of expenseID: UUID) async throws -> [ExpenseSplit] {
        try await database.query(
            "SELECT * FROM expense_splits WHERE expense_id = ? ORDER BY rowid",
            [.text(expenseID.uuidString)]
        ).map(Self.split)
    }

    public func deleteExpense(id: UUID) async throws {
        try await database.transaction { db in
            guard let row = try db.query("SELECT * FROM expenses WHERE id = ?", [.text(id.uuidString)]).first else {
                throw DomainError.expenseNotFound(id)
            }
            guard row.optionalInt("deleted_at") == nil else { return }
            let now = Date().millisecondsSince1970
            try db.execute(
                "UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?",
                [.int(now), .int(now), .text(id.uuidString)]
            )
            var deleted = Self.expense(try db.query("SELECT * FROM expenses WHERE id = ?", [.text(id.uuidString)])[0])
            deleted.deletedAt = Date(timeIntervalSince1970: Double(now) / 1000)
            let splits = try db.query(
                "SELECT * FROM expense_splits WHERE expense_id = ? ORDER BY rowid", [.text(id.uuidString)]
            ).map(Self.split)
            try OutboxStore.enqueue(
                .upsertExpense, entityID: id, groupID: deleted.groupID,
                payload: UpsertExpensePayload(expense: deleted, splits: splits), in: db
            )
        }
    }

    public func changes() -> AsyncStream<Void> {
        database.changes()
    }

    // MARK: - Helpers

    private static func requireMember(_ userID: UUID, of groupID: UUID, in db: isolated Database) throws {
        let rows = try db.query(
            "SELECT 1 FROM group_members WHERE group_id = ? AND user_id = ?",
            [.text(groupID.uuidString), .text(userID.uuidString)]
        )
        guard !rows.isEmpty else { throw DomainError.notAMember(userID: userID, groupID: groupID) }
    }

    private static func split(_ row: Row) -> ExpenseSplit {
        ExpenseSplit(
            id: row.uuid("id"), expenseID: row.uuid("expense_id"),
            userID: row.uuid("user_id"), amountMinor: row.int("amount_minor")
        )
    }

    private static func expense(_ row: Row) -> Expense {
        Expense(
            id: row.uuid("id"),
            groupID: row.uuid("group_id"),
            paidBy: row.uuid("paid_by"),
            title: row.text("title"),
            amountMinor: row.int("amount_minor"),
            currency: Currency(code: row.text("currency")) ?? .eur,
            createdAt: row.date("created_at"),
            updatedAt: row.date("updated_at"),
            deletedAt: row.optionalInt("deleted_at").map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }
}
