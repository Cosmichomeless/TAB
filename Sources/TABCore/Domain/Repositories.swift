import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case emptyName
    case invalidEmail
    case groupNotFound(UUID)
    case userNotFound(UUID)
    case alreadyMember(userID: UUID, groupID: UUID)
    case emptyTitle
    case invalidAmount
    case noParticipants
    case duplicateParticipant(UUID)
    case notAMember(userID: UUID, groupID: UUID)
    case splitsDoNotMatchAmount(expected: Int64, actual: Int64)
    case expenseNotFound(UUID)
}

public protocol UserRepository: Sendable {
    func createUser(name: String, email: String?) async throws -> User
    func user(id: UUID) async throws -> User?
}

public protocol GroupRepository: Sendable {
    /// Creates a group and adds its creator as the first member.
    func createGroup(name: String, currency: Currency, createdBy: UUID) async throws -> Group
    func groups() async throws -> [Group]
    func group(id: UUID) async throws -> Group?

    /// Members of a group, ordered by when they joined.
    func members(of groupID: UUID) async throws -> [User]

    /// Creates a participant and adds them to the group.
    func addParticipant(name: String, email: String?, to groupID: UUID) async throws -> User

    /// Emits a value every time local data changes.
    func changes() -> AsyncStream<Void>
}

public protocol ExpenseRepository: Sendable {
    /// Records an expense in the group's currency. `shares` must cover the selected participants
    /// and add up exactly to `amountMinor`. Payer and participants must be group members.
    func createExpense(
        groupID: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        shares: [SplitShare]
    ) async throws -> Expense

    /// Live (not deleted) expenses of a group, newest first.
    func expenses(in groupID: UUID) async throws -> [Expense]

    func splits(of expenseID: UUID) async throws -> [ExpenseSplit]

    /// Soft-deletes an expense. Deleting an already deleted expense is a no-op.
    func deleteExpense(id: UUID) async throws

    /// Emits a value every time local data changes.
    func changes() -> AsyncStream<Void>
}
