import Foundation

/// What the backend answers to an accepted operation: the row's new server-owned numbers.
public struct RemoteAck: Sendable, Equatable {
    public let version: Int64
    public let serverSeq: Int64
    /// Only present for groups.
    public let inviteCode: UUID?

    public init(version: Int64, serverSeq: Int64, inviteCode: UUID? = nil) {
        self.version = version
        self.serverSeq = serverSeq
        self.inviteCode = inviteCode
    }
}

public enum RemoteError: Error, Equatable, Sendable {
    /// No connection to the backend (or the request was cancelled). Nothing is known about the outcome.
    case offline
    /// The backend answered with an error. `sqlState` comes from the RPC, `status` from HTTP.
    case server(sqlState: String?, status: Int?, message: String)

    /// The server's current version carried by a `40001` error ("current version is N").
    var currentVersion: Int64? {
        guard case .server(let state, _, let message) = self, state == "40001" else { return nil }
        return message.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int64($0) }
    }
}

// MARK: - Rows as the backend returns them

public struct RemoteUser: Sendable, Equatable, Decodable {
    public let id: UUID
    public let name: String
    public let email: String?
    public let createdAt: Date
    public let version: Int64
    public let serverSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, email, version
        case createdAt = "created_at", serverSeq = "server_seq"
    }

    public init(id: UUID, name: String, email: String?, createdAt: Date, version: Int64, serverSeq: Int64) {
        self.id = id
        self.name = name
        self.email = email
        self.createdAt = createdAt
        self.version = version
        self.serverSeq = serverSeq
    }
}

public struct RemoteGroup: Sendable, Equatable, Decodable {
    public let id: UUID
    public let name: String
    public let currency: String
    public let createdBy: UUID
    public let createdAt: Date
    public let inviteCode: UUID?
    public let version: Int64
    public let serverSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, currency, version
        case createdBy = "created_by", createdAt = "created_at", inviteCode = "invite_code", serverSeq = "server_seq"
    }

    public init(
        id: UUID, name: String, currency: String, createdBy: UUID, createdAt: Date,
        inviteCode: UUID?, version: Int64, serverSeq: Int64
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.inviteCode = inviteCode
        self.version = version
        self.serverSeq = serverSeq
    }
}

public struct RemoteMember: Sendable, Equatable, Decodable {
    public let id: UUID
    public let groupID: UUID
    public let userID: UUID
    public let createdAt: Date
    public let version: Int64
    public let serverSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, version
        case groupID = "group_id", userID = "user_id", createdAt = "created_at", serverSeq = "server_seq"
    }

    public init(id: UUID, groupID: UUID, userID: UUID, createdAt: Date, version: Int64, serverSeq: Int64) {
        self.id = id
        self.groupID = groupID
        self.userID = userID
        self.createdAt = createdAt
        self.version = version
        self.serverSeq = serverSeq
    }
}

public struct RemoteExpense: Sendable, Equatable, Decodable {
    public struct Split: Sendable, Equatable, Decodable {
        public let id: UUID
        public let userID: UUID
        public let amountMinor: Int64

        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id", amountMinor = "amount_minor"
        }

        public init(id: UUID, userID: UUID, amountMinor: Int64) {
            self.id = id
            self.userID = userID
            self.amountMinor = amountMinor
        }
    }

    public let id: UUID
    public let groupID: UUID
    public let paidBy: UUID
    public let title: String
    public let amountMinor: Int64
    public let currency: String
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let version: Int64
    public let serverSeq: Int64
    public let splits: [Split]

    enum CodingKeys: String, CodingKey {
        case id, title, currency, version, splits
        case groupID = "group_id", paidBy = "paid_by", amountMinor = "amount_minor", createdAt = "created_at"
        case updatedAt = "updated_at", deletedAt = "deleted_at", serverSeq = "server_seq"
    }

    public init(
        id: UUID, groupID: UUID, paidBy: UUID, title: String, amountMinor: Int64, currency: String,
        createdAt: Date, updatedAt: Date, deletedAt: Date?, version: Int64, serverSeq: Int64, splits: [Split]
    ) {
        self.id = id
        self.groupID = groupID
        self.paidBy = paidBy
        self.title = title
        self.amountMinor = amountMinor
        self.currency = currency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.serverSeq = serverSeq
        self.splits = splits
    }
}

/// One row returned by `pull_changes`.
public enum RemoteChange: Sendable, Equatable {
    case user(RemoteUser)
    case group(RemoteGroup)
    case member(RemoteMember)
    case expense(RemoteExpense)

    public var serverSeq: Int64 {
        switch self {
        case .user(let row): row.serverSeq
        case .group(let row): row.serverSeq
        case .member(let row): row.serverSeq
        case .expense(let row): row.serverSeq
        }
    }
}

/// The only thing the sync engine knows about the network. Production uses `SupabaseBackend`; tests use
/// `InMemoryBackend`, which behaves like the SQL functions in `supabase/migrations`.
public protocol RemoteBackend: Sendable {
    /// Identifies the signed-in account, so local sync state is never mixed between accounts.
    func accountID() async throws -> String

    /// Delivers one operation. `baseVersion` is the version of the entity the device last saw (0 if it
    /// never synced); only expense updates use it.
    func send(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck

    /// Changes with `server_seq > since`, oldest first, at most `limit`.
    func pull(since: Int64, limit: Int, groupID: UUID?) async throws -> [RemoteChange]
}
