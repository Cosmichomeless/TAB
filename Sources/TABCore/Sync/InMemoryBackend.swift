import Foundation

/// A backend that lives in memory and follows the rules of `supabase/migrations/20261007000200_rpc.sql`:
/// state-based idempotent writes, `version` 1 on insert and +1 per change, a global `server_seq`, optimistic
/// concurrency on expenses, membership based visibility, and the same SQLSTATEs.
///
/// One `InMemoryServer` can serve several `InMemoryBackend`s (one per simulated device or account), which is
/// how the multi-device tests and the offline demo work without a real Supabase project.
public actor InMemoryServer {
    struct UserRow {
        var id: UUID, name: String, email: String?, ownerAuth: UUID, authUser: UUID?
        var createdAt: Date, version: Int64, serverSeq: Int64
    }
    struct GroupRow {
        var id: UUID, name: String, currency: String, createdBy: UUID, createdAt: Date
        var inviteCode: UUID, version: Int64, serverSeq: Int64
    }
    struct MemberRow {
        var id: UUID, groupID: UUID, userID: UUID, createdAt: Date, version: Int64, serverSeq: Int64
    }

    private var users: [UUID: UserRow] = [:]
    private var groups: [UUID: GroupRow] = [:]
    private var members: [UUID: MemberRow] = [:]
    private var expenses: [UUID: RemoteExpense] = [:]
    private var sequence: Int64 = 0

    public init() {}

    // MARK: - Inspection (tests)

    public var expenseRows: [RemoteExpense] { expenses.values.sorted { $0.serverSeq < $1.serverSeq } }
    public var memberCount: Int { members.count }
    public var userCount: Int { users.count }
    public var groupCount: Int { groups.count }
    public var currentSequence: Int64 { sequence }

    // MARK: - Writes (one per RPC)

    func claimUser(_ p: UpsertParticipantPayload, as auth: UUID) throws -> RemoteAck {
        let name = try Self.requireName(p.name)
        let email = Self.normalized(p.email)
        if users.values.contains(where: { $0.authUser == auth && $0.id != p.id }) {
            throw Self.error("42501", "account is already linked to another user")
        }
        if var row = users[p.id] {
            if row.authUser == auth {
                if row.name != name || row.email != email { row.name = name; row.email = email; touch(&row) }
            } else if row.authUser == nil, row.ownerAuth == auth {
                row.name = name; row.email = email; row.authUser = auth; touch(&row)
            } else {
                throw Self.error("42501", "user belongs to another account")
            }
            users[p.id] = row
            return Self.ack(row)
        }
        var row = UserRow(
            id: p.id, name: name, email: email, ownerAuth: auth, authUser: auth, createdAt: Self.date(p.createdAt),
            version: 0, serverSeq: 0
        )
        touch(&row, inserting: true)
        users[p.id] = row
        return Self.ack(row)
    }

    func upsertParticipant(_ p: UpsertParticipantPayload, as auth: UUID) throws -> RemoteAck {
        guard callerUserID(auth) != nil else { throw Self.error("42501", "claim your user before adding participants") }
        let name = try Self.requireName(p.name)
        let email = Self.normalized(p.email)
        if var row = users[p.id] {
            guard row.ownerAuth == auth else { throw Self.error("42501", "user belongs to another account") }
            if row.name != name || row.email != email { row.name = name; row.email = email; touch(&row) }
            users[p.id] = row
            return Self.ack(row)
        }
        var row = UserRow(
            id: p.id, name: name, email: email, ownerAuth: auth, authUser: nil, createdAt: Self.date(p.createdAt),
            version: 0, serverSeq: 0
        )
        touch(&row, inserting: true)
        users[p.id] = row
        return Self.ack(row)
    }

    func createGroup(_ p: CreateGroupPayload, as auth: UUID) throws -> RemoteAck {
        guard p.createdBy == callerUserID(auth) else { throw Self.error("42501", "groups can only be created by the caller") }
        let name = try Self.requireName(p.name)
        guard ["EUR", "USD", "GBP", "JPY"].contains(p.currency) else {
            throw Self.error("22023", "unsupported currency \(p.currency)")
        }
        if let row = groups[p.id] {
            guard row.name == name, row.currency == p.currency, row.createdBy == p.createdBy else {
                throw Self.error("23505", "group id already exists with different data")
            }
            return Self.ack(row)
        }
        var row = GroupRow(
            id: p.id, name: name, currency: p.currency, createdBy: p.createdBy, createdAt: Self.date(p.createdAt),
            inviteCode: UUID(), version: 0, serverSeq: 0
        )
        touch(&row, inserting: true)
        groups[p.id] = row
        return Self.ack(row)
    }

    func addMember(_ p: AddMemberPayload, as auth: UUID) throws -> RemoteAck {
        guard let group = groups[p.groupID] else { throw Self.error("P0002", "group not found") }
        guard isMember(auth, of: p.groupID) || group.createdBy == callerUserID(auth) else {
            throw Self.error("42501", "not allowed to add members to this group")
        }
        guard let user = users[p.userID], user.ownerAuth == auth || user.authUser == auth else {
            throw Self.error("42501", "user not found or not owned by the caller")
        }
        if let existing = members.values.first(where: { $0.groupID == p.groupID && $0.userID == p.userID }) {
            guard existing.id == p.id else {
                throw Self.error("23505", "user is already a member with a different membership id")
            }
            return Self.ack(existing)
        }
        guard members[p.id] == nil else { throw Self.error("23505", "membership id already used") }
        var row = MemberRow(
            id: p.id, groupID: p.groupID, userID: p.userID, createdAt: Self.date(p.createdAt), version: 0, serverSeq: 0
        )
        touch(&row, inserting: true)
        members[p.id] = row
        return Self.ack(row)
    }

    func upsertExpense(_ p: UpsertExpensePayload, baseVersion: Int64, as auth: UUID) throws -> RemoteAck {
        guard let group = groups[p.groupID] else { throw Self.error("P0002", "group not found") }
        guard isMember(auth, of: p.groupID) else { throw Self.error("42501", "not a member of this group") }
        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Self.error("22023", "title is required") }
        guard p.amountMinor > 0 else { throw Self.error("22023", "amount must be greater than zero") }
        let memberIDs = Set(members.values.filter { $0.groupID == p.groupID }.map(\.userID))
        guard memberIDs.contains(p.paidBy) else { throw Self.error("22023", "payer is not a member of the group") }
        guard !p.splits.isEmpty else { throw Self.error("22023", "at least one split is required") }
        guard Set(p.splits.map(\.userID)).count == p.splits.count else {
            throw Self.error("22023", "duplicate participant in splits")
        }
        guard p.splits.allSatisfy({ $0.amountMinor >= 0 && memberIDs.contains($0.userID) }) else {
            throw Self.error("22023", "invalid split")
        }
        guard p.splits.reduce(0, { $0 + $1.amountMinor }) == p.amountMinor else {
            throw Self.error("22023", "splits do not add up to the amount")
        }

        let splits = p.splits.map { RemoteExpense.Split(id: $0.id, userID: $0.userID, amountMinor: $0.amountMinor) }
        let deletedAt = p.deletedAt.map(Self.date)
        if let current = expenses[p.id] {
            guard current.groupID == p.groupID else { throw Self.error("22023", "expense belongs to another group") }
            let sameSplits = Set(current.splits.map { "\($0.userID)|\($0.amountMinor)" })
                == Set(splits.map { "\($0.userID)|\($0.amountMinor)" })
            if current.paidBy == p.paidBy, current.title == title, current.amountMinor == p.amountMinor,
               current.deletedAt == deletedAt, sameSplits {
                return RemoteAck(version: current.version, serverSeq: current.serverSeq)
            }
            guard baseVersion == current.version else {
                throw Self.error("40001", "version conflict: current version is \(current.version)")
            }
            sequence += 1
            let updated = RemoteExpense(
                id: p.id, groupID: p.groupID, paidBy: p.paidBy, title: title, amountMinor: p.amountMinor,
                currency: group.currency, createdAt: current.createdAt, updatedAt: Self.date(p.updatedAt),
                deletedAt: deletedAt, version: current.version + 1, serverSeq: sequence, splits: splits
            )
            expenses[p.id] = updated
            return RemoteAck(version: updated.version, serverSeq: updated.serverSeq)
        }
        guard baseVersion == 0 else { throw Self.error("P0002", "expense not found") }
        sequence += 1
        let created = RemoteExpense(
            id: p.id, groupID: p.groupID, paidBy: p.paidBy, title: title, amountMinor: p.amountMinor,
            currency: group.currency, createdAt: Self.date(p.createdAt), updatedAt: Self.date(p.updatedAt),
            deletedAt: deletedAt, version: 1, serverSeq: sequence, splits: splits
        )
        expenses[p.id] = created
        return RemoteAck(version: 1, serverSeq: sequence)
    }

    // MARK: - Pull

    func pull(since: Int64, limit: Int, groupID: UUID?, as auth: UUID) -> [RemoteChange] {
        let visibleGroups = Set(groups.keys.filter { isMember(auth, of: $0) })
        var changes: [RemoteChange] = []

        for row in users.values where row.serverSeq > since {
            if let groupID {
                guard members.values.contains(where: { $0.groupID == groupID && $0.userID == row.id }) else { continue }
            } else {
                let sharesGroup = members.values.contains { $0.userID == row.id && visibleGroups.contains($0.groupID) }
                guard row.ownerAuth == auth || row.authUser == auth || sharesGroup else { continue }
            }
            changes.append(.user(RemoteUser(
                id: row.id, name: row.name, email: row.email, createdAt: row.createdAt,
                version: row.version, serverSeq: row.serverSeq
            )))
        }
        for row in groups.values where row.serverSeq > since && visibleGroups.contains(row.id) && (groupID == nil || row.id == groupID) {
            changes.append(.group(RemoteGroup(
                id: row.id, name: row.name, currency: row.currency, createdBy: row.createdBy, createdAt: row.createdAt,
                inviteCode: row.inviteCode, version: row.version, serverSeq: row.serverSeq
            )))
        }
        for row in members.values where row.serverSeq > since && visibleGroups.contains(row.groupID) && (groupID == nil || row.groupID == groupID) {
            changes.append(.member(RemoteMember(
                id: row.id, groupID: row.groupID, userID: row.userID, createdAt: row.createdAt,
                version: row.version, serverSeq: row.serverSeq
            )))
        }
        for row in expenses.values where row.serverSeq > since && visibleGroups.contains(row.groupID) && (groupID == nil || row.groupID == groupID) {
            changes.append(.expense(row))
        }
        changes.sort { $0.serverSeq < $1.serverSeq }
        return Array(changes.prefix(limit))
    }

    // MARK: - Test hooks

    /// Changes an expense as if another device had edited it, bumping its version.
    public func editExpense(_ id: UUID, title: String) {
        guard let current = expenses[id] else { return }
        sequence += 1
        expenses[id] = RemoteExpense(
            id: id, groupID: current.groupID, paidBy: current.paidBy, title: title, amountMinor: current.amountMinor,
            currency: current.currency, createdAt: current.createdAt, updatedAt: Date(),
            deletedAt: current.deletedAt, version: current.version + 1, serverSeq: sequence, splits: current.splits
        )
    }

    // MARK: - Helpers

    func callerUserID(_ auth: UUID) -> UUID? {
        users.values.first { $0.authUser == auth }?.id
    }

    private func isMember(_ auth: UUID, of groupID: UUID) -> Bool {
        guard let user = callerUserID(auth) else { return false }
        return members.values.contains { $0.groupID == groupID && $0.userID == user }
    }

    private func touch(_ row: inout UserRow, inserting: Bool = false) {
        sequence += 1
        row.serverSeq = sequence
        row.version = inserting ? 1 : row.version + 1
    }

    private func touch(_ row: inout GroupRow, inserting: Bool = false) {
        sequence += 1
        row.serverSeq = sequence
        row.version = inserting ? 1 : row.version + 1
    }

    private func touch(_ row: inout MemberRow, inserting: Bool = false) {
        sequence += 1
        row.serverSeq = sequence
        row.version = inserting ? 1 : row.version + 1
    }

    private static func ack(_ row: UserRow) -> RemoteAck { RemoteAck(version: row.version, serverSeq: row.serverSeq) }
    private static func ack(_ row: GroupRow) -> RemoteAck {
        RemoteAck(version: row.version, serverSeq: row.serverSeq, inviteCode: row.inviteCode)
    }
    private static func ack(_ row: MemberRow) -> RemoteAck { RemoteAck(version: row.version, serverSeq: row.serverSeq) }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static func requireName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw error("22023", "name is required") }
        return trimmed
    }

    private static func normalized(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func error(_ sqlState: String, _ message: String) -> RemoteError {
        .server(sqlState: sqlState, status: sqlState == "40001" ? 409 : 400, message: message)
    }
}

