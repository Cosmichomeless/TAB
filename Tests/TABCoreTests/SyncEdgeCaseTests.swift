import Foundation
import Testing
@testable import TABCore

/// A backend that fails with something that is not a `RemoteError`, like a decoding error would.
private struct BrokenBackend: RemoteBackend {
    struct Glitch: Error {}

    func accountID() async throws -> String { "account" }
    func send(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck { throw Glitch() }
    func pull(since: Int64, limit: Int, groupID: UUID?) async throws -> [RemoteChange] { [] }
}

/// A backend whose request is cancelled while it is in flight (the app is suspended, for example).
private struct CancellingBackend: RemoteBackend {
    func accountID() async throws -> String { "account" }
    func send(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck { throw CancellationError() }
    func pull(since: Int64, limit: Int, groupID: UUID?) async throws -> [RemoteChange] { [] }
}

@Suite("Sync edge cases")
struct SyncEdgeCaseTests {
    // MARK: - Engine

    @Test func anUnexpectedBackendErrorIsRetriedWithBackoffAndNeverDropsTheOperation() async throws {
        let database = try Database.inMemory()
        let clock = TestClock()
        let engine = SyncEngine(database: database, backend: BrokenBackend(), now: { clock.now })
        let outbox = OutboxStore(database: database)
        let groups = SQLiteGroupRepository(database: database)
        _ = try await groups.createUser(name: "David", email: nil)

        let report = await engine.sync()

        #expect(report.outcome == .completed)
        #expect(report.pushed == 0)
        #expect(report.retrying == 1)
        #expect(report.rejected == 0)
        #expect(report.nextRetryAt == clock.now.addingTimeInterval(RetryPolicy.standard.delay(afterFailedAttempts: 1)))
        let operation = try #require(try await outbox.operations().first)
        #expect(operation.status == .failed)
        #expect(operation.attempts == 1)

        // Still backing off: nothing is sent until the delay has passed.
        #expect(await engine.sync().retrying == 0)
        clock.advance(RetryPolicy.standard.delay(afterFailedAttempts: 1) + 1)
        #expect(await engine.sync().retrying == 1)
        #expect(try await outbox.operations().first?.attempts == 2)
    }

    @Test func aCancelledRequestLeavesTheOperationReadyToBeSentAgain() async throws {
        let database = try Database.inMemory()
        let engine = SyncEngine(database: database, backend: CancellingBackend())
        let outbox = OutboxStore(database: database)
        _ = try await SQLiteGroupRepository(database: database).createUser(name: "David", email: nil)

        let report = await engine.sync()

        // Cancellation says nothing about whether the server applied it: the operation goes back to the queue
        // without consuming an attempt, and the cycle stops.
        #expect(report.outcome != .completed)
        #expect(report.pushed == 0)
        let operation = try #require(try await outbox.operations().first)
        #expect(operation.status == .pending)
        #expect(operation.attempts == 0)
    }

    // MARK: - Outbox

    @Test func entityStatusesOfNothingIsEmpty() async throws {
        let outbox = OutboxStore(database: try Database.inMemory())
        #expect(try await outbox.statuses(of: []).isEmpty)
    }

    @Test(arguments: [
        (OperationKind.claimUser, "user"), (.upsertParticipant, "user"), (.createGroup, "group"),
        (.addMember, "group_member"), (.upsertExpense, "expense"),
    ])
    func everyOperationKindMapsToAnEntityType(kind: OperationKind, expected: String) {
        #expect(OutboxStore.entityType(of: kind) == expected)
    }

    // MARK: - Remote applier

    @Test func aMembershipCreatedUnderAnotherIDIsReplacedByTheServersRow() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        await device.engine.sync()
        let serverMembership = try #require(
            try await device.database.query(
                "SELECT id FROM group_members WHERE group_id = ? AND user_id = ?",
                [.text(trip.group.id.uuidString), .text(trip.ana.id.uuidString)]
            ).first?.uuid("id")
        )

