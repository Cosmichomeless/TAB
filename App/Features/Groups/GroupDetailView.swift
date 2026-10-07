import SwiftUI
import TABCore

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: ExpenseGroup

    @State private var members: [User] = []
    @State private var expenses: [Expense] = []
    @State private var balances: [Balance] = []
    @State private var settlements: [Settlement] = []
    @State private var showingAddParticipant = false
    @State private var showingAddExpense = false

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
            Section("Balances") {
                ForEach(balances, id: \.userID) { balance in
                    HStack {
                        Text(name(of: balance.userID))
                        Spacer()
                        Text(group.currency.format(minorUnits: balance.netMinor))
                            .monospacedDigit()
                            .foregroundStyle(balance.netMinor < 0 ? .red : balance.netMinor > 0 ? .green : .secondary)
                    }
                }
            }
            if !settlements.isEmpty {
                Section("Suggested settlements") {
                    ForEach(settlements, id: \.self) { settlement in
                        HStack {
                            Text("\(name(of: settlement.from)) pays \(name(of: settlement.to))")
                            Spacer()
                            Text(group.currency.format(minorUnits: settlement.amountMinor)).monospacedDigit()
                        }
                    }
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
            Button("Add expense", systemImage: "plus") { showingAddExpense = true }
                .disabled(members.isEmpty)
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView(group: group, members: members)
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
        if let expenseRepository = model.expenseRepository,
           let ledger = try? await expenseRepository.ledger(in: group.id) {
            expenses = ledger.map(\.expense)
            balances = BalanceCalculator.balances(for: ledger, members: members.map(\.id))
            settlements = BalanceCalculator.settlements(for: balances)
        }
    }

    private func name(of id: UUID) -> String {
        members.first { $0.id == id }?.name ?? "Unknown"
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

struct AddExpenseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ExpenseGroup
    let members: [User]

    @State private var title = ""
    @State private var amount = ""
    @State private var payerID: UUID
    @State private var selected: Set<UUID>
    @State private var errorMessage: String?

    init(group: ExpenseGroup, members: [User]) {
        self.group = group
        self.members = members
        _payerID = State(initialValue: members.first?.id ?? UUID())
        _selected = State(initialValue: Set(members.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Amount (\(group.currency.code))", text: $amount)
                    .keyboardType(.decimalPad)
                Picker("Paid by", selection: $payerID) {
                    ForEach(members) { Text($0.name).tag($0.id) }
                }
                Section("Split equally between") {
                    ForEach(members) { member in
                        Toggle(member.name, isOn: Binding(
                            get: { selected.contains(member.id) },
                            set: { isOn in
                                if isOn { selected.insert(member.id) } else { selected.remove(member.id) }
                            }
                        ))
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("New expense")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                }
            }
        }
    }

    private func save() async {
        guard let repository = model.expenseRepository else { return }
        guard let amountMinor = group.currency.parse(minorUnits: amount), amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }
        do {
            _ = try await repository.createExpense(
                groupID: group.id, paidBy: payerID, title: title,
                amountMinor: amountMinor, splitEquallyAmong: Array(selected)
            )
            dismiss()
        } catch DomainError.emptyTitle {
            errorMessage = "Enter a title."
        } catch DomainError.noParticipants {
            errorMessage = "Select at least one participant."
        } catch {
            errorMessage = "The expense could not be saved."
        }
    }
}
