import Foundation
import Testing
@testable import TABCore

/// Two devices on one account, an in-memory server and every way the network can misbehave. Each test ends
/// by comparing what the devices and the server hold: the promise is eventual consistency, so after enough
/// synchronization they must be the same (see `docs/architecture/sync-protocol.md`).
@Suite("Sync resilience")
struct SyncResilienceTests {
    /// Two devices of the same account that already share one group, both with their own empty outbox.
    private struct Pair {
        let server: InMemoryServer
        let first: Device
        let second: Device
        let trip: Device.Trip
    }

    private func makePair(pageSize: Int = 500) async throws -> Pair {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        await first.engine.sync()
        let second = try Device(server: server, account: account, pageSize: pageSize)
        await second.engine.sync()
        return Pair(server: server, first: first, second: second, trip: trip)
    }

    private func expectConsistent(_ pair: Pair, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let server = await pair.server.expenseStates()
        #expect(try await pair.first.expenseStates() == server, sourceLocation: sourceLocation)
        #expect(try await pair.second.expenseStates() == server, sourceLocation: sourceLocation)
        let balances = try await pair.first.balances(in: pair.trip.group.id)
        #expect(try await pair.second.balances(in: pair.trip.group.id) == balances, sourceLocation: sourceLocation)
        #expect(balances.map(\.netMinor).reduce(0, +) == 0, sourceLocation: sourceLocation)
        for device in [pair.first, pair.second] {
            #expect(try await device.outbox.summary().isFullySynced, sourceLocation: sourceLocation)
            #expect(try await device.resolver.conflicts(status: .open).isEmpty, sourceLocation: sourceLocation)
            #expect(try await device.outbox.operations(status: .rejected).isEmpty, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Concurrent changes

    @Test func changesMadeOfflineOnTwoDevicesMergeWhenBothReconnect() async throws {
        let pair = try await makePair()
        let hotel = try await pair.first.addExpense(pair.trip, title: "Hotel", amountMinor: 9000)
        await pair.first.engine.sync()
        await pair.second.engine.sync()

        await pair.first.backend.setOnline(false)
        await pair.second.backend.setOnline(false)
        try await pair.first.expenses.deleteExpense(id: hotel.id)
        try await pair.first.addExpense(pair.trip, title: "Dinner", amountMinor: 3000)
        try await pair.second.addExpense(pair.trip, title: "Taxi", amountMinor: 1200)
        try await pair.second.addExpense(pair.trip, title: "Museum", amountMinor: 2500)
        // Nothing moves while both are offline.
        #expect(await pair.first.engine.sync().outcome == .offline)
        #expect(try await pair.second.expenses.expenses(in: pair.trip.group.id).count == 3)

        await pair.second.backend.setOnline(true)
        await pair.first.backend.setOnline(true)
        try await settle([pair.second, pair.first])

        let live = try await pair.first.expenses.expenses(in: pair.trip.group.id).map(\.title).sorted()
        #expect(live == ["Dinner", "Museum", "Taxi"])
        #expect(try await pair.second.expenses.expenses(in: pair.trip.group.id).map(\.title).sorted() == live)
        try await expectConsistent(pair)
    }

    @Test func aDeleteAndAnEditOfTheSameExpenseEndInOneAgreedState() async throws {
        let pair = try await makePair()
        let expense = try await pair.first.addExpense(pair.trip, title: "Dinner")
        await pair.first.engine.sync()
        await pair.second.engine.sync()

        await pair.server.editExpense(expense.id, title: "Dinner at Luigi's")
        try await pair.second.expenses.deleteExpense(id: expense.id)
        try await settle([pair.second, pair.first])

        try await expectConsistent(pair)
        #expect(try await pair.first.title(of: expense.id) == "Dinner at Luigi's")
    }

    // MARK: - Connection loss

    @Test func aConnectionLostHalfwayThroughAPushLeavesTheServerConsistentAndFinishesLater() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let trip = try await first.makeTrip()
        let expense = try await first.addExpense(trip)
        let total = try await first.outbox.operations().count

        await first.backend.inject(.succeed, .succeed, .succeed, .fail(.offline))
        let partial = await first.engine.sync()
        #expect(partial.outcome == .offline)
        #expect(partial.pushed == 3)
        #expect(try await first.outbox.operations(status: .done).count == 3)
        #expect(await server.expenseRows.isEmpty)

        // Another device looking at the half-synchronized server sees a valid prefix, never a dangling expense.
        let second = try Device(server: server, account: account)
        #expect(await second.engine.sync().outcome == .completed)
        #expect(try await second.expenses.expenses(in: trip.group.id).isEmpty)
        #expect(try await second.count("expenses") == 0)

        let finished = await first.engine.sync()
        #expect(finished.outcome == .completed)
        #expect(finished.pushed == total - 3)
        await second.engine.sync()
        #expect(try await second.expenseStates() == (await server.expenseStates()))
        #expect(try await second.version(of: expense.id) == 1)
    }

    @Test func aPullThatKeepsFailingDoesNotBlockPushingOrCorruptTheCursor() async throws {
        let pair = try await makePair(pageSize: 2)
        for index in 1...5 { try await pair.first.addExpense(pair.trip, title: "Expense \(index)") }
        await pair.first.engine.sync()

        for _ in 0..<3 {
            await pair.second.backend.failNextPull(with: serviceUnavailable)
            #expect(await pair.second.engine.sync().outcome == .failed("unavailable"))
            #expect(try await pair.second.count("expenses") == 0)
        }
        // Writes made on the second device in the meantime still reach the server.
        try await pair.second.addExpense(pair.trip, title: "Taxi", amountMinor: 1200)
        await pair.second.backend.failNextPull(with: serviceUnavailable)
        _ = await pair.second.engine.sync()
        #expect(await pair.server.expenseRows.count == 6)

        try await settle([pair.second, pair.first])
        try await expectConsistent(pair)
        #expect(try await pair.second.count("expenses") == 6)
    }

    // MARK: - Restart

    @Test func restartingTheAppAfterTheServerAppliedEverythingReplaysWithoutDuplicates() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let device = try Device(server: server, account: account)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)
        await device.engine.sync()
        let sequence = await server.currentSequence

