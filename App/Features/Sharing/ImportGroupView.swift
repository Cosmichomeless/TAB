import SwiftUI
import TABCore

/// Shows what a shared group contains and asks how to bring it in. Nothing is saved until "Import".
struct ImportGroupView: View {
    let snapshot: GroupSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var existing: ExpenseGroup?
    @State private var mode: GroupArchive.ImportMode = .updateExisting
    @State private var me: UUID?
    @State private var message: String?
    @State private var working = false

    private var currency: Currency { snapshot.group.currency }
    private var canUpdate: Bool { existing.map { $0.currency == currency } ?? true }
    private var userIsInFile: Bool { snapshot.participants.contains { $0.id == model.currentUser?.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    if let existing { alreadyHere(existing) }
                    if !userIsInFile { whoAreYou }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.negative).padding(.horizontal, 4)
                    }
                    Button("Import group", action: runImport)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working)
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("Import group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingImport = nil } }
            }
            .task {
                existing = try? await model.archive?.existingGroup(matching: snapshot)
                if !canUpdate { mode = .addAsCopy }
            }
        }
        .tint(Theme.accent)
    }

    private var summary: some View {
        let total = snapshot.expenses.reduce(Int64(0)) { $0 + $1.amountMinor }
        return CardSection("Group") {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.group.name).font(.title2.weight(.semibold))
                Text("\(snapshot.participants.count) people · \(snapshot.expenses.count) expenses")
                    .foregroundStyle(.secondary)
                Text("Total \(currency.format(minorUnits: total))").foregroundStyle(.secondary)
                Text(snapshot.participants.map(\.name).formatted(.list(type: .and)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .accessibilityElement(children: .combine)
        }
    }

    private func alreadyHere(_ group: ExpenseGroup) -> some View {
        CardSection("You already have this group") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("How to import", selection: $mode) {
                    if canUpdate { Text("Update it").tag(GroupArchive.ImportMode.updateExisting) }
                    Text("Add a copy").tag(GroupArchive.ImportMode.addAsCopy)
                }
                .pickerStyle(.segmented)
                Text(mode == .updateExisting
                    ? String(localized: "The expenses in your group are replaced by the ones in this file.")
                    : String(localized: "Your group stays as it is and a new one is created."))
                    .font(.footnote).foregroundStyle(.secondary)
                if !canUpdate {
                    Text("Your group uses \(group.currency.code) and this one uses \(currency.code), so it cannot be updated.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private var whoAreYou: some View {
        CardSection("Which one are you?") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Which one are you?", selection: $me) {
                    Text("None of them").tag(UUID?.none)
                    ForEach(snapshot.participants, id: \.id) { person in
                        Text(person.name).tag(UUID?.some(person.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Pick yourself so the balances show what you owe or are owed. If you skip it, you join the group as a new member.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func runImport() {
        working = true
        Task {
            do {
                try await model.importGroup(snapshot, mode: mode, asParticipant: userIsInFile ? nil : me)
                model.pendingImport = nil
            } catch {
                message = AppModel.message(for: error)
                working = false
            }
        }
    }
}
