import Foundation
import SQLite3

/// Numbered schema migrations. Version N is `Migrator.migrations[N - 1]`.
/// Never edit a migration that has shipped; append a new one instead.
enum Migrator {
    static let migrations: [String] = [
        // 1 — users, groups and memberships
        """
        CREATE TABLE users (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            email TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE groups (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            currency TEXT NOT NULL,
            created_by TEXT NOT NULL REFERENCES users(id),
            created_at INTEGER NOT NULL
        );

        CREATE TABLE group_members (
            id TEXT PRIMARY KEY NOT NULL,
            group_id TEXT NOT NULL REFERENCES groups(id),
            user_id TEXT NOT NULL REFERENCES users(id),
            created_at INTEGER NOT NULL,
            UNIQUE (group_id, user_id)
        );

        CREATE INDEX group_members_group ON group_members(group_id);
        """,
        // 2 — expenses and their splits
        """
        CREATE TABLE expenses (
            id TEXT PRIMARY KEY NOT NULL,
            group_id TEXT NOT NULL REFERENCES groups(id),
            paid_by TEXT NOT NULL REFERENCES users(id),
            title TEXT NOT NULL,
            amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
            currency TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER
        );

        CREATE INDEX expenses_group ON expenses(group_id, created_at);

        CREATE TABLE expense_splits (
            id TEXT PRIMARY KEY NOT NULL,
            expense_id TEXT NOT NULL REFERENCES expenses(id),
            user_id TEXT NOT NULL REFERENCES users(id),
            amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
            UNIQUE (expense_id, user_id)
        );

        CREATE INDEX expense_splits_expense ON expense_splits(expense_id);
        """,
        // 3 — synchronization: server versions, outbox, pull cursor and conflicts
        """
        ALTER TABLE users ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE users ADD COLUMN server_seq INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE groups ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE groups ADD COLUMN server_seq INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE groups ADD COLUMN invite_code TEXT;
        ALTER TABLE group_members ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE group_members ADD COLUMN server_seq INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE expenses ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE expenses ADD COLUMN server_seq INTEGER NOT NULL DEFAULT 0;

        CREATE TABLE pending_operation (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            group_id TEXT,
            payload TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'sending', 'failed', 'rejected', 'conflict', 'done')),
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX pending_operation_status ON pending_operation(status, seq);
        CREATE INDEX pending_operation_entity ON pending_operation(entity_id);

        CREATE TABLE sync_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            cursor INTEGER NOT NULL DEFAULT 0,
            account_id TEXT,
            last_pulled_at INTEGER,
            last_pushed_at INTEGER,
            last_error TEXT
        );

        INSERT INTO sync_state (id) VALUES (1);

        CREATE TABLE conflict (
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            local_payload TEXT NOT NULL,
            remote_payload TEXT,
            remote_version INTEGER,
            status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
            resolution TEXT,
            created_at INTEGER NOT NULL,
            resolved_at INTEGER
        );

        CREATE INDEX conflict_entity ON conflict(entity_id, status);
        """,
    ]

    static func migrate(_ connection: OpaquePointer) throws {
        let current = try Database.query("PRAGMA user_version", [], on: connection)
            .first.map { Int($0.int("user_version")) } ?? 0

        for version in stride(from: current + 1, through: migrations.count, by: 1) {
            try Database.run("BEGIN IMMEDIATE", on: connection)
            do {
                for statement in migrations[version - 1].split(separator: ";") {
                    let sql = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sql.isEmpty { try Database.run(sql, on: connection) }
                }
                try Database.run("PRAGMA user_version = \(version)", on: connection)
                try Database.run("COMMIT", on: connection)
            } catch {
                try? Database.run("ROLLBACK", on: connection)
                throw error
            }
        }
    }
}
