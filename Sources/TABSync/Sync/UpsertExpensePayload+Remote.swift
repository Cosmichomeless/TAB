import Foundation
import TABCore

extension UpsertExpensePayload {
    /// The server's copy of an expense, in the same shape as a local operation so both sides can be compared.
    init(remote: RemoteExpense) {
        self.init(
            id: remote.id, groupID: remote.groupID, paidBy: remote.paidBy, title: remote.title,
            amountMinor: remote.amountMinor, createdAt: remote.createdAt.millisecondsSince1970,
            updatedAt: remote.updatedAt.millisecondsSince1970, deletedAt: remote.deletedAt?.millisecondsSince1970,
            splits: remote.splits.map { Split(id: $0.id, userID: $0.userID, amountMinor: $0.amountMinor) }
        )
    }
}