        // Two devices added the same person: this one holds the membership under a different id.
        let localOnly = UUID()
        try await device.database.execute(
            "UPDATE group_members SET id = ?, version = 0 WHERE id = ?",
            [.text(localOnly.uuidString), .text(serverMembership.uuidString)]
        )
        await device.engine.sync()

        let memberships = try await device.database.query(
            "SELECT id FROM group_members WHERE group_id = ? AND user_id = ?",
            [.text(trip.group.id.uuidString), .text(trip.ana.id.uuidString)]
        )
        #expect(memberships.map { $0.uuid("id") } == [serverMembership])
        #expect(try await device.groups.members(of: trip.group.id).count == 2)
    }

    @Test func aMembershipWithUnsentChangesIsNotReplacedByTheServersRow() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        await device.engine.sync()
        let serverMembership = try #require(
            try await device.database.query(
                "SELECT id FROM group_members WHERE group_id = ? AND user_id = ?",
                [.text(trip.group.id.uuidString), .text(trip.ana.id.uuidString)]
            ).first?.uuid("id")
        )
        let localOnly = UUID()
        try await device.database.execute(
            "UPDATE group_members SET id = ? WHERE id = ?", [.text(localOnly.uuidString), .text(serverMembership.uuidString)]
        )
        // The local membership still has an operation waiting to be sent.
        try await device.database.execute(
            """
            INSERT INTO pending_operation (id, kind, entity_id, group_id, payload, status, created_at, updated_at)
            VALUES (?, 'addMember', ?, ?, '{}', 'sending', 0, 0)
            """,
            [.text(UUID().uuidString), .text(localOnly.uuidString), .text(trip.group.id.uuidString)]
        )

        let changes = try await device.backend.pull(since: 0, limit: 1000, groupID: nil)
        _ = try await device.database.transaction { db in try RemoteApplier.apply(changes, in: db) }

        let memberships = try await device.database.query(
            "SELECT id FROM group_members WHERE group_id = ? AND user_id = ?",
            [.text(trip.group.id.uuidString), .text(trip.ana.id.uuidString)]
        )
        #expect(memberships.map { $0.uuid("id") } == [localOnly])
    }

    // MARK: - Conflict resolver

    @Test func keepingTheLocalChangeNeedsTheServersVersionAndTheOperation() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server, conflictPolicy: .manual)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)
        await device.engine.sync()
        await server.editExpense(expense.id, title: "Edited elsewhere")
        try await device.expenses.deleteExpense(id: expense.id)
        await device.engine.sync()
        let conflict = try #require(try await device.resolver.conflicts(status: .open).first)

        // The server's version was not recorded.
        try await device.database.execute("UPDATE conflict SET remote_version = NULL WHERE id = ?", [.text(conflict.id.uuidString)])
        await #expect(throws: ConflictError.remoteVersionUnknown) { try await device.resolver.keepLocal(conflict.id) }

        // The operation that conflicted is gone.
        try await device.database.execute("UPDATE conflict SET remote_version = 2 WHERE id = ?", [.text(conflict.id.uuidString)])
        try await device.database.execute("DELETE FROM pending_operation WHERE id = ?", [.text(conflict.operationID.uuidString)])
        await #expect(throws: ConflictError.operationGone) { try await device.resolver.keepLocal(conflict.id) }

        // Failed attempts changed nothing: the conflict is still open.
        #expect(try await device.resolver.conflicts(status: .open).count == 1)
    }

    @Test func aLostChangeCannotBeRestoredOnAnExpenseThatNoLongerExists() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)
        await device.engine.sync()
        await server.editExpense(expense.id, title: "Edited elsewhere")
        try await device.expenses.deleteExpense(id: expense.id)
        await device.engine.sync()
        let conflict = try #require(try await device.resolver.conflicts().first)

        try await device.database.execute("DELETE FROM expense_splits WHERE expense_id = ?", [.text(expense.id.uuidString)])
        try await device.database.execute("DELETE FROM expenses WHERE id = ?", [.text(expense.id.uuidString)])

        await #expect(throws: ConflictError.entityGone) { try await device.resolver.restoreLocal(conflict.id) }
        #expect(try await device.resolver.conflicts().first?.resolution == .remoteWins)
    }
}
