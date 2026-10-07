import Foundation

/// Local-first implementation of the user and group repositories on top of SQLite.
public struct SQLiteGroupRepository: GroupRepository, UserRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - UserRepository

    public func createUser(name: String, email: String?) async throws -> User {
        let user = User(name: try Self.validName(name), email: try Self.validEmail(email))
        try await database.execute(
            "INSERT INTO users (id, name, email, created_at) VALUES (?, ?, ?, ?)",
            [.text(user.id.uuidString), .text(user.name), Self.value(user.email), .int(user.createdAt.millisecondsSince1970)]
        )
        return user
    }

    public func user(id: UUID) async throws -> User? {
        try await database.query("SELECT * FROM users WHERE id = ?", [.text(id.uuidString)])
            .first.map(Self.user)
    }

    // MARK: - GroupRepository

    public func createGroup(name: String, currency: Currency, createdBy: UUID) async throws -> Group {
        let group = Group(name: try Self.validName(name), currency: currency, createdBy: createdBy)
        try await database.transaction { db in
            try Self.requireUser(createdBy, in: db)
            try db.execute(
                "INSERT INTO groups (id, name, currency, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(group.id.uuidString), .text(group.name), .text(group.currency.code),
                    .text(createdBy.uuidString), .int(group.createdAt.millisecondsSince1970),
                ]
            )
            try Self.insertMember(userID: createdBy, groupID: group.id, in: db)
        }
        return group
    }

    public func groups() async throws -> [Group] {
        try await database.query("SELECT * FROM groups ORDER BY created_at DESC, id").map(Self.group)
    }

    public func group(id: UUID) async throws -> Group? {
        try await database.query("SELECT * FROM groups WHERE id = ?", [.text(id.uuidString)])
            .first.map(Self.group)
    }

    public func members(of groupID: UUID) async throws -> [User] {
        try await database.query(
            """
            SELECT users.* FROM group_members
            JOIN users ON users.id = group_members.user_id
            WHERE group_members.group_id = ?
            ORDER BY group_members.rowid
            """,
            [.text(groupID.uuidString)]
        ).map(Self.user)
    }

    public func addParticipant(name: String, email: String?, to groupID: UUID) async throws -> User {
        let user = User(name: try Self.validName(name), email: try Self.validEmail(email))
        try await database.transaction { db in
            guard !(try db.query("SELECT 1 FROM groups WHERE id = ?", [.text(groupID.uuidString)])).isEmpty else {
                throw DomainError.groupNotFound(groupID)
            }
            try db.execute(
                "INSERT INTO users (id, name, email, created_at) VALUES (?, ?, ?, ?)",
                [.text(user.id.uuidString), .text(user.name), Self.value(user.email), .int(user.createdAt.millisecondsSince1970)]
            )
            try Self.insertMember(userID: user.id, groupID: groupID, in: db)
        }
        return user
    }

    public func changes() -> AsyncStream<Void> {
        database.changes()
    }

    // MARK: - Helpers

    private static func requireUser(_ id: UUID, in db: isolated Database) throws {
        guard !(try db.query("SELECT 1 FROM users WHERE id = ?", [.text(id.uuidString)])).isEmpty else {
            throw DomainError.userNotFound(id)
        }
    }

    private static func insertMember(userID: UUID, groupID: UUID, in db: isolated Database) throws {
        let member = GroupMember(groupID: groupID, userID: userID)
        try db.execute(
            "INSERT INTO group_members (id, group_id, user_id, created_at) VALUES (?, ?, ?, ?)",
            [
                .text(member.id.uuidString), .text(groupID.uuidString), .text(userID.uuidString),
                .int(member.createdAt.millisecondsSince1970),
            ]
        )
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DomainError.emptyName }
        return trimmed
    }

    private static func validEmail(_ email: String?) throws -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else {
            throw DomainError.invalidEmail
        }
        return email
    }

    private static func value(_ text: String?) -> SQLValue {
        text.map(SQLValue.text) ?? .null
    }

    private static func user(_ row: Row) -> User {
        User(id: row.uuid("id"), name: row.text("name"), email: row.optionalText("email"), createdAt: row.date("created_at"))
    }

    private static func group(_ row: Row) -> Group {
        Group(
            id: row.uuid("id"),
            name: row.text("name"),
            currency: Currency(code: row.text("currency")) ?? .eur,
            createdBy: row.uuid("created_by"),
            createdAt: row.date("created_at")
        )
    }
}
