import Foundation
import Testing
@testable import TABCore

@Suite("Local groups and participants")
struct GroupRepositoryTests {
    private func makeRepository() async throws -> SQLiteGroupRepository {
        SQLiteGroupRepository(database: try Database.inMemory())
    }

    @Test func createsGroupWithCreatorAsFirstMember() async throws {
        let repository = try await makeRepository()
        let david = try await repository.createUser(name: "David", email: "david@example.com")

        let group = try await repository.createGroup(name: "Lisbon Trip", currency: .eur, createdBy: david.id)

        let members = try await repository.members(of: group.id)
        #expect(members.map(\.id) == [david.id])
        #expect(try await repository.groups() == [group])
    }

    @Test func addsParticipantsInJoinOrder() async throws {
        let repository = try await makeRepository()
        let david = try await repository.createUser(name: "David", email: nil)
        let group = try await repository.createGroup(name: "Lisbon Trip", currency: .eur, createdBy: david.id)

        let ana = try await repository.addParticipant(name: "Ana", email: nil, to: group.id)
        let marta = try await repository.addParticipant(name: "  Marta ", email: "marta@example.com", to: group.id)

        let members = try await repository.members(of: group.id)
        #expect(members.map(\.name) == ["David", "Ana", "Marta"])
        #expect(members.map(\.id) == [david.id, ana.id, marta.id])
        #expect(marta.name == "Marta")
        #expect(ana.email == nil)
    }

    @Test func rejectsInvalidInput() async throws {
        let repository = try await makeRepository()
        let david = try await repository.createUser(name: "David", email: nil)
        let group = try await repository.createGroup(name: "Trip", currency: .eur, createdBy: david.id)

        await #expect(throws: DomainError.emptyName) {
            try await repository.createGroup(name: "   ", currency: .eur, createdBy: david.id)
        }
        await #expect(throws: DomainError.emptyName) {
            try await repository.addParticipant(name: "", email: nil, to: group.id)
        }
        await #expect(throws: DomainError.invalidEmail) {
            try await repository.addParticipant(name: "Ana", email: "not-an-email", to: group.id)
        }
        let unknown = UUID()
        await #expect(throws: DomainError.groupNotFound(unknown)) {
            try await repository.addParticipant(name: "Ana", email: nil, to: unknown)
        }
        await #expect(throws: DomainError.userNotFound(unknown)) {
            try await repository.createGroup(name: "Ghost", currency: .eur, createdBy: unknown)
        }
    }

    @Test func failedWritesLeaveNoPartialData() async throws {
        let repository = try await makeRepository()
        let unknown = UUID()

        _ = try? await repository.createGroup(name: "Ghost", currency: .eur, createdBy: unknown)

        #expect(try await repository.groups().isEmpty)
    }

    @Test func dataSurvivesRelaunch() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let groupID: UUID
        do {
            let repository = SQLiteGroupRepository(database: try Database(path: path))
            let david = try await repository.createUser(name: "David", email: nil)
            let group = try await repository.createGroup(name: "Lisbon Trip", currency: .usd, createdBy: david.id)
            _ = try await repository.addParticipant(name: "Ana", email: nil, to: group.id)
            groupID = group.id
        }

        let reopened = SQLiteGroupRepository(database: try Database(path: path))
        let groups = try await reopened.groups()
        #expect(groups.map(\.id) == [groupID])
        #expect(groups.first?.currency == .usd)
        #expect(try await reopened.members(of: groupID).map(\.name) == ["David", "Ana"])
    }

    @Test func notifiesObserversOnWrite() async throws {
        let repository = try await makeRepository()
        let changes = repository.changes()
        let david = try await repository.createUser(name: "David", email: nil)

        _ = try await repository.createGroup(name: "Trip", currency: .eur, createdBy: david.id)

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }
}
