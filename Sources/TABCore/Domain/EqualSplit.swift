import Foundation

/// Deterministic equal splitting in minor units.
///
/// Every participant gets `amount / n` (rounded down). The `amount % n` leftover minor units are
/// handed out one each to the participants whose id sorts first (by canonical UUID string), so the
/// result depends only on the amount and the set of participants, never on input order or on the
/// device doing the calculation. The shares always add up exactly to the amount.
public enum EqualSplit {
    public static func shares(amountMinor: Int64, among participants: [UUID]) throws -> [SplitShare] {
        guard amountMinor > 0 else { throw DomainError.invalidAmount }
        guard !participants.isEmpty else { throw DomainError.noParticipants }

        var seen = Set<UUID>()
        for id in participants {
            guard seen.insert(id).inserted else { throw DomainError.duplicateParticipant(id) }
        }

        let ordered = participants.sorted { $0.uuidString < $1.uuidString }
        let count = Int64(ordered.count)
        let base = amountMinor / count
        let remainder = Int(amountMinor % count)

        return ordered.enumerated().map { index, id in
            SplitShare(userID: id, amountMinor: base + (index < remainder ? 1 : 0))
        }
    }
}

extension ExpenseRepository {
    /// Records an expense split equally among `participants`.
    public func createExpense(
        groupID: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        splitEquallyAmong participants: [UUID]
    ) async throws -> Expense {
        try await createExpense(
            groupID: groupID,
            paidBy: paidBy,
            title: title,
            amountMinor: amountMinor,
            shares: try EqualSplit.shares(amountMinor: amountMinor, among: participants)
        )
    }
}

extension ExpenseRepository {
    /// Edits an expense, splitting the new amount equally among `participants`.
    public func updateExpense(
        id: UUID,
        paidBy: UUID,
        title: String,
        amountMinor: Int64,
        splitEquallyAmong participants: [UUID]
    ) async throws -> Expense {
        try await updateExpense(
            id: id, paidBy: paidBy, title: title, amountMinor: amountMinor,
            shares: try EqualSplit.shares(amountMinor: amountMinor, among: participants)
        )
    }
}

extension ExpenseRepository {
    public func updateExpense(
        id: UUID, paidBy: UUID, title: String, amountMinor: Int64,
        originalAmountMinor: Int64, originalSplits: [ExpenseSplit], participants: [UUID]
    ) async throws -> Expense {
        let shares: [SplitShare]
        if amountMinor == originalAmountMinor && Set(participants) == Set(originalSplits.map(\.userID)) {
            shares = originalSplits.map { SplitShare(userID: $0.userID, amountMinor: $0.amountMinor) }
        } else {
            shares = try EqualSplit.shares(amountMinor: amountMinor, among: participants)
        }
        return try await updateExpense(id: id, paidBy: paidBy, title: title, amountMinor: amountMinor, shares: shares)
    }
}
