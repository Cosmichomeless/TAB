#if SYNC
import SwiftUI
import TABCore
import TABSync

struct ConflictBanner: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        Button(action: review) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.title3).foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 of your edits was replaced" : "\(count) of your edits were replaced")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Someone else changed the same expense first. Review and restore yours.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.amber.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.amber.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ConflictReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ExpenseGroup
    let members: [User]
    @State private var conflicts: [Conflict] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(conflicts) { conflict in
                    if conflict.status == .open || conflict.resolution == .remoteWins {
                        Section {
                            if let local = conflict.local {
                                version(local, heading: "Your edit (will replace current version)")
                            }
                            if let remote = conflict.remote {
                                version(remote, heading: "Current version")
                            }
                            Button("Restore my edit") { Task { await restore(conflict.id) } }
                                .disabled(conflict.local == nil || (conflict.status == .open && conflict.remoteVersion == nil))
                        } header: { Text(conflict.local?.title ?? "Expense conflict") }
                        .listRowBackground(Theme.card)
                    }
                }
                if let message { Text(message).foregroundStyle(Theme.negative) }
            }
            .scrollContentBackground(.hidden)
            .brandScreen()
            .navigationTitle("Review changes")
            .toolbar { Button("Done") { dismiss() } }
            .task { await reload() }
        }
        .tint(Theme.accent)
    }

    private func reload() async { conflicts = await model.conflicts(in: group.id) }

    private func version(_ expense: UpsertExpensePayload, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            LabeledContent("Title", value: expense.title)
            LabeledContent("Amount", value: group.currency.format(minorUnits: expense.amountMinor))
            LabeledContent("Paid by", value: name(of: expense.paidBy))
            LabeledContent("Status", value: expense.deletedAt == nil ? "Active" : "Deleted")
            VStack(alignment: .leading, spacing: 4) {
                Text("Split").foregroundStyle(.secondary)
                ForEach(expense.splits, id: \.id) { split in
                    LabeledContent(name(of: split.userID), value: group.currency.format(minorUnits: split.amountMinor))
                }
            }
        }
    }

    private func name(of id: UUID) -> String {
        members.first { $0.id == id }?.name ?? id.uuidString
    }

    private func restore(_ id: UUID) async {
        do { try await model.restoreConflict(id); await reload() }
        catch { message = "Could not restore your edit. Try again." }
    }
}
#endif
