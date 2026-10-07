import Foundation

public struct User: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    /// `nil` for participants who do not have an account.
    public var email: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, email: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.email = email
        self.createdAt = createdAt.truncatedToMilliseconds
    }
}

public struct Group: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public let currency: Currency
    public let createdBy: UUID
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        currency: Currency,
        createdBy: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.createdBy = createdBy
        self.createdAt = createdAt.truncatedToMilliseconds
    }
}

public struct GroupMember: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let groupID: UUID
    public let userID: UUID
    public let createdAt: Date

    public init(id: UUID = UUID(), groupID: UUID, userID: UUID, createdAt: Date = Date()) {
        self.id = id
        self.groupID = groupID
        self.userID = userID
        self.createdAt = createdAt.truncatedToMilliseconds
    }
}

public struct Expense: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let groupID: UUID
    public var paidBy: UUID
    public var title: String
    /// Total in minor units of `currency`. Always greater than zero.
    public var amountMinor: Int64
    public let currency: Currency
    public let createdAt: Date
    public var updatedAt: Date
    /// Soft delete marker, so deletions can synchronize.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        groupID: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        currency: Currency,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.paidBy = paidBy
        self.title = title
        self.amountMinor = amountMinor
        self.currency = currency
        self.createdAt = createdAt.truncatedToMilliseconds
        self.updatedAt = (updatedAt ?? createdAt).truncatedToMilliseconds
        self.deletedAt = deletedAt?.truncatedToMilliseconds
    }
}

public struct ExpenseSplit: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let expenseID: UUID
    public let userID: UUID
    public let amountMinor: Int64

    public init(id: UUID = UUID(), expenseID: UUID, userID: UUID, amountMinor: Int64) {
        self.id = id
        self.expenseID = expenseID
        self.userID = userID
        self.amountMinor = amountMinor
    }
}

/// One participant's share, before the expense it belongs to exists.
public struct SplitShare: Hashable, Sendable {
    public let userID: UUID
    public let amountMinor: Int64

    public init(userID: UUID, amountMinor: Int64) {
        self.userID = userID
        self.amountMinor = amountMinor
    }
}

extension Date {
    /// Dates are persisted with millisecond precision; truncating at creation keeps
    /// entities equal to what is read back from storage.
    var truncatedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
