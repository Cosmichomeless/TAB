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

    /// Up to this many members with a balance, the payments are the fewest possible (see `settlements`).
    /// Above it the search would be too slow for a phone and the greedy answer is used instead.
    static let exactSearchLimit = 18

    /// A short list of payments that brings every balance to zero.
    ///
    /// The fewest payments possible are `n - g`, with `n` the members who owe or are owed and `g` the most
    /// groups of them whose balances add up to zero on their own: each such group settles inside itself with
    /// one payment fewer than it has members. Finding `g` is exact for up to `exactSearchLimit` members;
    /// beyond that every member goes in one group, which needs at most `n - 1` payments.
    /// Inside a group the largest debtor pays the largest creditor, with ties broken by user id, so the
    /// result is deterministic and does not depend on the order of `balances`.
    public static func settlements(for balances: [Balance]) -> [Settlement] {
        let open = balances.filter { $0.netMinor != 0 }.sorted { $0.userID.uuidString < $1.userID.uuidString }
        guard !open.isEmpty else { return [] }
        let groups = open.count <= exactSearchLimit ? zeroSumGroups(of: open) : [open]
        return groups.flatMap(greedySettlements)
            .sorted { lhs, rhs in
                if lhs.amountMinor != rhs.amountMinor { return lhs.amountMinor > rhs.amountMinor }
                if lhs.from != rhs.from { return lhs.from.uuidString < rhs.from.uuidString }
                return lhs.to.uuidString < rhs.to.uuidString
            }
    }

    /// Splits `balances` into the most groups whose balances add up to zero. `dp[mask]` is how many such groups
    /// the members in `mask` can be cut into when they are taken out one at a time, so a group closes whenever
    /// the members left add up to zero.
    private static func zeroSumGroups(of balances: [Balance]) -> [[Balance]] {
        let n = balances.count
        let full = (1 << n) - 1
        var sum = [Int64](repeating: 0, count: full + 1)
        for mask in 1...full {
            let low = mask.trailingZeroBitCount
            sum[mask] = sum[mask & (mask - 1)] + balances[low].netMinor
        }
        var best = [UInt8](repeating: 0, count: full + 1)
        for mask in 1...full {
            var top: UInt8 = 0
            var rest = mask
            while rest != 0 {
                let bit = rest & -rest
                top = max(top, best[mask ^ bit])
                rest ^= bit
            }
            best[mask] = top + (sum[mask] == 0 ? 1 : 0)
        }

        var groups: [[Balance]] = []
        var current: [Balance] = []
        var mask = full
        while mask != 0 {
            let closes: UInt8 = sum[mask] == 0 ? 1 : 0
            var next = 0
            var rest = mask
            while rest != 0 {
                let bit = rest & -rest
                if best[mask ^ bit] + closes == best[mask] { next = mask ^ bit; break }
                rest ^= bit
            }
            let taken = mask ^ next
            current.append(balances[taken.trailingZeroBitCount])
            mask = next
            if sum[mask] == 0 { groups.append(current); current = [] }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Largest debtor pays largest creditor until the group is settled.
    private static func greedySettlements(for balances: [Balance]) -> [Settlement] {
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
