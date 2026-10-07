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
