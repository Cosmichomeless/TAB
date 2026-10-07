import Foundation
import Testing
@testable import TABCore

@Suite("Equal splitting")
struct EqualSplitTests {
    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
    }

    @Test func splitsEvenlyWhenDivisible() throws {
        let people = ids(3)
        let shares = try EqualSplit.shares(amountMinor: 3000, among: people)
        #expect(shares.map(\.amountMinor) == [1000, 1000, 1000])
        #expect(Set(shares.map(\.userID)) == Set(people))
    }

    @Test func givesRemainderToFirstParticipantsInIDOrder() throws {
        let people = ids(3)
        let shares = try EqualSplit.shares(amountMinor: 1000, among: people)
        #expect(shares.map(\.userID) == people)
        #expect(shares.map(\.amountMinor) == [334, 333, 333])

        let two = try EqualSplit.shares(amountMinor: 1001, among: ids(3))
        #expect(two.map(\.amountMinor) == [334, 334, 333])
    }

    @Test func isIndependentOfInputOrder() throws {
        let people = ids(5)
        let expected = try EqualSplit.shares(amountMinor: 10_001, among: people)
        for _ in 0..<20 {
            #expect(try EqualSplit.shares(amountMinor: 10_001, among: people.shuffled()) == expected)
        }
    }

    @Test func singleParticipantGetsEverything() throws {
        let shares = try EqualSplit.shares(amountMinor: 999, among: ids(1))
        #expect(shares.map(\.amountMinor) == [999])
    }

    @Test func amountSmallerThanParticipantCount() throws {
        let shares = try EqualSplit.shares(amountMinor: 2, among: ids(5))
        #expect(shares.map(\.amountMinor) == [1, 1, 0, 0, 0])
    }

    @Test func alwaysSumsExactlyToTheAmount() throws {
        for count in 1...12 {
            let people = ids(count)
            for amount in [Int64(1), 2, 3, 7, 99, 100, 101, 1000, 12_345, 999_999, 1_000_000_007, Int64.max / 2] {
                let shares = try EqualSplit.shares(amountMinor: amount, among: people)
                #expect(shares.reduce(Int64(0)) { $0 + $1.amountMinor } == amount)
                let amounts = shares.map(\.amountMinor)
                #expect(amounts.max()! - amounts.min()! <= 1)
                #expect(amounts.min()! >= 0)
            }
        }
    }

    @Test func rejectsInvalidInput() {
        let people = ids(2)
        #expect(throws: DomainError.invalidAmount) { try EqualSplit.shares(amountMinor: 0, among: people) }
        #expect(throws: DomainError.invalidAmount) { try EqualSplit.shares(amountMinor: -5, among: people) }
        #expect(throws: DomainError.noParticipants) { try EqualSplit.shares(amountMinor: 100, among: []) }
        #expect(throws: DomainError.duplicateParticipant(people[0])) {
            try EqualSplit.shares(amountMinor: 100, among: [people[0], people[0]])
        }
    }

    @Test func repositoryStoresEqualSplitThatMatchesTheTotal() async throws {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)
        let marta = try await groups.addParticipant(name: "Marta", email: nil, to: group.id)

        let expense = try await expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Dinner", amountMinor: 1000,
            splitEquallyAmong: [david.id, ana.id, marta.id]
        )

        let splits = try await expenses.splits(of: expense.id)
        #expect(splits.count == 3)
        #expect(splits.reduce(Int64(0)) { $0 + $1.amountMinor } == 1000)
    }

    @Test func parsesAmountsIntoMinorUnits() {
        #expect(Currency.eur.parse(minorUnits: "12.5") == 1250)
        #expect(Currency.eur.parse(minorUnits: "12,50") == 1250)
        #expect(Currency.eur.parse(minorUnits: " 7 ") == 700)
        #expect(Currency.eur.parse(minorUnits: "0.05") == 5)
        #expect(Currency.jpy.parse(minorUnits: "500") == 500)
        #expect(Currency.eur.parse(minorUnits: "1.234") == nil)
        #expect(Currency.jpy.parse(minorUnits: "5.5") == nil)
        #expect(Currency.eur.parse(minorUnits: "") == nil)
        #expect(Currency.eur.parse(minorUnits: "-3") == nil)
        #expect(Currency.eur.parse(minorUnits: "abc") == nil)
        #expect(Currency.eur.parse(minorUnits: "1.2.3") == nil)
        #expect(Currency.eur.parse(minorUnits: ".5") == nil)
    }
}
