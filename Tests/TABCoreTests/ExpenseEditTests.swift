import Foundation
import Testing
@testable import TABCore

@Suite("Editing expenses")
struct ExpenseEditTests {
    @Test func editingTitleAndPayerPreservesUnequalSharesFromStorage() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let expense = try await device.expenses.createExpense(
            groupID: trip.group.id, paidBy: trip.david.id, title: "Dinner", amountMinor: 3000,
            shares: [SplitShare(userID: trip.david.id, amountMinor: 1000),
                     SplitShare(userID: trip.ana.id, amountMinor: 2000)]
        )
        let original = try await device.expenses.splits(of: expense.id)

        _ = try await device.expenses.updateExpense(
            id: expense.id, paidBy: trip.ana.id, title: "New title", amountMinor: expense.amountMinor,
            originalAmountMinor: expense.amountMinor, originalSplits: original,
            participants: original.map(\.userID)
        )

        #expect(try await device.expenses.splits(of: expense.id) == original)
        #expect(try await device.expenses.expenses(in: trip.group.id).first?.paidBy == trip.ana.id)
    }

    @Test func changingAmountRecalculatesUnequalSharesEqually() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let expense = try await device.expenses.createExpense(
            groupID: trip.group.id, paidBy: trip.david.id, title: "Dinner", amountMinor: 3000,
            shares: [SplitShare(userID: trip.david.id, amountMinor: 1000),
                     SplitShare(userID: trip.ana.id, amountMinor: 2000)]
        )
        let original = try await device.expenses.splits(of: expense.id)

        _ = try await device.expenses.updateExpense(
            id: expense.id, paidBy: trip.david.id, title: "Dinner", amountMinor: 4000,
            originalAmountMinor: expense.amountMinor, originalSplits: original,
            participants: original.map(\.userID)
        )

        #expect(try await device.expenses.splits(of: expense.id).map(\.amountMinor) == [2000, 2000])
    }

    @Test func editedAmountCanBeShownInAnEditableFieldWithoutCurrencySymbols() {
        #expect(Currency.eur.input(minorUnits: 1234) == "12.34")
        #expect(Currency.eur.input(minorUnits: 1200) == "12.00")
        #expect(Currency.jpy.input(minorUnits: 1234) == "1234")
        #expect(Currency.eur.parse(minorUnits: Currency.eur.input(minorUnits: 1234)) == 1234)
    }

    @Test func anEditReplacesTheExpenseAndItsSharesAndChangesTheBalances() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let dinner = try await device.addExpense(trip, title: "Dinner", amountMinor: 3000)

        let edited = try await device.expenses.updateExpense(
            id: dinner.id, paidBy: trip.ana.id, title: "  Tapas ", amountMinor: 4000,
            splitEquallyAmong: [trip.david.id, trip.ana.id]
        )

        #expect(edited.id == dinner.id)
        #expect(edited.title == "Tapas")
        #expect(edited.amountMinor == 4000)
        #expect(edited.paidBy == trip.ana.id)
        #expect(edited.createdAt == dinner.createdAt)
        #expect(try await device.expenses.expenses(in: trip.group.id).map(\.title) == ["Tapas"])
        #expect(try await device.expenses.splits(of: dinner.id).map(\.amountMinor) == [2000, 2000])
        #expect(try await device.balances(in: trip.group.id).map(\.netMinor).sorted() == [-2000, 2000])
    }

    @Test func anEditQueuesOneMoreOperationInTheSameTransaction() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let dinner = try await device.addExpense(trip)

        _ = try await device.expenses.updateExpense(
            id: dinner.id, paidBy: trip.david.id, title: "Lunch", amountMinor: 3000,
            splitEquallyAmong: [trip.david.id]
        )

        let operations = try await device.outbox.operations().filter { $0.kind == .upsertExpense }
        #expect(operations.count == 2)
        let payload = try JSONDecoder().decode(UpsertExpensePayload.self, from: try #require(operations.last).payload)
        #expect(payload.title == "Lunch")
        #expect(payload.splits.count == 1)
    }

    @Test func titleOnlyEditOfAThreePersonSplitDoesNotAddTheFourthMember() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let fourth = try await device.groups.addParticipant(name: "Marta", email: nil, to: trip.group.id)
        _ = try await device.groups.addParticipant(name: "Bruno", email: nil, to: trip.group.id)
        let dinner = try await device.expenses.createExpense(
            groupID: trip.group.id, paidBy: trip.david.id, title: "Dinner", amountMinor: 3000,
            splitEquallyAmong: [trip.david.id, trip.ana.id, fourth.id]
        )
        let original = try await device.expenses.splits(of: dinner.id)

        _ = try await device.expenses.updateExpense(
            id: dinner.id, paidBy: dinner.paidBy, title: "Dinner updated", amountMinor: dinner.amountMinor,
            splitEquallyAmong: original.map { $0.userID }
        )

        #expect(try await device.expenses.splits(of: dinner.id) == original)
    }

    @Test func aFailedEditChangesNothingAndQueuesNothing() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let dinner = try await device.addExpense(trip, title: "Dinner", amountMinor: 3000)
        let before = try await device.outbox.operations().count

        await #expect(throws: DomainError.emptyTitle) {
            try await device.expenses.updateExpense(
                id: dinner.id, paidBy: trip.david.id, title: " ", amountMinor: 100, splitEquallyAmong: [trip.david.id]
            )
        }
        await #expect(throws: DomainError.invalidAmount) {
            try await device.expenses.updateExpense(
                id: dinner.id, paidBy: trip.david.id, title: "x", amountMinor: 0, shares: [SplitShare(userID: trip.david.id, amountMinor: 0)]
            )
        }
        await #expect(throws: DomainError.splitsDoNotMatchAmount(expected: 100, actual: 90)) {
            try await device.expenses.updateExpense(
                id: dinner.id, paidBy: trip.david.id, title: "x", amountMinor: 100, shares: [SplitShare(userID: trip.david.id, amountMinor: 90)]
            )
        }
        let stranger = UUID()
        await #expect(throws: DomainError.notAMember(userID: stranger, groupID: trip.group.id)) {
            try await device.expenses.updateExpense(
                id: dinner.id, paidBy: stranger, title: "x", amountMinor: 100, splitEquallyAmong: [trip.david.id]
            )
        }

        #expect(try await device.title(of: dinner.id) == "Dinner")
        #expect(try await device.expenses.splits(of: dinner.id).map(\.amountMinor) == [1500, 1500])
        #expect(try await device.outbox.operations().count == before)
    }

    @Test func aDeletedOrUnknownExpenseCannotBeEdited() async throws {
        let device = try Device(server: InMemoryServer())
        let trip = try await device.makeTrip()
        let dinner = try await device.addExpense(trip)
        try await device.expenses.deleteExpense(id: dinner.id)

        await #expect(throws: DomainError.expenseNotFound(dinner.id)) {
            try await device.expenses.updateExpense(
                id: dinner.id, paidBy: trip.david.id, title: "x", amountMinor: 100, splitEquallyAmong: [trip.david.id]
            )
        }
        let unknown = UUID()
        await #expect(throws: DomainError.expenseNotFound(unknown)) {
            try await device.expenses.updateExpense(
                id: unknown, paidBy: trip.david.id, title: "x", amountMinor: 100, splitEquallyAmong: [trip.david.id]
            )
        }
    }

    @Test func anEditMadeOfflineReachesAnotherDevice() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let phone = try Device(server: server, account: account)
        let tablet = try Device(server: server, account: account)
        let trip = try await phone.makeTrip()
        let dinner = try await phone.addExpense(trip, title: "Dinner", amountMinor: 3000)
        await phone.engine.sync()
        await tablet.engine.sync()

        await phone.backend.setOnline(false)
        _ = try await phone.expenses.updateExpense(
            id: dinner.id, paidBy: trip.david.id, title: "Tapas", amountMinor: 5000,
            splitEquallyAmong: [trip.david.id, trip.ana.id]
        )
        #expect(await phone.engine.sync().outcome == .offline)
        await phone.backend.setOnline(true)
        #expect(await phone.engine.sync().outcome == .completed)
        await tablet.engine.sync()

        #expect(try await tablet.expenses.expenses(in: trip.group.id).map(\.title) == ["Tapas"])
        #expect(try await tablet.balances(in: trip.group.id) == (try await phone.balances(in: trip.group.id)))
        #expect(try await phone.version(of: dinner.id) == 2)
    }

    @Test func twoDevicesEditingTheSameExpenseLeaveTheLoserRecoverable() async throws {
        let server = InMemoryServer()
        let account = UUID()
        let phone = try Device(server: server, account: account)
        let tablet = try Device(server: server, account: account)
        let trip = try await phone.makeTrip()
        let dinner = try await phone.addExpense(trip, title: "Dinner", amountMinor: 3000)
        await phone.engine.sync()
        await tablet.engine.sync()

        _ = try await phone.expenses.updateExpense(
            id: dinner.id, paidBy: trip.david.id, title: "Phone", amountMinor: 3000, splitEquallyAmong: [trip.david.id, trip.ana.id]
        )
        _ = try await tablet.expenses.updateExpense(
            id: dinner.id, paidBy: trip.david.id, title: "Tablet", amountMinor: 3000, splitEquallyAmong: [trip.david.id, trip.ana.id]
        )
        await phone.engine.sync()
        await tablet.engine.sync()

        // remoteWins: the tablet shows the phone's edit, and its own is kept as a conflict it can restore.
        #expect(try await tablet.title(of: dinner.id) == "Phone")
        let conflict = try #require(try await tablet.resolver.conflicts().first)
        #expect(conflict.local?.title == "Tablet")
        try await tablet.resolver.restoreLocal(conflict.id)
        await tablet.engine.sync()
        await phone.engine.sync()
        #expect(try await phone.title(of: dinner.id) == "Tablet")
    }
}
