import Foundation
import Testing
@testable import TABCore

@Suite("Balances and settlements")
struct BalanceTests {
    private let group = UUID()
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func entry(paidBy: UUID, _ shares: [(UUID, Int64)], deleted: Bool = false) -> ExpenseWithSplits {
        let total = shares.reduce(Int64(0)) { $0 + $1.1 }
        let expense = Expense(
            groupID: group, paidBy: paidBy, title: "x", amountMinor: total, currency: .eur,
            deletedAt: deleted ? Date() : nil
        )
        return ExpenseWithSplits(
            expense: expense,
            splits: shares.map { ExpenseSplit(expenseID: expense.id, userID: $0.0, amountMinor: $0.1) }
        )
    }

    private func net(_ balances: [Balance], _ id: UUID) -> Int64 {
        balances.first { $0.userID == id }?.netMinor ?? .min
    }

    @Test func derivesBalancesFromSplits() {
        // A pays 30 for everyone, B pays 15 for A and B.
        let ledger = [
            entry(paidBy: a, [(a, 1000), (b, 1000), (c, 1000)]),
            entry(paidBy: b, [(a, 750), (b, 750)]),
        ]
        let balances = BalanceCalculator.balances(for: ledger, members: [a, b, c])

        #expect(net(balances, a) == 3000 - 1000 - 750)
        #expect(net(balances, b) == 1500 - 1000 - 750)
        #expect(net(balances, c) == -1000)
    }

    @Test func membersWithoutExpensesAreZeroAndOrderIsKept() {
        let balances = BalanceCalculator.balances(for: [], members: [c, a, b])
        #expect(balances.map(\.userID) == [c, a, b])
        #expect(balances.allSatisfy { $0.netMinor == 0 })
    }

    @Test func ignoresDeletedExpenses() {
        let ledger = [
            entry(paidBy: a, [(a, 500), (b, 500)]),
            entry(paidBy: b, [(a, 9000), (b, 9000)], deleted: true),
        ]
        let balances = BalanceCalculator.balances(for: ledger, members: [a, b])
        #expect(net(balances, a) == 500)
        #expect(net(balances, b) == -500)
    }

    @Test func suggestsMinimalObviousSettlements() {
        let balances = [Balance(userID: a, netMinor: 1250), Balance(userID: b, netMinor: -1000), Balance(userID: c, netMinor: -250)]
        let settlements = BalanceCalculator.settlements(for: balances)
        #expect(settlements == [
            Settlement(from: b, to: a, amountMinor: 1000),
            Settlement(from: c, to: a, amountMinor: 250),
        ])
    }

    @Test func noSettlementsWhenEveryoneIsSquare() {
        let balances = BalanceCalculator.balances(for: [], members: [a, b, c])
        #expect(BalanceCalculator.settlements(for: balances).isEmpty)
    }

    @Test func settlementsAreDeterministicForTies() {
        let balances = [Balance(userID: c, netMinor: -500), Balance(userID: b, netMinor: -500), Balance(userID: a, netMinor: 1000)]
        let first = BalanceCalculator.settlements(for: balances)
        #expect(first == BalanceCalculator.settlements(for: balances.reversed()))
        #expect(first.map(\.from) == [b, c])
    }

    /// Small deterministic generator so the property test is reproducible.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func totalsAreConservedForRandomLedgers() throws {
        var rng = LCG(state: 42)
        for _ in 0..<200 {
            let memberCount = Int.random(in: 2...8, using: &rng)
            let members = (0..<memberCount).map { _ in UUID() }
            var ledger: [ExpenseWithSplits] = []
            for _ in 0..<Int.random(in: 0...15, using: &rng) {
                let payer = members.randomElement(using: &rng)!
                let participants = Array(members.shuffled(using: &rng).prefix(Int.random(in: 1...memberCount, using: &rng)))
                let amount = Int64.random(in: 1...1_000_000, using: &rng)
                let shares = try EqualSplit.shares(amountMinor: amount, among: participants)
                let expense = Expense(groupID: group, paidBy: payer, title: "x", amountMinor: amount, currency: .eur)
                ledger.append(ExpenseWithSplits(
                    expense: expense,
                    splits: shares.map { ExpenseSplit(expenseID: expense.id, userID: $0.userID, amountMinor: $0.amountMinor) }
                ))
            }

            let balances = BalanceCalculator.balances(for: ledger, members: members)
            #expect(balances.reduce(Int64(0)) { $0 + $1.netMinor } == 0)

            let settlements = BalanceCalculator.settlements(for: balances)
            #expect(settlements.count <= max(memberCount - 1, 0))
            #expect(settlements.allSatisfy { $0.amountMinor > 0 && $0.from != $0.to })

            var settled = Dictionary(uniqueKeysWithValues: balances.map { ($0.userID, $0.netMinor) })
            for s in settlements {
                settled[s.from, default: 0] += s.amountMinor
                settled[s.to, default: 0] -= s.amountMinor
            }
            #expect(settled.values.allSatisfy { $0 == 0 })
        }
    }

    @Test func repositoryLedgerFeedsBalances() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let created = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: created.id)
        _ = try await expenses.createExpense(
            groupID: created.id, paidBy: david.id, title: "Dinner", amountMinor: 1001,
            splitEquallyAmong: [david.id, ana.id]
        )

        let balances = BalanceCalculator.balances(
            for: try await expenses.ledger(in: created.id), members: [david.id, ana.id]
        )

        #expect(balances.reduce(Int64(0)) { $0 + $1.netMinor } == 0)
        // Ana only owes her share (500 or 501); David is owed exactly that amount.
        let anaNet = net(balances, ana.id)
        #expect([-500, -501].contains(anaNet))
        #expect(net(balances, david.id) == -anaNet)
    }
}
