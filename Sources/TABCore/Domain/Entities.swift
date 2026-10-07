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

extension Date {
    /// Dates are persisted with millisecond precision; truncating at creation keeps
    /// entities equal to what is read back from storage.
    var truncatedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
