import Foundation

/// What a pending operation asks the backend to do. Each kind maps to one RPC (see `docs/architecture/backend.md`).
/// Operations are *state based*: the payload is the full desired state of the entity, never a delta, so
/// replaying an operation is harmless and the latest one wins naturally.
public enum OperationKind: String, Sendable, Codable, CaseIterable {
    /// Registers the account holder's own user (`claim_user`).
    case claimUser
    case upsertParticipant
    case createGroup
    case addMember
    case upsertExpense
}

/// Lifecycle of one outbox entry.
///
/// ```text
/// pending ──send──▶ sending ──ack──▶ done
///    ▲                 │
///    │  transient error├──────▶ failed ──(next_attempt_at reached)──▶ sending
///    └──── app restart ┘            (retryable, backoff)
///                      ├──────▶ rejected   (permanent error, needs attention)
///                      └──────▶ conflict   (entity changed remotely, see `conflict` table)
/// ```
public enum OperationStatus: String, Sendable, Codable {
    case pending, sending, failed, rejected, conflict, done

    /// Still has to reach the backend (or is waiting for a decision).
    public var isUnfinished: Bool { self != .done }
}

/// One durable entry of the outbox.
public struct PendingOperation: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Position in the outbox. Operations of the same group are sent in `seq` order.
    public let seq: Int64
    public let kind: OperationKind
    public let entityID: UUID
    /// Groups the operations that must be delivered in order. `nil` blocks every later operation.
    public let groupID: UUID?
    /// JSON of the matching `*Payload` type.
    public let payload: Data
    public var status: OperationStatus
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public let createdAt: Date
}

/// What the UI shows for an entity. Derived from its operations, never stored on the entity.
public enum SyncStatus: String, Sendable, Codable, Comparable {
    case synced, pending, failed, conflict

    private var rank: Int {
        switch self {
        case .synced: 0
        case .pending: 1
        case .failed: 2
        case .conflict: 3
        }
    }

    public static func < (lhs: SyncStatus, rhs: SyncStatus) -> Bool { lhs.rank < rhs.rank }

    /// The status of an entity is the most severe status among its operations.
    public init(operations: [OperationStatus]) {
        self = operations.map(SyncStatus.init(operation:)).max() ?? .synced
    }

    public init(operation: OperationStatus) {
        switch operation {
        case .done: self = .synced
        case .pending, .sending: self = .pending
        case .failed, .rejected: self = .failed
        case .conflict: self = .conflict
        }
    }
}

// MARK: - Payloads (full desired state; dates are milliseconds since the epoch)

public struct UpsertParticipantPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let email: String?
    public let createdAt: Int64
}

public struct CreateGroupPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let currency: String
    public let createdBy: UUID
    public let createdAt: Int64
}

public struct AddMemberPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let groupID: UUID
    public let userID: UUID
    public let createdAt: Int64
}

public struct UpsertExpensePayload: Codable, Sendable, Equatable {
    public struct Split: Codable, Sendable, Equatable {
        public let id: UUID
        public let userID: UUID
        public let amountMinor: Int64
    }

    public let id: UUID
    public let groupID: UUID
    public let paidBy: UUID
    public let title: String
    public let amountMinor: Int64
    public let createdAt: Int64
    public let updatedAt: Int64
    public let deletedAt: Int64?
    public let splits: [Split]
}

extension UpsertParticipantPayload {
    init(user: User) { self.init(id: user.id, name: user.name, email: user.email, createdAt: user.createdAt.millisecondsSince1970) }
}

extension CreateGroupPayload {
    init(group: Group) {
        self.init(
            id: group.id, name: group.name, currency: group.currency.code, createdBy: group.createdBy,
            createdAt: group.createdAt.millisecondsSince1970
        )
    }
}

extension AddMemberPayload {
    init(member: GroupMember) {
        self.init(id: member.id, groupID: member.groupID, userID: member.userID, createdAt: member.createdAt.millisecondsSince1970)
    }
}

extension UpsertExpensePayload {
    init(expense: Expense, splits: [ExpenseSplit]) {
        self.init(
            id: expense.id, groupID: expense.groupID, paidBy: expense.paidBy, title: expense.title,
            amountMinor: expense.amountMinor, createdAt: expense.createdAt.millisecondsSince1970,
            updatedAt: expense.updatedAt.millisecondsSince1970,
            deletedAt: expense.deletedAt?.millisecondsSince1970,
            splits: splits.map { Split(id: $0.id, userID: $0.userID, amountMinor: $0.amountMinor) }
        )
    }
}

extension UpsertExpensePayload {
    /// The server's copy of an expense, in the same shape as a local operation so both sides can be compared.
    init(remote: RemoteExpense) {
        self.init(
            id: remote.id, groupID: remote.groupID, paidBy: remote.paidBy, title: remote.title,
            amountMinor: remote.amountMinor, createdAt: remote.createdAt.millisecondsSince1970,
            updatedAt: remote.updatedAt.millisecondsSince1970, deletedAt: remote.deletedAt?.millisecondsSince1970,
            splits: remote.splits.map { Split(id: $0.id, userID: $0.userID, amountMinor: $0.amountMinor) }
        )
    }
}