        // The app was killed while every operation was in flight: the server has them, the device does not know.
        try await device.database.execute("UPDATE pending_operation SET status = 'sending'")
        let restarted = Device(restarting: device, server: server)
        let report = await restarted.engine.sync()

        #expect(report.outcome == .completed)
        #expect(await server.currentSequence == sequence)
        #expect(await server.expenseRows.map(\.id) == [expense.id])
        #expect(try await restarted.outbox.summary().isFullySynced)
        #expect(try await restarted.version(of: expense.id) == 1)
    }

    @Test func restartingAfterALostResponseNeverDuplicatesAndKeepsTheSyncState() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let device = try Device(server: server, account: account)
        let trip = try await device.makeTrip()
        await device.engine.sync()
        let expense = try await device.addExpense(trip)

        await device.backend.inject(.loseResponse)
        #expect(await device.engine.sync().outcome == .offline)
        let cursor = try await device.database.query("SELECT cursor FROM sync_state").first?.int("cursor") ?? 0

        let restarted = Device(restarting: device, server: server)
        let report = await restarted.engine.sync()
        #expect(report.outcome == .completed)
        #expect(try await restarted.database.query("SELECT account_id FROM sync_state").first?.text("account_id") == account.uuidString)
        let resumed = try await restarted.database.query("SELECT cursor FROM sync_state").first?.int("cursor") ?? 0
        #expect(resumed >= cursor)
        #expect(await server.expenseRows.map(\.id) == [expense.id])
        #expect(try await restarted.version(of: expense.id) == 1)
    }

    // MARK: - Duplicate operations

    @Test func everyOperationDeliveredManyTimesStillAppliesOnce() async throws {
        let server = InMemoryServer()
        let device = try Device(server: server)
        let trip = try await device.makeTrip()
        let expense = try await device.addExpense(trip)
        let total = try await device.outbox.operations().count

        // Every operation is applied by the server and its acknowledgement is lost, over and over.
        await device.backend.inject(.loseResponse, .loseResponse, .loseResponse, .loseResponse, .loseResponse, .loseResponse)
        try await settle([device])

        #expect(await device.backend.sentOperations.count > total)
        #expect(await server.userCount == 2)
        #expect(await server.groupCount == 1)
        #expect(await server.memberCount == 2)
        #expect(await server.expenseRows.map(\.id) == [expense.id])
        #expect(await server.expenseRows.first?.version == 1)
        #expect(try await device.version(of: expense.id) == 1)
        #expect(try await device.expenseStates() == (await server.expenseStates()))
    }

    // MARK: - Server failures

    @Test func aMixOfServerFailuresDelaysChangesButNeverLosesThem() async throws {
        let pair = try await makePair()
        for index in 1...3 { try await pair.second.addExpense(pair.trip, title: "Expense \(index)") }
        let tooMany = RemoteError.server(sqlState: nil, status: 429, message: "slow down")

        await pair.second.backend.inject(
            .fail(serviceUnavailable), .fail(tooMany), .fail(.offline), .loseResponse, .succeed,
            .fail(RemoteError.server(sqlState: nil, status: 500, message: "boom")), .fail(serviceUnavailable)
        )
        try await settle([pair.second, pair.first])

        try await expectConsistent(pair)
        #expect(try await pair.first.count("expenses") == 3)
    }

    @Test func anExpiredSessionPausesEverythingAndResumesWithoutLoss() async throws {
        let pair = try await makePair()
        try await pair.second.addExpense(pair.trip, title: "Dinner")
        await pair.second.backend.setSignedIn(false)

        #expect(await pair.second.engine.sync().outcome == .unauthenticated)
        #expect(await pair.server.expenseRows.isEmpty)

        await pair.second.backend.setSignedIn(true)
        try await settle([pair.second, pair.first])
        try await expectConsistent(pair)
        #expect(await pair.server.expenseRows.count == 1)
    }

    @Test func aRejectedChangeInOneGroupDoesNotStopTheOtherGroups() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let first = try Device(server: server, account: account)
        let david = try await first.groups.createUser(name: "David", email: nil)
        let blocked = try await first.groups.createGroup(name: "Blocked", currency: .eur, createdBy: david.id)
        let open = try await first.groups.createGroup(name: "Open", currency: .eur, createdBy: david.id)
        for group in [blocked, open] {
            try await first.expenses.createExpense(
                groupID: group.id, paidBy: david.id, title: "Dinner", amountMinor: 1000,
                shares: [SplitShare(userID: david.id, amountMinor: 1000)]
            )
        }

        // The user claim goes through, then the backend refuses to create the first group.
        let refusal = RemoteError.server(sqlState: "22023", status: 400, message: "invalid group")
        await first.backend.inject(.succeed, .fail(refusal))
        let report = await first.engine.sync()

        #expect(report.rejected == 1)
        #expect(try await first.outbox.operations(status: .rejected).count == 1)
        #expect(await server.groupCount == 1)
        #expect(await server.expenseRows.map(\.groupID) == [open.id])

        let second = try Device(server: server, account: account)
        await second.engine.sync()
        #expect(try await second.groups.groups().map(\.id) == [open.id])
        #expect(try await second.expenses.expenses(in: open.id).count == 1)
    }

    // MARK: - Eventual consistency under random failures

    /// Small deterministic generator, so a failing schedule can be replayed from its seed.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    func randomWritesAndFailuresOnTwoDevicesAlwaysConverge(seed: Int) async throws {
        let pair = try await makePair(pageSize: 3)
        var random = Generator(state: UInt64(seed))
        let devices = [pair.first, pair.second]

        for step in 0..<40 {
            let device = devices[random.next(2)]
            switch random.next(10) {
            case 0, 1, 2:
                try await device.addExpense(pair.trip, title: "Expense \(step)", amountMinor: Int64(100 * (1 + random.next(50))))
            case 3:
                let live = try await device.expenseStates().filter { !$0.deleted }
                if !live.isEmpty { try await device.expenses.deleteExpense(id: live[random.next(live.count)].id) }
            case 4:
                let live = await pair.server.expenseStates().filter { !$0.deleted }
                if !live.isEmpty { await pair.server.editExpense(live[random.next(live.count)].id, title: "Edited \(step)") }
            case 5:
                await device.backend.setOnline(random.next(2) == 0)
            case 6:
                await device.backend.setSignedIn(random.next(4) != 0)
            case 7:
                let faults: [InMemoryBackend.Fault] = [
                    .fail(serviceUnavailable), .fail(.offline), .loseResponse, .succeed,
                ]
                await device.backend.inject(faults[random.next(faults.count)], faults[random.next(faults.count)])
            case 8:
                await device.backend.failNextPull(with: serviceUnavailable)
            default:
                device.clock.advance(Double(random.next(400)))
                await device.engine.sync()
            }
        }

        for device in devices {
            await device.backend.setOnline(true)
            await device.backend.setSignedIn(true)
        }
        try await settle(devices)
        try await expectConsistent(pair)
    }
}
