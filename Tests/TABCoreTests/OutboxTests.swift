import Foundation
import Testing
@testable import TABCore

@Suite("Outbox and sync state machine")
struct OutboxTests {
    struct Fixture {
        let database: Database
        let groups: SQLiteGroupRepository
        let expenses: SQLiteExpenseRepository
        let outbox: OutboxStore
    }

    private func makeFixture(policy: RetryPolicy = .standard) throws -> Fixture {
        let database = try Database.inMemory()
        return Fixture(
            database: database,
            groups: SQLiteGroupRepository(database: database),
            expenses: SQLiteExpenseRepository(database: database),
            outbox: OutboxStore(database: database, retryPolicy: policy)
        )
    }

    // MARK: - Enqueueing

    @Test func localWritesEnqueueOperationsInOrder() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let group = try await f.groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await f.groups.addParticipant(name: "Ana", email: nil, to: group.id)
        _ = try await f.expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Dinner", amountMinor: 3000,
            shares: [SplitShare(userID: david.id, amountMinor: 1500), SplitShare(userID: ana.id, amountMinor: 1500)]
        )

        let kinds = try await f.outbox.operations().map(\.kind)
        #expect(kinds == [.claimUser, .createGroup, .addMember, .upsertParticipant, .addMember, .upsertExpense])
        #expect(try await f.outbox.operations().allSatisfy { $0.status == .pending })
    }

    @Test func failedWriteLeavesNoOperation() async throws {
        let f = try makeFixture()
        _ = try? await f.groups.createGroup(name: "Ghost", currency: .eur, createdBy: UUID())
        #expect(try await f.outbox.operations().isEmpty)
    }

    @Test func expensePayloadCarriesTheFullAggregate() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let group = try await f.groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let expense = try await f.expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Taxi", amountMinor: 1200,
            shares: [SplitShare(userID: david.id, amountMinor: 1200)]
        )

        let operation = try #require(try await f.outbox.operations().last)
        let payload = try JSONDecoder().decode(UpsertExpensePayload.self, from: operation.payload)
        let localSplits = try await f.expenses.splits(of: expense.id)
        #expect(operation.entityID == expense.id)
        #expect(operation.groupID == group.id)
        #expect(payload.amountMinor == 1200)
        #expect(payload.deletedAt == nil)
        #expect(payload.splits.map(\.id) == localSplits.map(\.id))
    }

    @Test func deletingAnExpenseEnqueuesTheTombstone() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let group = try await f.groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let expense = try await f.expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Taxi", amountMinor: 1200,
            shares: [SplitShare(userID: david.id, amountMinor: 1200)]
        )

        try await f.expenses.deleteExpense(id: expense.id)
        try await f.expenses.deleteExpense(id: expense.id) // already deleted: no second operation

        let upserts = try await f.outbox.operations().filter { $0.kind == .upsertExpense }
        #expect(upserts.count == 2)
        let payload = try JSONDecoder().decode(UpsertExpensePayload.self, from: upserts[1].payload)
        #expect(payload.deletedAt != nil)
        #expect(payload.splits.count == 1)
    }

    // MARK: - Ordering

    @Test func sendsOneGroupInOrderAndOtherGroupsIndependently() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let first = try await f.groups.createGroup(name: "A", currency: .eur, createdBy: david.id)
        let second = try await f.groups.createGroup(name: "B", currency: .eur, createdBy: david.id)

        // Only the user claim is eligible: it has no group and blocks everything after it.
        var batch = try await f.outbox.nextBatch()
        #expect(batch.map(\.kind) == [.claimUser])
        try await f.outbox.markDone(batch[0].id)

        // Now the head of each group is eligible, but not the creator's membership behind the group.
        batch = try await f.outbox.nextBatch()
        #expect(batch.map(\.entityID) == [first.id, second.id])
        #expect(batch.allSatisfy { $0.kind == .createGroup })
    }

    @Test func aFailingOperationHoldsBackItsGroupOnly() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let first = try await f.groups.createGroup(name: "A", currency: .eur, createdBy: david.id)
        let second = try await f.groups.createGroup(name: "B", currency: .eur, createdBy: david.id)
        let claim = try #require(try await f.outbox.nextBatch().first)
        try await f.outbox.markDone(claim.id)

        let heads = try await f.outbox.nextBatch()
        let firstHead = try #require(heads.first { $0.entityID == first.id })
        let secondHead = try #require(heads.first { $0.entityID == second.id })
        try await f.outbox.markSending(firstHead.id)
        try await f.outbox.markFailed(firstHead.id, error: "offline")
        try await f.outbox.markDone(secondHead.id)

        let next = try await f.outbox.nextBatch()
        #expect(next.map(\.groupID) == [second.id]) // A is backing off; B moves on
        #expect(next.first?.kind == .addMember)
    }

    @Test func rejectedOperationBlocksLaterOnesUntilRequeued() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let claim = try #require(try await f.outbox.nextBatch().first)
        try await f.outbox.markRejected(claim.id, error: "invalid")

        _ = try await f.groups.createGroup(name: "A", currency: .eur, createdBy: david.id)
        #expect(try await f.outbox.nextBatch().isEmpty)

        try await f.outbox.requeue(claim.id)
        #expect(try await f.outbox.nextBatch().map(\.id) == [claim.id])
    }

    // MARK: - Transitions

    @Test func failureBacksOffExponentiallyAndCountsAttempts() async throws {
        let f = try makeFixture(policy: RetryPolicy(base: 10, cap: 25))
        _ = try await f.groups.createUser(name: "David", email: nil)
        let operation = try #require(try await f.outbox.nextBatch().first)
        let now = Date()

        let first = try await f.outbox.markFailed(operation.id, error: "timeout", now: now)
        let second = try await f.outbox.markFailed(operation.id, error: "timeout", now: now)
        let third = try await f.outbox.markFailed(operation.id, error: "timeout", now: now)

        #expect(first.timeIntervalSince(now) == 10)
        #expect(second.timeIntervalSince(now) == 20)
        #expect(third.timeIntervalSince(now) == 25) // capped
        let stored = try #require(try await f.outbox.operations().first)
        #expect(stored.attempts == 3)
        #expect(stored.lastError == "timeout")
        #expect(try await f.outbox.nextBatch(now: now).isEmpty) // still backing off
        #expect(try await f.outbox.nextBatch(now: now.addingTimeInterval(26)).count == 1)
    }

    @Test func unauthenticatedDoesNotConsumeAnAttempt() async throws {
        let f = try makeFixture()
        _ = try await f.groups.createUser(name: "David", email: nil)
        let operation = try #require(try await f.outbox.nextBatch().first)

        try await f.outbox.markSending(operation.id)
        try await f.outbox.markUnauthenticated(operation.id)

        let stored = try #require(try await f.outbox.operations().first)
        #expect(stored.status == .pending)
        #expect(stored.attempts == 0)
        #expect(try await f.outbox.nextBatch().count == 1)
    }

    @Test func interruptedOperationsAreRecoveredAfterRestart() async throws {
        let f = try makeFixture()
        _ = try await f.groups.createUser(name: "David", email: nil)
        let operation = try #require(try await f.outbox.nextBatch().first)
        try await f.outbox.markSending(operation.id)
        #expect(try await f.outbox.nextBatch().isEmpty)

        #expect(try await f.outbox.recoverInterrupted() == 1)

        #expect(try await f.outbox.operations().first?.status == .pending)
        #expect(try await f.outbox.nextBatch().count == 1)
    }

    @Test func doneOperationsArePurgedOnlyWhenOld() async throws {
        let f = try makeFixture()
        _ = try await f.groups.createUser(name: "David", email: nil)
        let operation = try #require(try await f.outbox.nextBatch().first)
        try await f.outbox.markDone(operation.id)

        try await f.outbox.purgeDone(before: Date().addingTimeInterval(-3600))
        #expect(try await f.outbox.operations().count == 1)
        try await f.outbox.purgeDone(before: Date().addingTimeInterval(60))
        #expect(try await f.outbox.operations().isEmpty)
    }

    // MARK: - Derived status

    @Test func entityStatusIsTheMostSevereOfItsOperations() async throws {
        #expect(SyncStatus(operations: []) == .synced)
        #expect(SyncStatus(operations: [.done, .done]) == .synced)
        #expect(SyncStatus(operations: [.done, .sending]) == .pending)
        #expect(SyncStatus(operations: [.pending, .failed]) == .failed)
        #expect(SyncStatus(operations: [.failed, .conflict, .pending]) == .conflict)
        #expect(SyncStatus(operation: .rejected) == .failed)
    }

    @Test func reportsStatusPerEntityAndSummary() async throws {
        let f = try makeFixture()
        let david = try await f.groups.createUser(name: "David", email: nil)
        let group = try await f.groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let claim = try #require(try await f.outbox.nextBatch().first)

        #expect(try await f.outbox.statuses(of: [david.id, group.id])[david.id] == .pending)
        try await f.outbox.markDone(claim.id)
        let statuses = try await f.outbox.statuses(of: [david.id, group.id, UUID()])
        #expect(statuses[david.id] == .synced)
        #expect(statuses[group.id] == .pending)

        let creation = try #require(try await f.outbox.nextBatch().first)
        try await f.outbox.markConflict(creation.id, error: "version")
        #expect(try await f.outbox.statuses(of: [group.id])[group.id] == .conflict)
        let summary = try await f.outbox.summary()
        #expect(summary.conflicts == 1)
        #expect(summary.pending == 1) // the creator's membership is queued behind it
        #expect(!summary.isFullySynced)
    }

    // MARK: - Error classification

    @Test func classifiesBackendErrors() {
        #expect(FailureClass.classify(sqlState: "40001") == .conflict)
        #expect(FailureClass.classify(sqlState: "28000") == .unauthenticated)
        #expect(FailureClass.classify(sqlState: "42501") == .permanent)
        #expect(FailureClass.classify(sqlState: "22023") == .permanent)
        #expect(FailureClass.classify(sqlState: "23505") == .permanent)
        #expect(FailureClass.classify(sqlState: "P0002") == .retry)
        #expect(FailureClass.classify(sqlState: nil, httpStatus: 401) == .unauthenticated)
        #expect(FailureClass.classify(sqlState: nil, httpStatus: 503) == .retry)
        #expect(FailureClass.classify(sqlState: nil, httpStatus: 429) == .retry)
        #expect(FailureClass.classify(sqlState: nil, httpStatus: nil) == .retry)
        #expect(FailureClass.classify(sqlState: "XX000", httpStatus: 500) == .retry)
    }

    @Test func backoffGrowsAndIsCapped() {
        let policy = RetryPolicy(base: 2, cap: 300)
        #expect(policy.delay(afterFailedAttempts: 1) == 2)
        #expect(policy.delay(afterFailedAttempts: 2) == 4)
        #expect(policy.delay(afterFailedAttempts: 5) == 32)
        #expect(policy.delay(afterFailedAttempts: 50) == 300)
    }

    // MARK: - Schema

    @Test func migrationCreatesSyncStateRow() async throws {
        let database = try Database.inMemory()
        let rows = try await database.query("SELECT cursor FROM sync_state WHERE id = 1")
        #expect(rows.first?.int("cursor") == 0)
        let version = try await database.query("PRAGMA user_version").first?.int("user_version")
        #expect(version == Int64(Migrator.migrations.count))
    }
}
