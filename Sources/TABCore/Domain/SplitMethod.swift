import Foundation

/// How an expense is divided among the people who take part in it.
///
/// Every method ends as exact minor units per person that add up to the amount, so balances,
/// storage and sync never need to know which method produced them.
public enum SplitMethod: Hashable, Sendable {
    /// The same amount for everyone; leftover minor units go to the participants whose id sorts first.
    case equal(among: [UUID])
    /// Parts, for example 2 parts and 1 part: whoever has 2 pays double. Every part is at least 1.
    case shares([UUID: Int64])
    /// Hundredths of a percent (3333 is 33.33 %). They must add up to 10 000.
    case percentages([UUID: Int64])
    /// The amount each person owes. They must add up to the expense amount; zero means "not taking part".
    case exact([UUID: Int64])

    public static let fullPercentage: Int64 = 10_000
}

/// Turns a `SplitMethod` into the shares stored with an expense.
///
/// For `shares` and `percentages` each person gets the floor of `amount × weight / total weight`, and the
/// leftover minor units go one by one to the largest fractional remainders. Ties are broken by canonical
/// UUID string, so the result depends only on the amount, the weights and the people, never on input order
/// or on the device calculating it.
public enum SplitCalculator {
    public static func shares(amountMinor: Int64, method: SplitMethod) throws -> [SplitShare] {
        guard amountMinor > 0 else { throw DomainError.invalidAmount }
        switch method {
        case .equal(let participants):
            return try EqualSplit.shares(amountMinor: amountMinor, among: participants)
        case .shares(let parts):
            return try weighted(amountMinor: amountMinor, weights: parts)
        case .percentages(let percentages):
            let total = try validWeights(percentages).reduce(0) { $0 + $1.value }
            guard total == SplitMethod.fullPercentage else { throw DomainError.percentagesDoNotAddUp(actual: total) }
            return try weighted(amountMinor: amountMinor, weights: percentages)
        case .exact(let amounts):
            return try exact(amountMinor: amountMinor, amounts: amounts)
        }
    }

    private static func validWeights(_ weights: [UUID: Int64]) throws -> [UUID: Int64] {
        guard !weights.isEmpty else { throw DomainError.noParticipants }
        for (id, weight) in weights where weight <= 0 { throw DomainError.invalidSplitWeight(id) }
        return weights
    }

    private static func weighted(amountMinor: Int64, weights: [UUID: Int64]) throws -> [SplitShare] {
        let weights = try validWeights(weights)
        let ordered = weights.keys.sorted { $0.uuidString < $1.uuidString }
        let (total, totalOverflow) = weights.values.reduce((Int64(0), false)) { acc, weight in
            let (sum, overflow) = acc.0.addingReportingOverflow(weight)
            return (sum, acc.1 || overflow)
        }
        guard !totalOverflow else { throw DomainError.invalidAmount }

        var shares: [(id: UUID, amount: Int64, remainder: Int64)] = []
        for id in ordered {
            // 128-bit product: amount × weight can exceed Int64 for large amounts and weights.
            let (high, low) = amountMinor.multipliedFullWidth(by: weights[id]!)
            let (quotient, remainder) = total.dividingFullWidth((high, low))
            shares.append((id, quotient, remainder))
        }
        let leftover = Int(amountMinor - shares.reduce(0) { $0 + $1.amount })
        let receivers = Set(
            shares.enumerated()
                .sorted { ($0.element.remainder, $1.offset) > ($1.element.remainder, $0.offset) }
                .prefix(leftover)
                .map(\.offset)
        )
        return shares.enumerated().map { index, entry in
            SplitShare(userID: entry.id, amountMinor: entry.amount + (receivers.contains(index) ? 1 : 0))
        }
    }

    private static func exact(amountMinor: Int64, amounts: [UUID: Int64]) throws -> [SplitShare] {
        for (id, amount) in amounts where amount < 0 { throw DomainError.invalidSplitWeight(id) }
        let taking = amounts.filter { $0.value > 0 }
        guard !taking.isEmpty else { throw DomainError.noParticipants }
        let (sum, overflow) = taking.values.reduce((Int64(0), false)) { acc, amount in
            let (next, over) = acc.0.addingReportingOverflow(amount)
            return (next, acc.1 || over)
        }
        guard !overflow, sum == amountMinor else {
            throw DomainError.splitsDoNotMatchAmount(expected: amountMinor, actual: overflow ? .max : sum)
        }
        return taking.keys.sorted { $0.uuidString < $1.uuidString }.map { SplitShare(userID: $0, amountMinor: taking[$0]!) }
    }
}

extension ExpenseRepository {
    /// Records an expense divided with `method`.
    public func createExpense(
        groupID: UUID, paidBy: UUID, title: String, amountMinor: Int64, method: SplitMethod
    ) async throws -> Expense {
        try await createExpense(
            groupID: groupID, paidBy: paidBy, title: title, amountMinor: amountMinor,
            shares: try SplitCalculator.shares(amountMinor: amountMinor, method: method)
        )
    }

    /// Edits an expense, dividing the new amount with `method`.
    public func updateExpense(
        id: UUID, paidBy: UUID, title: String, amountMinor: Int64, method: SplitMethod
    ) async throws -> Expense {
        try await updateExpense(
            id: id, paidBy: paidBy, title: title, amountMinor: amountMinor,
            shares: try SplitCalculator.shares(amountMinor: amountMinor, method: method)
        )
    }
}
