import Foundation

/// An expense together with its splits, the only input balances are derived from.
public struct ExpenseWithSplits: Hashable, Sendable {
    public let expense: Expense
    public let splits: [ExpenseSplit]

    public init(expense: Expense, splits: [ExpenseSplit]) {
        self.expense = expense
        self.splits = splits
    }
}

/// A member's net position in minor units. Positive: the member is owed money. Negative: owes money.
public struct Balance: Hashable, Sendable {
    public let userID: UUID
    public let netMinor: Int64

    public init(userID: UUID, netMinor: Int64) {
        self.userID = userID
        self.netMinor = netMinor
    }
}

/// A suggested payment that moves `amountMinor` from `from` to `to`.
public struct Settlement: Hashable, Sendable {
    public let from: UUID
    public let to: UUID
    public let amountMinor: Int64

    public init(from: UUID, to: UUID, amountMinor: Int64) {
        self.from = from
        self.to = to
        self.amountMinor = amountMinor
    }
}

/// Balances are never stored: they are recomputed from expenses and splits, so there is no second
/// copy of the truth to keep in sync.
public enum BalanceCalculator {
    /// Net balance of every member: what they paid minus what they owe. Deleted expenses are ignored.
    /// The result follows the order of `members` and always adds up to zero.
    public static func balances(for ledger: [ExpenseWithSplits], members: [UUID]) -> [Balance] {
        var net: [UUID: Int64] = Dictionary(uniqueKeysWithValues: members.map { ($0, 0) })
        for entry in ledger where entry.expense.deletedAt == nil {
            net[entry.expense.paidBy, default: 0] += entry.expense.amountMinor
            for split in entry.splits {
                net[split.userID, default: 0] -= split.amountMinor
            }
        }
        let extras = net.keys.filter { !members.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return (members + extras).map { Balance(userID: $0, netMinor: net[$0] ?? 0) }
    }

    /// A short list of payments that brings every balance to zero.
    ///
    /// Greedy matching of the largest debtor with the largest creditor (ties broken by user id), which is
    /// deterministic and needs at most `participants - 1` payments.
    public static func settlements(for balances: [Balance]) -> [Settlement] {
        func order(_ lhs: Balance, _ rhs: Balance) -> Bool {
            let (a, b) = (abs(lhs.netMinor), abs(rhs.netMinor))
            return a != b ? a > b : lhs.userID.uuidString < rhs.userID.uuidString
        }
        var creditors = balances.filter { $0.netMinor > 0 }.sorted(by: order)
        var debtors = balances.filter { $0.netMinor < 0 }.sorted(by: order)

        var result: [Settlement] = []
        var c = 0
        var d = 0
        while c < creditors.count, d < debtors.count {
            let amount = min(creditors[c].netMinor, -debtors[d].netMinor)
            result.append(Settlement(from: debtors[d].userID, to: creditors[c].userID, amountMinor: amount))
            creditors[c] = Balance(userID: creditors[c].userID, netMinor: creditors[c].netMinor - amount)
            debtors[d] = Balance(userID: debtors[d].userID, netMinor: debtors[d].netMinor + amount)
            if creditors[c].netMinor == 0 { c += 1 }
            if debtors[d].netMinor == 0 { d += 1 }
        }
        return result
    }
}

extension ExpenseRepository {
    /// Live expenses of a group with their splits.
    public func ledger(in groupID: UUID) async throws -> [ExpenseWithSplits] {
        var ledger: [ExpenseWithSplits] = []
        for expense in try await expenses(in: groupID) {
            ledger.append(ExpenseWithSplits(expense: expense, splits: try await splits(of: expense.id)))
        }
        return ledger
    }
}