/// One simulated device (and account) talking to an `InMemoryServer`, with controllable failures.
public actor InMemoryBackend: RemoteBackend {
    /// Something that goes wrong with a call to `send`.
    public enum Fault: Sendable, Equatable {
        /// The request fails before the server sees it.
        case fail(RemoteError)
        /// The server applies the operation but the response never arrives: the device sees `offline`.
        case loseResponse
    }

    public let account: UUID
    private let server: InMemoryServer
    private var online = true
    private var signedIn = true
    private var faults: [Fault] = []
    private var pullFailure: RemoteError?

    /// Operation ids in the order the device sent them, including retries.
    public private(set) var sentOperations: [UUID] = []
    public private(set) var pullRequests: [Int64] = []

    public init(server: InMemoryServer, account: UUID = UUID()) {
        self.server = server
        self.account = account
    }

    public func setOnline(_ online: Bool) { self.online = online }
    public func setSignedIn(_ signedIn: Bool) { self.signedIn = signedIn }
    /// Faults are consumed by successive calls to `send`, one each, oldest first.
    public func inject(_ faults: Fault...) { self.faults.append(contentsOf: faults) }
    public func failNextPull(with error: RemoteError) { pullFailure = error }

    public func accountID() async throws -> String {
        try requireConnection()
        return account.uuidString
    }

    public func send(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck {
        sentOperations.append(operation.id)
        try requireConnection()
        var lostResponse = false
        if !faults.isEmpty {
            switch faults.removeFirst() {
            case .fail(let error): throw error
            case .loseResponse: lostResponse = true
            }
        }
        let ack = try await apply(operation, baseVersion: baseVersion)
        if lostResponse { throw RemoteError.offline }
        return ack
    }

    public func pull(since: Int64, limit: Int, groupID: UUID?) async throws -> [RemoteChange] {
        try requireConnection()
        pullRequests.append(since)
        if let failure = pullFailure {
            pullFailure = nil
            throw failure
        }
        return await server.pull(since: since, limit: limit, groupID: groupID, as: account)
    }

    private func requireConnection() throws {
        guard online else { throw RemoteError.offline }
        guard signedIn else { throw RemoteError.server(sqlState: "28000", status: 401, message: "not authenticated") }
    }

    private func apply(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck {
        let decoder = JSONDecoder()
        do {
            switch operation.kind {
            case .claimUser:
                return try await server.claimUser(try decoder.decode(UpsertParticipantPayload.self, from: operation.payload), as: account)
            case .upsertParticipant:
                return try await server.upsertParticipant(try decoder.decode(UpsertParticipantPayload.self, from: operation.payload), as: account)
            case .createGroup:
                return try await server.createGroup(try decoder.decode(CreateGroupPayload.self, from: operation.payload), as: account)
            case .addMember:
                return try await server.addMember(try decoder.decode(AddMemberPayload.self, from: operation.payload), as: account)
            case .upsertExpense:
                return try await server.upsertExpense(
                    try decoder.decode(UpsertExpensePayload.self, from: operation.payload), baseVersion: baseVersion, as: account
                )
            }
        } catch is DecodingError {
            throw RemoteError.server(sqlState: "22023", status: 400, message: "unreadable operation payload")
        }
    }
}
