import Foundation
import Testing
@testable import TABCore

@Suite("Unequal splits")
struct SplitMethodTests {
    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
    }

    private func amounts(_ shares: [SplitShare]) -> [Int64] { shares.map(\.amountMinor) }

    // MARK: Parts

    @Test func twoPartsAndOnePartSplitInProportion() throws {
        let people = ids(2)
        let shares = try SplitCalculator.shares(amountMinor: 3000, method: .shares([people[0]: 2, people[1]: 1]))
        #expect(amounts(shares) == [2000, 1000])
    }

    @Test func partsHandOutTheLeftoverToTheLargestRemainders() throws {
        let people = ids(3)
        // 100 split 1:1:1 leaves 1 cent; the three remainders tie, so the first id takes it.
        let even = try SplitCalculator.shares(amountMinor: 100, method: .shares(Dictionary(uniqueKeysWithValues: people.map { ($0, 1) })))
        #expect(amounts(even) == [34, 33, 33])
        // 10 split 1:2:2 is 2, 4, 4 exactly.
        let exact = try SplitCalculator.shares(amountMinor: 10, method: .shares([people[0]: 1, people[1]: 2, people[2]: 2]))
        #expect(amounts(exact) == [2, 4, 4])
        // 10 split 2:3:3 gives 2.5, 3.75, 3.75: floors 2, 3, 3 and the two cents go to the .75 remainders.
        let uneven = try SplitCalculator.shares(amountMinor: 10, method: .shares([people[0]: 2, people[1]: 3, people[2]: 3]))
        #expect(amounts(uneven) == [2, 4, 4])
    }

    @Test func aWeightOfZeroOrLessIsRefused() {
        let people = ids(2)
        #expect(throws: DomainError.invalidSplitWeight(people[1])) {
            try SplitCalculator.shares(amountMinor: 100, method: .shares([people[0]: 1, people[1]: 0]))
        }
        #expect(throws: DomainError.noParticipants) {
            try SplitCalculator.shares(amountMinor: 100, method: .shares([:]))
        }
    }

    // MARK: Percentages

    @Test func percentagesMustAddUpToOneHundred() throws {
        let people = ids(3)
        let thirds = try SplitCalculator.shares(
            amountMinor: 1000, method: .percentages([people[0]: 3333, people[1]: 3333, people[2]: 3334])
        )
        #expect(amounts(thirds).reduce(0, +) == 1000)
        #expect(amounts(thirds) == [333, 333, 334])

        #expect(throws: DomainError.percentagesDoNotAddUp(actual: 9_900)) {
            try SplitCalculator.shares(amountMinor: 1000, method: .percentages([people[0]: 5000, people[1]: 4900]))
        }
    }

    @Test func percentagesGiveExactAmountsWhenTheyDivideEvenly() throws {
        let people = ids(2)
        let shares = try SplitCalculator.shares(amountMinor: 20_000, method: .percentages([people[0]: 7500, people[1]: 2500]))
        #expect(amounts(shares) == [15_000, 5_000])
    }

    // MARK: Exact amounts

    @Test func exactAmountsMustAddUpToTheExpense() throws {
        let people = ids(3)
        let shares = try SplitCalculator.shares(amountMinor: 1000, method: .exact([people[0]: 600, people[1]: 400, people[2]: 0]))
        #expect(amounts(shares) == [600, 400])
        #expect(shares.map(\.userID) == [people[0], people[1]])

        #expect(throws: DomainError.splitsDoNotMatchAmount(expected: 1000, actual: 900)) {
            try SplitCalculator.shares(amountMinor: 1000, method: .exact([people[0]: 600, people[1]: 300]))
        }
        #expect(throws: DomainError.invalidSplitWeight(people[0])) {
            try SplitCalculator.shares(amountMinor: 1000, method: .exact([people[0]: -100, people[1]: 1100]))
        }
        #expect(throws: DomainError.noParticipants) {
            try SplitCalculator.shares(amountMinor: 1000, method: .exact([people[0]: 0]))
        }
    }

    @Test func anAmountThatOverflowsIsReportedNotTrapped() {
        let people = ids(2)
        #expect(throws: DomainError.self) {
            try SplitCalculator.shares(amountMinor: 10, method: .exact([people[0]: .max, people[1]: .max]))
        }
    }

    @Test func aNonPositiveExpenseIsRefusedForEveryMethod() {
        let people = ids(2)
        for method in [SplitMethod.equal(among: people), .shares([people[0]: 1]), .exact([people[0]: 1])] {
            #expect(throws: DomainError.invalidAmount) { try SplitCalculator.shares(amountMinor: 0, method: method) }
        }
    }

    // MARK: Properties

    @Test func weightedSplitsAlwaysAddUpAndStayWithinOneCentOfTheExactShare() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let people = ids(Int.random(in: 1...8, using: &generator))
            let weights = Dictionary(uniqueKeysWithValues: people.map { ($0, Int64.random(in: 1...50, using: &generator)) })
            let amount = Int64.random(in: 1...5_000_000, using: &generator)
            let total = weights.values.reduce(0, +)

            let shares = try SplitCalculator.shares(amountMinor: amount, method: .shares(weights))

            #expect(shares.map(\.amountMinor).reduce(0, +) == amount)
            #expect(Set(shares.map(\.userID)) == Set(people))
            for share in shares {
                let exact = Double(amount) * Double(weights[share.userID]!) / Double(total)
                #expect(abs(Double(share.amountMinor) - exact) < 1)
            }
        }
    }

    @Test func theResultDoesNotDependOnInputOrderOrDictionaryOrder() throws {
        let people = ids(6)
        let weights = Dictionary(uniqueKeysWithValues: zip(people, [3, 1, 4, 1, 5, 9] as [Int64]))
        let expected = try SplitCalculator.shares(amountMinor: 100_003, method: .shares(weights))
        for _ in 0..<20 {
            let shuffled = Dictionary(uniqueKeysWithValues: weights.shuffled())
            #expect(try SplitCalculator.shares(amountMinor: 100_003, method: .shares(shuffled)) == expected)
        }
        #expect(expected.map(\.userID) == people)
    }

    @Test func percentagesAlwaysAddUpForRandomSplits() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let people = ids(Int.random(in: 1...6, using: &generator))
            var remaining = SplitMethod.fullPercentage
            var percentages: [UUID: Int64] = [:]
            for (index, id) in people.enumerated() {
                let isLast = index == people.count - 1
                let slotsAfter = Int64(people.count - index - 1)
                let value = isLast ? remaining : Int64.random(in: 1...(remaining - slotsAfter), using: &generator)
                percentages[id] = value
                remaining -= value
            }
            let amount = Int64.random(in: 1...10_000_000, using: &generator)
            let shares = try SplitCalculator.shares(amountMinor: amount, method: .percentages(percentages))
            #expect(shares.map(\.amountMinor).reduce(0, +) == amount)
        }
    }

    @Test func hugeAmountsDoNotOverflowTheIntermediateProduct() throws {
        let people = ids(3)
        let amount = Int64.max / 4
        let shares = try SplitCalculator.shares(
            amountMinor: amount, method: .shares([people[0]: 1_000_000_000, people[1]: 999_999_999, people[2]: 1])
        )
        #expect(shares.map(\.amountMinor).reduce(0, +) == amount)
    }

    // MARK: Through the repository

    @Test func theRepositoryStoresAndBalancesAnUnequalSplit() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)

        let expense = try await expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Wine", amountMinor: 3000,
            method: .shares([david.id: 1, ana.id: 2])
        )
        let stored = try await expenses.splits(of: expense.id)
        #expect(Dictionary(uniqueKeysWithValues: stored.map { ($0.userID, $0.amountMinor) }) == [david.id: 1000, ana.id: 2000])

        let ledger = try await expenses.ledger(in: group.id)
        let balances = BalanceCalculator.balances(for: ledger, members: [david.id, ana.id])
        #expect(balances.first { $0.userID == david.id }?.netMinor == 2000)
        #expect(balances.first { $0.userID == ana.id }?.netMinor == -2000)
    }

    @Test func aRejectedSplitStoresNothing() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)

        await #expect(throws: DomainError.self) {
            try await expenses.createExpense(
                groupID: group.id, paidBy: david.id, title: "Wine", amountMinor: 3000, method: .exact([david.id: 2000])
            )
        }
        #expect(try await expenses.expenses(in: group.id).isEmpty)
    }

    @Test func editingTitleOnlyKeepsAnUnequalSplit() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)
        let expense = try await expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Wine", amountMinor: 3000, method: .exact([david.id: 500, ana.id: 2500])
        )
        let original = try await expenses.splits(of: expense.id)

        _ = try await expenses.updateExpense(
            id: expense.id, paidBy: david.id, title: "Red wine", amountMinor: 3000,
            originalAmountMinor: 3000, originalSplits: original, participants: [david.id, ana.id]
        )

        let after = try await expenses.splits(of: expense.id)
        #expect(Dictionary(uniqueKeysWithValues: after.map { ($0.userID, $0.amountMinor) }) == [david.id: 500, ana.id: 2500])
    }

    // MARK: Form input

    @Test func formTextBecomesTheMethodForEachMode() throws {
        let people = ids(3)
        let entries = [people[0]: "2", people[1]: " 1 ", people[2]: ""]
        #expect(try SplitInput.method(mode: .shares, participants: people, entries: entries, currency: .eur)
            == .shares([people[0]: 2, people[1]: 1]))
        #expect(try SplitInput.method(mode: .percentages, participants: people, entries: [people[0]: "33,33", people[1]: "66.67"], currency: .eur)
            == .percentages([people[0]: 3333, people[1]: 6667]))
        #expect(try SplitInput.method(mode: .exact, participants: people, entries: [people[0]: "10,5", people[1]: "0"], currency: .eur)
            == .exact([people[0]: 1050]))
        #expect(try SplitInput.method(mode: .exact, participants: people, entries: [people[0]: "500"], currency: .jpy)
            == .exact([people[0]: 500]))
        #expect(try SplitInput.method(mode: .equal, participants: people, entries: [:], currency: .eur) == .equal(among: people))
    }

    @Test func textThatIsNotANumberIsReportedForThatPerson() {
        let people = ids(2)
        for mode in [SplitMode.shares, .percentages, .exact] {
            #expect(throws: DomainError.invalidSplitWeight(people[1])) {
                try SplitInput.method(mode: mode, participants: people, entries: [people[0]: "1", people[1]: "abc"], currency: .eur)
            }
        }
        #expect(throws: DomainError.invalidSplitWeight(people[0])) {
            try SplitInput.method(mode: .shares, participants: people, entries: [people[0]: "1.5"], currency: .eur)
        }
        #expect(throws: DomainError.invalidSplitWeight(people[0])) {
            try SplitInput.method(mode: .shares, participants: people, entries: [people[0]: "-1"], currency: .eur)
        }
    }

    @Test func storedSplitsAreRecognisedAsEqualOrNot() throws {
        let people = ids(3)
        let expenseID = UUID()
        func splits(_ amounts: [Int64]) -> [ExpenseSplit] {
            zip(people, amounts).map { ExpenseSplit(expenseID: expenseID, userID: $0, amountMinor: $1) }
        }
        let equal = try SplitCalculator.shares(amountMinor: 100, method: .equal(among: people))
        #expect(SplitInput.isEqual(splits(equal.map(\.amountMinor)), amountMinor: 100))
        #expect(!SplitInput.isEqual(splits([50, 30, 20]), amountMinor: 100))
    }

    @Test func remainingShowsWhatIsLeftToAssign() {
        let people = ids(2)
        let entries = [people[0]: "6", people[1]: "x"]
        #expect(SplitInput.remaining(mode: .exact, amountMinor: 1000, participants: people, entries: entries, currency: .eur) == 400)
        #expect(SplitInput.remaining(mode: .percentages, amountMinor: 1000, participants: people, entries: [people[0]: "60"], currency: .eur) == 4000)
        #expect(SplitInput.remaining(mode: .shares, amountMinor: 1000, participants: people, entries: entries, currency: .eur) == nil)
    }
}
