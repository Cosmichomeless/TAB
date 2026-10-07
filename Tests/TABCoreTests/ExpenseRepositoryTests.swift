import Foundation
import Testing
@testable import TABCore

@Suite("Local expenses")
struct ExpenseRepositoryTests {
    struct Fixture {
        let groups: SQLiteGroupRepository
        let expenses: SQLiteExpenseRepository
        let group: Group
        let david: User
        let ana: User
    }

    private func makeFixture(path: String? = nil) async throws -> Fixture {
        let database = try path.map { try Database(path: $0) } ?? Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Lisbon", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)
        return Fixture(
            groups: groups, expenses: SQLiteExpenseRepository(database: database),
            group: group, david: david, ana: ana
        )
    }

    private func shares(_ pairs: (User, Int64)...) -> [SplitShare] {
        pairs.map { SplitShare(userID: $0.0.id, amountMinor: $0.1) }
    }

    @Test func recordsPayerTitleAmountCurrencyParticipantsAndTimestamp() async throws {
        let f = try await makeFixture()
        let before = Date().truncatedToMilliseconds

        let expense = try await f.expenses.createExpense(
            groupID: f.group.id, paidBy: f.david.id, title: "  Dinner ", amountMinor: 3001,
            shares: shares((f.david, 1501), (f.ana, 1500))
        )

        #expect(expense.title == "Dinner")
        #expect(expense.paidBy == f.david.id)
        #expect(expense.amountMinor == 3001)
        #expect(expense.currency == .eur)
        #expect(expense.createdAt >= before)
        #expect(try await f.expenses.expenses(in: f.group.id) == [expense])
        let splits = try await f.expenses.splits(of: expense.id)
        #expect(splits.map(\.userID) == [f.david.id, f.ana.id])
        #expect(splits.map(\.amountMinor) == [1501, 1500])
    }

    @Test func listsNewestFirstAndHidesDeleted() async throws {
        let f = try await makeFixture()
        let first = try await f.expenses.createExpense(
            groupID: f.group.id, paidBy: f.david.id, title: "Taxi", amountMinor: 1000,
            shares: shares((f.david, 500), (f.ana, 500))
        )
        let second = try await f.expenses.createExpense(
            groupID: f.group.id, paidBy: f.ana.id, title: "Lunch", amountMinor: 2000,
            shares: shares((f.david, 1000), (f.ana, 1000))
        )
        #expect(try await f.expenses.expenses(in: f.group.id).map(\.id) == [second.id, first.id])

        try await f.expenses.deleteExpense(id: second.id)
        try await f.expenses.deleteExpense(id: second.id)

        #expect(try await f.expenses.expenses(in: f.group.id).map(\.id) == [first.id])
        await #expect(throws: DomainError.expenseNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try await f.expenses.deleteExpense(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        }
    }

    @Test func rejectsInvalidExpenses() async throws {
        let f = try await makeFixture()
        let even = shares((f.david, 500), (f.ana, 500))

        await #expect(throws: DomainError.emptyTitle) {
            try await f.expenses.createExpense(groupID: f.group.id, paidBy: f.david.id, title: " ", amountMinor: 1000, shares: even)
        }
        await #expect(throws: DomainError.invalidAmount) {
            try await f.expenses.createExpense(groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 0, shares: [])
        }
        await #expect(throws: DomainError.noParticipants) {
            try await f.expenses.createExpense(groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 1000, shares: [])
        }
        await #expect(throws: DomainError.splitsDoNotMatchAmount(expected: 1000, actual: 999)) {
            try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 1000,
                shares: shares((f.david, 500), (f.ana, 499))
            )
        }
        await #expect(throws: DomainError.duplicateParticipant(f.ana.id)) {
            try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 1000,
                shares: shares((f.ana, 500), (f.ana, 500))
            )
        }
        #expect(try await f.expenses.expenses(in: f.group.id).isEmpty)
    }

    @Test func requiresPayerAndParticipantsToBeGroupMembers() async throws {
        let f = try await makeFixture()
        let outsider = try await f.groups.createUser(name: "Outsider", email: nil)

        await #expect(throws: DomainError.notAMember(userID: outsider.id, groupID: f.group.id)) {
            try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: outsider.id, title: "x", amountMinor: 1000,
                shares: shares((f.david, 1000))
            )
        }
        await #expect(throws: DomainError.notAMember(userID: outsider.id, groupID: f.group.id)) {
            try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 1000,
                shares: shares((f.david, 500), (outsider, 500))
            )
        }
        #expect(try await f.expenses.expenses(in: f.group.id).isEmpty)
    }

    @Test func failedWriteLeavesNoOrphanSplits() async throws {
        let f = try await makeFixture()
        let outsider = try await f.groups.createUser(name: "Outsider", email: nil)

        _ = try? await f.expenses.createExpense(
            groupID: f.group.id, paidBy: f.david.id, title: "x", amountMinor: 1000,
            shares: shares((f.david, 500), (outsider, 500))
        )

        let leftovers = try await f.expenses.splits(of: UUID())
        #expect(leftovers.isEmpty)
        #expect(try await f.expenses.expenses(in: f.group.id).isEmpty)
    }

    @Test func historySurvivesRelaunchOffline() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let groupID: UUID
        let expenseID: UUID
        do {
            let f = try await makeFixture(path: path)
            let expense = try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: f.ana.id, title: "Museum", amountMinor: 2400,
                shares: shares((f.david, 1200), (f.ana, 1200))
            )
            groupID = f.group.id
            expenseID = expense.id
        }

        let reopened = SQLiteExpenseRepository(database: try Database(path: path))
        let history = try await reopened.expenses(in: groupID)
        #expect(history.map(\.id) == [expenseID])
        #expect(try await reopened.splits(of: expenseID).map(\.amountMinor) == [1200, 1200])
    }

    @Test func formatsMinorUnits() {
        #expect(Currency.eur.format(minorUnits: 1050).contains("10.50") || Currency.eur.format(minorUnits: 1050).contains("10,50"))
        #expect(Currency.jpy.format(minorUnits: 500).contains("500"))
    }
}
