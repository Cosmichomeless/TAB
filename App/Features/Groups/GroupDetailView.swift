import SwiftUI
import TABCore

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: ExpenseGroup

    @State private var members: [User] = []
    @State private var expenses: [Expense] = []
    @State private var showingAddParticipant = false

    var body: some View {
        List {
            Section("Expenses") {
                if expenses.isEmpty {
                    Text("No expenses yet").foregroundStyle(.secondary)
                }
                ForEach(expenses) { expense in
                    ExpenseRow(expense: expense, payer: members.first { $0.id == expense.paidBy })
                }
            }
            Section("Members") {
                ForEach(members) { member in
                    VStack(alignment: .leading) {
                        Text(member.name)
                        if let email = member.email {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .toolbar {
            Button("Add participant", systemImage: "person.badge.plus") { showingAddParticipant = true }
        }
        .sheet(isPresented: $showingAddParticipant) {
            AddParticipantView(group: group)
        }
        .task {
            guard let repository = model.repository else { return }
            await reload(repository)
            for await _ in repository.changes() {
                await reload(repository)
            }
        }
    }

    private func reload(_ repository: SQLiteGroupRepository) async {
        members = (try? await repository.members(of: group.id)) ?? members
        if let expenseRepository = model.expenseRepository {
            expenses = (try? await expenseRepository.expenses(in: group.id)) ?? expenses
        }
    }
}

struct ExpenseRow: View {
    let expense: Expense
    let payer: User?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(expense.title)
                Text("Paid by \(payer?.name ?? "unknown") · \(expense.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(expense.currency.format(minorUnits: expense.amountMinor))
                .monospacedDigit()
        }
    }
}

struct AddParticipantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ExpenseGroup

    @State private var name = ""
    @State private var email = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Email (optional)", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add participant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                _ = try await model.repository?.addParticipant(name: name, email: email, to: group.id)
                                dismiss()
                            } catch DomainError.invalidEmail {
                                errorMessage = "Enter a valid email or leave it empty."
                            } catch {
                                errorMessage = "Enter the participant's name."
                            }
                        }
                    }
                }
            }
        }
    }
}
