import Foundation
import Testing
@testable import TABCore

@Suite("Sync engine")
struct SyncEngineTests {
    // MARK: - Push

    @Test func offlineWritesAreSentWhenTheConnectionReturns() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        await device.backend.setOnline(false)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)

        let offline = await device.engine.sync()
        #expect(offline.outcome == .offline)
        #expect(try await device.outbox.operations().allSatisfy { $0.status == .pending && $0.attempts == 0 })
        #expect(await server.expenseRows.isEmpty)

        await device.backend.setOnline(true)
        let online = await device.engine.sync()
        #expect(online.outcome == .completed)
        #expect(online.pushed == 6)
        #expect(try await device.outbox.operations().allSatisfy { $0.status == .done })
        #expect(try await device.outbox.statuses(of: [expense.id])[expense.id] == .synced)
        #expect(try await device.version(of: expense.id) == 1)
        #expect(await server.expenseRows.map(\.id) == [expense.id])
        #expect(await server.memberCount == 2)
    }

    @Test func replayingAnAcknowledgedOperationIsHarmless() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)
        await device.engine.sync()
        let sequence = await server.currentSequence

        for operation in try await device.outbox.operations() { try await device.outbox.requeue(operation.id) }
        let report = await device.engine.sync()

        #expect(report.outcome == .completed)
        #expect(report.pushed == 6)
        #expect(await server.currentSequence == sequence)
        #expect(await server.expenseRows.count == 1)
        #expect(try await device.version(of: expense.id) == 1)
    }

    @Test func aLostResponseNeverDuplicatesTheExpense() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        await device.engine.sync()

        let expense = try await device.addExpense(trip)
        await device.backend.inject(.loseResponse)
        let lost = await device.engine.sync()
        #expect(lost.outcome == .offline)
        #expect(await server.expenseRows.count == 1)
        #expect(try await device.outbox.operations(status: .pending).count == 1)

        let retried = await device.engine.sync()
        #expect(retried.outcome == .completed)
        #expect(await server.expenseRows.count == 1)
        #expect(try await device.version(of: expense.id) == 1)
        #expect(try await device.outbox.statuses(of: [expense.id])[expense.id] == .synced)
    }

    @Test func transientFailuresBackOffExponentially() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let start = device.clock.now
        _ = try await device.groups.createUser(name: "David", email: nil)

        await device.backend.inject(.fail(serviceUnavailable), .fail(serviceUnavailable))
        let first = await device.engine.sync()
        #expect(first.retrying == 1)
        #expect(first.nextRetryAt == start.addingTimeInterval(2))
        #expect(try await device.outbox.operations().first?.status == .failed)

        // Not eligible yet: nothing is sent.
        _ = await device.engine.sync()
        #expect(await device.backend.sentOperations.count == 1)

        device.clock.advance(2)
        let second = await device.engine.sync()
        #expect(second.retrying == 1)
        #expect(second.nextRetryAt == start.addingTimeInterval(2 + 4))
        #expect(try await device.outbox.operations().first?.attempts == 2)

        device.clock.advance(3)
        _ = await device.engine.sync()
        #expect(await device.backend.sentOperations.count == 2)

        device.clock.advance(1)
        let third = await device.engine.sync()
        #expect(third.outcome == .completed)
        #expect(third.pushed == 1)
        #expect(third.nextRetryAt == nil)
        #expect(await server.userCount == 1)
    }

    @Test func anExpiredSessionPausesWithoutConsumingAttempts() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        _ = try await device.makeTrip()

        await device.backend.setSignedIn(false)
        let signedOut = await device.engine.sync()
        #expect(signedOut.outcome == .unauthenticated)

        // A 401 in the middle of a cycle leaves the operation pending, too.
        await device.backend.setSignedIn(true)
        await device.backend.inject(.fail(.server(sqlState: "28000", status: 401, message: "jwt expired")))
        let expired = await device.engine.sync()
        #expect(expired.outcome == .unauthenticated)
        #expect(try await device.outbox.operations().allSatisfy { $0.status == .pending && $0.attempts == 0 })

        let resumed = await device.engine.sync()
        #expect(resumed.outcome == .completed)
        #expect(try await device.outbox.operations().allSatisfy { $0.status == .done })
    }

    @Test func aRejectedOperationHoldsLaterOperationsOfItsGroup() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        await device.engine.sync()

        let first = try await device.addExpense(trip, title: "First")
        let second = try await device.addExpense(trip, title: "Second")
        await device.backend.inject(.fail(.server(sqlState: "22023", status: 400, message: "invalid")))
        let report = await device.engine.sync()

        #expect(report.rejected == 1)
        #expect(try await device.outbox.statuses(of: [first.id])[first.id] == .failed)
        #expect(try await device.outbox.statuses(of: [second.id])[second.id] == .pending)
        #expect(await server.expenseRows.isEmpty)

        // Retrying the rejected operation releases the rest.
        let rejected = try #require(try await device.outbox.operations(status: .rejected).first)
        try await device.outbox.requeue(rejected.id)
        let after = await device.engine.sync()
        #expect(after.outcome == .completed)
        #expect(await server.expenseRows.map(\.title) == ["First", "Second"])
    }

    @Test func unreadablePayloadsAreRejectedNotRetriedForever() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        _ = try await device.groups.createUser(name: "David", email: nil)
        try await device.database.execute("UPDATE pending_operation SET payload = '{\"nope\":1}'")

        let report = await device.engine.sync()
        #expect(report.rejected == 1)
        #expect(report.retrying == 0)
        #expect(try await device.outbox.operations().first?.status == .rejected)
    }

    // MARK: - Conflicts

    @Test func underTheManualPolicyAConcurrentEditStaysOpenWithBothVersionsRecorded() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server, conflictPolicy: .manual)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip, title: "Dinner")
        await device.engine.sync()

        await server.editExpense(expense.id, title: "Dinner (edited elsewhere)")
        try await device.expenses.deleteExpense(id: expense.id)
        let report = await device.engine.sync()

        #expect(report.conflicts == 1)
        #expect(report.outcome == .completed)
        #expect(try await device.outbox.statuses(of: [expense.id])[expense.id] == .conflict)
        let conflicts = try await device.database.query("SELECT * FROM conflict WHERE status = 'open'")
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.uuid("entity_id") == expense.id)
        #expect(conflicts.first?.text("entity_type") == "expense")
        #expect(conflicts.first?.optionalInt("remote_version") == 2)
        #expect(report.resolved == 0)

        // Both sides are recorded: the user's deletion and the server's edit.
        let recorded = try await device.resolver.conflicts(status: .open)
        #expect(recorded.first?.local?.deletedAt != nil)
        #expect(recorded.first?.local?.title == "Dinner")
        #expect(recorded.first?.remote?.title == "Dinner (edited elsewhere)")
        #expect(recorded.first?.remote?.deletedAt == nil)

        // The pull skips the entity while it has an unfinished operation: the local change is not overwritten.
        #expect(try await device.title(of: expense.id) == "Dinner")
        #expect(try await device.version(of: expense.id) == 1)

        // Syncing again does not pile up duplicates.
        await device.engine.sync()
        #expect(try await device.count("conflict") == 1)
    }

    @Test func theServerVersionWinsByDefaultAndTheLocalChangeIsKept() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip, title: "Dinner")
        await device.engine.sync()

        await server.editExpense(expense.id, title: "Dinner (edited elsewhere)")
        try await device.expenses.deleteExpense(id: expense.id)
        let report = await device.engine.sync()

        #expect(report.outcome == .completed)
        #expect(report.conflicts == 1)
        #expect(report.resolved == 1)

        // The device now shows what the server has, and nothing is waiting any more.
        #expect(try await device.title(of: expense.id) == "Dinner (edited elsewhere)")
        #expect(try await device.version(of: expense.id) == 2)
        #expect(try await device.outbox.operations().filter { $0.status.isUnfinished }.isEmpty)
        #expect(try await device.outbox.statuses(of: [expense.id])[expense.id] == .synced)
        #expect(try await device.outbox.summary().isFullySynced)
        #expect(try await device.expenses.expenses(in: trip.group.id).map(\.title) == ["Dinner (edited elsewhere)"])

        // The change that lost is still on record.
        let all = try await device.resolver.conflicts()
        #expect(all.count == 1)
        #expect(all.first?.status == .resolved)
        #expect(all.first?.resolution == .remoteWins)
        #expect(all.first?.local?.deletedAt != nil)
        #expect(all.first?.remote?.title == "Dinner (edited elsewhere)")
        #expect(all.first?.remoteVersion == 2)

        // Another cycle changes nothing.
        let again = await device.engine.sync()
        #expect(again.resolved == 0)
        #expect(again.conflicts == 0)
        #expect(try await device.count("conflict") == 1)
    }

    @Test func aChangeThatLostCanBeRestoredOnTopOfTheServerVersion() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip, title: "Dinner")
        await device.engine.sync()
        await server.editExpense(expense.id, title: "Dinner (edited elsewhere)")
        try await device.expenses.deleteExpense(id: expense.id)
        await device.engine.sync()

        let conflict = try #require(try await device.resolver.conflicts().first)
        try await device.resolver.restoreLocal(conflict.id)

        // Locally the deletion is back immediately and queued for the server.
        #expect(try await device.expenses.expenses(in: trip.group.id).isEmpty)
        #expect(try await device.outbox.statuses(of: [expense.id])[expense.id] == .pending)

        let report = await device.engine.sync()
        #expect(report.conflicts == 0)
        #expect(report.pushed == 1)
        let remote = try #require(await server.expenseRows.first { $0.id == expense.id })
        #expect(remote.deletedAt != nil)
        #expect(remote.version == 3)
        #expect(try await device.version(of: expense.id) == 3)
        #expect(try await device.resolver.conflicts().first?.resolution == .restored)

        // Restoring twice is refused.
        await #expect(throws: ConflictError.notRestorable) { try await device.resolver.restoreLocal(conflict.id) }
    }

    @Test func keepingTheLocalChangeOverwritesTheServerOnPurpose() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server, conflictPolicy: .manual)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip, title: "Dinner")
        await device.engine.sync()
        await server.editExpense(expense.id, title: "Dinner (edited elsewhere)")
        try await device.expenses.deleteExpense(id: expense.id)
        await device.engine.sync()

        // Still open after more cycles: manual means manual.
        await device.engine.sync()
        let conflict = try #require(try await device.resolver.conflicts(status: .open).first)

        try await device.resolver.keepLocal(conflict.id)
        let report = await device.engine.sync()

        #expect(report.conflicts == 0)
        #expect(report.pushed == 1)
        let remote = try #require(await server.expenseRows.first { $0.id == expense.id })
        #expect(remote.deletedAt != nil)
        #expect(remote.version == 3)
        #expect(try await device.resolver.conflicts().first?.resolution == .keepLocal)
        #expect(try await device.outbox.summary().isFullySynced)

        await #expect(throws: ConflictError.notOpen) { try await device.resolver.keepLocal(conflict.id) }
    }

    @Test func keepingTheLocalChangeNeedsTheServerVersion() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server, conflictPolicy: .manual)
        await #expect(throws: ConflictError.notFound) { try await device.resolver.keepLocal(UUID()) }
    }

    @Test func twoDevicesThatChangeTheSameExpenseDifferentlyConverge() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        let expense = try await first.addExpense(trip, title: "Dinner")
        await first.engine.sync()
        let second = try Device(server: server, account: account)
        await second.engine.sync()

        // The second device's edit reaches the server first (there is no edit screen yet, so the test hook
        // stands in for it); the first device deletes the expense from a stale copy.
        await server.editExpense(expense.id, title: "Dinner (edited)")
        try await first.expenses.deleteExpense(id: expense.id)
        let report = await first.engine.sync()
        await second.engine.sync()

        #expect(report.conflicts == 1)
        #expect(report.resolved == 1)
        for device in [first, second] {
            #expect(try await device.title(of: expense.id) == "Dinner (edited)")
            #expect(try await device.version(of: expense.id) == 2)
            #expect(try await device.expenses.expenses(in: trip.group.id).count == 1)
            #expect(try await device.outbox.summary().isFullySynced)
        }
    }

    @Test func theSameChangeOnTwoDevicesIsNotAConflict() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        let expense = try await first.addExpense(trip)
        await first.engine.sync()
        let second = try Device(server: server, account: account)
        await second.engine.sync()

        // Both delete it while offline. The backend sees the second request as a replay of the first.
        try await first.expenses.deleteExpense(id: expense.id)
        try await second.expenses.deleteExpense(id: expense.id)
        // Deletions are stamped with the wall clock, and the backend compares the stamp to recognise a replay.
        // Give both the same instant, or the test would depend on the two calls landing in one millisecond.
        let deletedAt = try #require(
            try await first.database.query("SELECT deleted_at FROM expenses WHERE id = ?", [.text(expense.id.uuidString)])
                .first?.optionalInt("deleted_at")
        )
        try await second.database.execute(
            "UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?",
            [.int(deletedAt), .int(deletedAt), .text(expense.id.uuidString)]
        )
        try await second.database.execute(
            """
            UPDATE pending_operation SET payload = json_set(payload, '$.deletedAt', ?, '$.updatedAt', ?)
            WHERE entity_id = ? AND status = 'pending'
            """,
            [.int(deletedAt), .int(deletedAt), .text(expense.id.uuidString)]
        )
        await second.engine.sync()
        let report = await first.engine.sync()
        await second.engine.sync()

        #expect(report.conflicts == 0)
        #expect(report.resolved == 0)
        #expect(try await first.count("conflict") == 0)
        #expect(try await first.version(of: expense.id) == (try await second.version(of: expense.id)))
        #expect(try await first.expenses.expenses(in: trip.group.id).isEmpty)
        #expect(try await second.expenses.expenses(in: trip.group.id).isEmpty)
    }

    @Test func resolvingAConflictReleasesTheOperationsItWasHoldingBack() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip, title: "Dinner")
        await device.engine.sync()

        await server.editExpense(expense.id, title: "Dinner (edited elsewhere)")
        try await device.expenses.deleteExpense(id: expense.id)
        let later = try await device.addExpense(trip, title: "Taxi", amountMinor: 1200)
        let report = await device.engine.sync()

        // The taxi was queued behind the conflicting operation and goes out in the same cycle.
        #expect(report.resolved == 1)
        #expect(await server.expenseRows.contains { $0.id == later.id })
        #expect(try await device.outbox.summary().isFullySynced)
    }

    // MARK: - Pull

    @Test func anotherDevicePullsEverythingInDependencyOrder() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        let expense = try await first.addExpense(trip)
        await first.engine.sync()

        let second = try Device(server: server, account: account)
        let report = await second.engine.sync()

        #expect(report.outcome == .completed)
        #expect(report.pulled > 0)
        #expect(try await second.count("users") == 2)
        #expect(try await second.count("groups") == 1)
        #expect(try await second.count("group_members") == 2)
        #expect(try await second.expenses.splits(of: expense.id).map(\.amountMinor).sorted() == [1500, 1500])
        #expect(try await second.version(of: expense.id) == 1)
        #expect(try await second.outbox.operations().isEmpty)
    }

    @Test func pullAppliesOnlyNewerVersionsAndTheOverlapIsHarmless() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        let expense = try await first.addExpense(trip, title: "Dinner")
        await first.engine.sync()

        let second = try Device(server: server, account: account)
        await second.engine.sync()

        // Same data again (the overlap re-reads it): nothing is applied.
        let again = await second.engine.sync()
        #expect(again.pulled == 0)
        #expect(await second.backend.pullRequests.last == 0)

        await server.editExpense(expense.id, title: "Dinner at Luigi's")
        let edited = await second.engine.sync()
        #expect(edited.pulled == 1)
        #expect(try await second.title(of: expense.id) == "Dinner at Luigi's")
        #expect(try await second.version(of: expense.id) == 2)
    }

    @Test func pullPagesAreAppliedTogether() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        for index in 1...5 { try await first.addExpense(trip, title: "Expense \(index)") }
        await first.engine.sync()

        let second = try Device(server: server, account: account, pageSize: 2)
        let report = await second.engine.sync()

        #expect(report.outcome == .completed)
        #expect(try await second.count("expenses") == 5)
        #expect(await second.backend.pullRequests.count >= 4)
    }

    @Test func aFailedPullChangesNothingAndTheNextOneRecovers() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        try await first.addExpense(trip)
        await first.engine.sync()

        let second = try Device(server: server, account: account)
        await second.backend.failNextPull(with: serviceUnavailable)
        let failed = await second.engine.sync()
        #expect(failed.outcome == .failed("unavailable"))
        #expect(try await second.count("expenses") == 0)
        #expect(try await second.database.query("SELECT cursor, last_error FROM sync_state").first?.int("cursor") == 0)

        let recovered = await second.engine.sync()
        #expect(recovered.outcome == .completed)
        #expect(try await second.count("expenses") == 1)
        #expect(try await second.database.query("SELECT last_error FROM sync_state").first?.optionalText("last_error") == nil)
    }

    // MARK: - Engine behaviour

    @Test func aDatabaseNeverMixesTwoAccounts() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        _ = try await device.makeTrip()
        await device.engine.sync()

        let intruder = InMemoryBackend(server: server)
        let engine = SyncEngine(database: device.database, backend: intruder)
        let before = await server.currentSequence
        _ = try await device.groups.createUser(name: "Eve", email: nil)
        let report = await engine.sync()

        #expect(report.outcome == .accountMismatch)
        #expect(await intruder.sentOperations.isEmpty)
        #expect(await server.currentSequence == before)
    }

    @Test func concurrentSyncCallsAreCoalesced() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        try await device.addExpense(trip)

        let reports = await withTaskGroup(of: SyncReport.self) { group in
            for _ in 0..<8 { group.addTask { await device.engine.sync() } }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(reports.allSatisfy { $0.outcome == .completed })
        #expect(await server.expenseRows.count == 1)
        #expect(await device.backend.pullRequests.count <= 2)
        #expect(await device.backend.sentOperations.count == 6)
    }

    @Test func operationsInterruptedByACrashAreRecovered() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)

        // The app died after marking the first operation as sending.
        let first = try #require(try await device.outbox.operations().first)
        try await device.outbox.markSending(first.id)

        let report = await device.engine.sync()
        #expect(report.outcome == .completed)
        #expect(try await device.outbox.operations().allSatisfy { $0.status == .done })
        #expect(await server.expenseRows.map(\.id) == [expense.id])
    }
}
