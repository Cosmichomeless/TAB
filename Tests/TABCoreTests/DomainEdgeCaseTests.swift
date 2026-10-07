import Foundation
import Testing
@testable import TABCore

@Suite("Domain edge cases")
struct DomainEdgeCaseTests {
    // MARK: - Balances

    @Test func peopleOutsideTheMemberListAreAppendedInAStableOrder() {
        let group = UUID()
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let x = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
        let y = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
        let expense = Expense(groupID: group, paidBy: x, title: "x", amountMinor: 300, currency: .eur)
        let ledger = [
            ExpenseWithSplits(expense: expense, splits: [
                ExpenseSplit(expenseID: expense.id, userID: a, amountMinor: 100),
                ExpenseSplit(expenseID: expense.id, userID: x, amountMinor: 100),
                ExpenseSplit(expenseID: expense.id, userID: y, amountMinor: 100),
            ]),
        ]

        let balances = BalanceCalculator.balances(for: ledger, members: [a])

        // Members first, then the rest sorted by id, so the output never depends on dictionary order.
        #expect(balances.map(\.userID) == [a, y, x])
        #expect(balances.map(\.netMinor) == [-100, -100, 200])
        #expect(balances.reduce(0) { $0 + $1.netMinor } == 0)
    }

    // MARK: - Currency

    @Test(arguments: ["eur", "EUR", "Eur"])
    func currencyCodesAreCaseInsensitive(code: String) {
        #expect(Currency(code: code) == .eur)
    }

    @Test func unsupportedCurrencyCodesAreRefused() {
        #expect(Currency(code: "XXX") == nil)
        #expect(Currency(code: "") == nil)
    }

    @Test(arguments: Currency.supported)
    func currencyRoundTripsThroughJSONAsAPlainString(currency: Currency) throws {
        let data = try JSONEncoder().encode(currency)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(currency.code)\"")
        #expect(try JSONDecoder().decode(Currency.self, from: data) == currency)
    }

    @Test func decodingAnUnknownCurrencyFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Currency.self, from: Data("\"XXX\"".utf8))
        }
    }

    @Test func parsesAmountsInEachCurrencyPrecision() {
        #expect(Currency.eur.parse(minorUnits: "12.5") == 1250)
        #expect(Currency.eur.parse(minorUnits: " 12,50 ") == 1250)
        #expect(Currency.eur.parse(minorUnits: "7") == 700)
        #expect(Currency.jpy.parse(minorUnits: "500") == 500)
        #expect(Currency.jpy.parse(minorUnits: "500.5") == nil)
    }

    @Test(arguments: ["", ".", "abc", "1.234", "1.2.3", "-5", "1e3", "٣"])
    func rejectsMalformedAmounts(text: String) {
        #expect(Currency.eur.parse(minorUnits: text) == nil)
    }

    // MARK: - Repositories

    @Test func looksUpUsersAndGroupsByIDAndReturnsNilWhenUnknown() async throws {
        let groups = SQLiteGroupRepository(database: try Database.inMemory())
        let david = try await groups.createUser(name: "David", email: "david@example.com")
        let trip = try await groups.createGroup(name: "Lisbon", currency: .usd, createdBy: david.id)

        #expect(try await groups.user(id: david.id) == david)
        #expect(try await groups.group(id: trip.id) == trip)
        #expect(try await groups.user(id: UUID()) == nil)
        #expect(try await groups.group(id: UUID()) == nil)
    }

    @Test func anExpenseNeedsAnExistingGroupAndNonNegativeShares() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let trip = try await groups.createGroup(name: "Lisbon", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: trip.id)

        let unknown = UUID()
        await #expect(throws: DomainError.groupNotFound(unknown)) {
            try await expenses.createExpense(
                groupID: unknown, paidBy: david.id, title: "Dinner", amountMinor: 100,
                shares: [SplitShare(userID: david.id, amountMinor: 100)]
            )
        }
        await #expect(throws: DomainError.invalidAmount) {
            try await expenses.createExpense(
                groupID: trip.id, paidBy: david.id, title: "Dinner", amountMinor: 100,
                shares: [SplitShare(userID: david.id, amountMinor: 150), SplitShare(userID: ana.id, amountMinor: -50)]
            )
        }
        // Neither failure left anything behind.
        #expect(try await expenses.expenses(in: trip.id).isEmpty)
        #expect(try await database.query("SELECT 1 FROM pending_operation WHERE kind = 'upsertExpense'").isEmpty)
    }

    // MARK: - Database

    @Test func openingADatabaseInAMissingDirectoryFails() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/tab.sqlite").path
        do {
            _ = try Database(path: path)
            Issue.record("Expected the database to refuse a path whose directory does not exist")
        } catch DatabaseError.openFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func aFailingStatementReportsItsSQL() async throws {
        let database = try Database.inMemory()
        do {
            try await database.execute("INSERT INTO table_that_does_not_exist VALUES (1)")
            Issue.record("Expected the statement to fail")
        } catch DatabaseError.statementFailed(let sql, _) {
            #expect(sql.contains("table_that_does_not_exist"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func aFailedTransactionRollsBackEverythingItWrote() async throws {
        let database = try Database.inMemory()
        let id = UUID().uuidString

        await #expect(throws: DatabaseError.self) {
            try await database.transaction { db in
                try db.execute(
                    "INSERT INTO users (id, name, created_at) VALUES (?, 'Ana', 0)", [.text(id)]
                )
                try db.execute("INSERT INTO table_that_does_not_exist VALUES (1)")
            }
        }
        #expect(try await database.query("SELECT 1 FROM users WHERE id = ?", [.text(id)]).isEmpty)
    }
}
