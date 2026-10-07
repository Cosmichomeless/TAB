import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case emptyName
    case invalidEmail
    case groupNotFound(UUID)
    case userNotFound(UUID)
    case alreadyMember(userID: UUID, groupID: UUID)
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
