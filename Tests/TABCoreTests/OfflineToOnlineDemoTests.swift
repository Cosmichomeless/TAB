import Foundation
import Testing
@testable import TABCore

/// The release demo, as one test: create an expense offline, reconnect, and see it on another device.
/// It runs against the in-memory server, not a real Supabase project (see docs/release/demo.md).
@Suite("Offline to online demo")
struct OfflineToOnlineDemoTests {
    @Test func anExpenseCreatedOfflineReachesAnotherDeviceAfterReconnecting() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let phone = try Device(server: server, account: account)
        let tablet = try Device(server: server, account: account)

        // 1. The phone loses its connection and David records a dinner. The UI would update at once.
        await phone.backend.setOnline(false)
        let trip = try await phone.makeTrip()
        let dinner = try await phone.addExpense(trip, title: "Dinner", amountMinor: 6000)
        #expect(try await phone.expenses.expenses(in: trip.group.id).map(\.title) == ["Dinner"])
        #expect(try await phone.outbox.statuses(of: [dinner.id])[dinner.id] == .pending)

        // 2. Nothing reaches the server and nothing is lost while the phone is offline.
        #expect(await phone.engine.sync().outcome == .offline)
        #expect(await server.expenseRows.isEmpty)
        #expect(await tablet.engine.sync().pulled == 0)
        #expect(try await tablet.expenses.expenses(in: trip.group.id).isEmpty)

        // 3. The connection returns: the pending operations are delivered and acknowledged.
        await phone.backend.setOnline(true)
        let pushed = await phone.engine.sync()
        #expect(pushed.outcome == .completed)
        #expect(try await phone.outbox.statuses(of: [dinner.id])[dinner.id] == .synced)
        #expect(await server.expenseRows.map(\.id) == [dinner.id])

        // 4. The other device pulls it, with the same balances.
        let pulled = await tablet.engine.sync()
        #expect(pulled.outcome == .completed)
        #expect(try await tablet.expenses.expenses(in: trip.group.id).map(\.title) == ["Dinner"])
        #expect(try await tablet.balances(in: trip.group.id).map(\.netMinor).sorted() == [-3000, 3000])
        #expect(try await tablet.balances(in: trip.group.id) == (try await phone.balances(in: trip.group.id)))
    }
}
