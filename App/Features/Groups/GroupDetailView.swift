import SwiftUI
import TABCore

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: ExpenseGroup

    @State private var members: [User] = []
    @State private var expenses: [Expense] = []
    @State private var balances: [Balance] = []
    @State private var settlements: [Settlement] = []
    @State private var statuses: [UUID: SyncStatus] = [:]
    @State private var conflicts: [Conflict] = []
    @State private var showingAddParticipant = false
    @State private var showingAddExpense = false
    @State private var showingConflicts = false
    @State private var editing: Expense?
    @State private var pendingDelete: Expense?
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                Hero(group: group, members: members, totalMinor: expenses.reduce(0) { $0 + $1.amountMinor },
                     myBalance: myBalance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if attentionCount > 0 {
                Section {
                    ConflictBanner(count: attentionCount) { showingConflicts = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                if expenses.isEmpty {
                    Text("No expenses yet. Add the first one with the + button.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.card)
                }
                ForEach(expenses) { expense in
                    Button { editing = expense } label: {
                        ExpenseRow(expense: expense, payer: member(expense.paidBy), status: statuses[expense.id])
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.card)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = expense }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = expense }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = expense }
                    }
                }
            } header: {
                SectionTitle("Expenses")
            }
            Section {
                ForEach(balances, id: \.userID) { balance in
                    HStack(spacing: 12) {
                        Avatar(name: name(of: balance.userID), id: balance.userID, size: 34)
                        Text(name(of: balance.userID))
                        Spacer()
                        Text(signed(balance.netMinor))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(balance.netMinor < 0 ? Theme.negative : balance.netMinor > 0 ? Theme.positive : .secondary)
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                SectionTitle("Balances")
            }
            if !settlements.isEmpty {
                Section {
                    ForEach(settlements, id: \.self) { settlement in
                        HStack(spacing: 10) {
                            Avatar(name: name(of: settlement.from), id: settlement.from, size: 30)
                            Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(Theme.amber)
                            Avatar(name: name(of: settlement.to), id: settlement.to, size: 30)
                            Text("\(name(of: settlement.from)) pays \(name(of: settlement.to))")
                                .font(.subheadline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer()
                            Text(group.currency.format(minorUnits: settlement.amountMinor))
                                .monospacedDigit().fontWeight(.semibold)
                        }
                        .listRowBackground(Theme.card)
                    }
                } header: {
                    SectionTitle("Suggested settlements")
                }
            }
            Section {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        Avatar(name: member.name, id: member.id, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                            if let email = member.email {
                                Text(email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                SectionTitle("Members")
            }
        }
        .scrollContentBackground(.hidden)
        .brandScreen()
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add participant", systemImage: "person.badge.plus") { showingAddParticipant = true }
            Button("Add expense", systemImage: "plus") { showingAddExpense = true }
                .disabled(members.isEmpty)
        }
        .sheet(isPresented: $showingAddExpense) {
            ExpenseFormView(group: group, members: members, editing: nil)
        }
        .sheet(item: $editing) { expense in
            ExpenseFormView(group: group, members: members, editing: expense)
        }
        .sheet(isPresented: $showingAddParticipant) {
            AddParticipantView(group: group)
        }
        .sheet(isPresented: $showingConflicts) {
            ConflictReviewView(group: group, members: members)
        }
        .confirmationDialog(
            "Delete this expense?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { expense in
            Button("Delete \"\(expense.title)\"", role: .destructive) {
                Task {
                    do { try await model.deleteExpense(id: expense.id) }
                    catch { actionError = "The expense could not be deleted." }
                }
            }
        } message: { _ in
            Text("The balances are recalculated and the deletion syncs to the other devices.")
        }
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        .alert("Could not delete", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task(id: model.syncRevision) {
            statuses = await model.syncStatuses(of: expenses.map(\.id))
            conflicts = await model.conflicts(in: group.id)
            if let repository = model.repository { await reload(repository) }
        }
        .task {
            guard let repository = model.repository else { return }
            await reload(repository)
            for await _ in repository.changes() {
                await reload(repository)
            }
        }
    }

    private var myBalance: Int64? {
        guard let me = model.currentUser else { return nil }
        return balances.first { $0.userID == me.id }?.netMinor
    }

    /// Edits that lost and have not been restored, or that still wait for a decision.
    private var attentionCount: Int {
        conflicts.filter { $0.status == .open || $0.resolution == .remoteWins }.count
    }

    private func reload(_ repository: SQLiteGroupRepository) async {
        members = (try? await repository.members(of: group.id)) ?? members
        if let expenseRepository = model.expenseRepository,
           let ledger = try? await expenseRepository.ledger(in: group.id) {
            expenses = ledger.map(\.expense)
            balances = BalanceCalculator.balances(for: ledger, members: members.map(\.id))
            settlements = BalanceCalculator.settlements(for: balances)
            statuses = await model.syncStatuses(of: expenses.map(\.id))
        }
        conflicts = await model.conflicts(in: group.id)
    }

    private func member(_ id: UUID) -> User? { members.first { $0.id == id } }

    private func name(of id: UUID) -> String { member(id)?.name ?? "Unknown" }

    private func signed(_ minor: Int64) -> String {
        (minor > 0 ? "+" : "") + group.currency.format(minorUnits: minor)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}

/// Total spent and where the signed-in person stands, on the icon's gradient.
private struct Hero: View {
    @ScaledMetric(relativeTo: .largeTitle) private var totalFontSize: CGFloat = 38
    let group: ExpenseGroup
    let members: [User]
    let totalMinor: Int64
    let myBalance: Int64?

    var body: some View {
        ZStack(alignment: .topLeading) {
            BrandBackground()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total spent").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    Text(group.currency.format(minorUnits: totalMinor))
                        .font(.system(size: totalFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    HStack(spacing: -10) {
                        ForEach(members.prefix(5)) { member in
                            Avatar(name: member.name, id: member.id, size: 30)
                                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        }
                    }
                    Spacer()
                    if let myBalance { balanceChip(myBalance) }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func balanceChip(_ minor: Int64) -> some View {
        let text: String = minor == 0
            ? "You are settled"
            : minor > 0
                ? "You are owed \(group.currency.format(minorUnits: minor))"
                : "You owe \(group.currency.format(minorUnits: -minor))"
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(red: 0.07, green: 0.20, blue: 0.24))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(minor < 0 ? Theme.amber : Theme.mint, in: Capsule())
    }
}

private struct ConflictBanner: View {
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

struct ExpenseRow: View {
    let expense: Expense
    let payer: User?
    /// `nil` when sync is not available (nothing to show).
    var status: SyncStatus?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: payer?.name ?? "?", id: expense.paidBy, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.title).font(.body.weight(.medium)).lineLimit(2)
                Text("Paid by \(payer?.name ?? "unknown") · \(expense.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(expense.currency.format(minorUnits: expense.amountMinor))
                    .monospacedDigit().fontWeight(.semibold)
                if let status { SyncBadge(status: status) }
            }
        }
        .contentShape(Rectangle())
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Spacer()
                        Avatar(name: name.isEmpty ? "?" : name, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, size: 88)
                        Spacer()
                    }
                    CardSection("Who is joining \(group.name)?") {
                        TextField("Name", text: $name).padding(16)
                        Divider().padding(.leading, 16)
                        TextField("Email (optional)", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .padding(16)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.negative).padding(.horizontal, 4)
                    }
                    Text("They don't need the app: expenses can be split with anyone you add here.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("Add participant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await model.addParticipant(name: name, email: email, to: group.id)
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
        .tint(Theme.accent)
    }
}

struct ExpenseFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ExpenseGroup
    let members: [User]
    let editing: Expense?
    @State private var title: String
    @State private var amount: String
    @State private var payerID: UUID
    @State private var selected: Set<UUID>
    @State private var originalSplits: [ExpenseSplit] = []
    @State private var message: String?
    @State private var isSaving = false
    private enum SplitLoadState { case loading, loaded, failed }
    @State private var splitLoadState: SplitLoadState

    init(group: ExpenseGroup, members: [User], editing: Expense?) {
        self.group = group
        self.members = members
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _amount = State(initialValue: editing.map { group.currency.input(minorUnits: $0.amountMinor) } ?? "")
        _payerID = State(initialValue: editing?.paidBy ?? members.first?.id ?? UUID())
        _selected = State(initialValue: editing == nil ? Set(members.map(\.id)) : [])
        _splitLoadState = State(initialValue: editing == nil ? .loaded : .loading)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CardSection("Expense") {
                        TextField("Title", text: $title).padding(16)
                        Divider().padding(.leading, 16)
                        TextField("Amount (\(group.currency.code))", text: $amount)
                            .keyboardType(.decimalPad).padding(16)
                    }
                    CardSection("Paid by") {
                        Picker("Paid by", selection: $payerID) {
                            ForEach(members) { Text($0.name).tag($0.id) }
                        }
                        .padding(12)
                    }
                    CardSection(editing == nil ? "Split equally between" : "Split between") {
                        ForEach(members) { member in
                            Toggle(isOn: Binding(
                                get: { selected.contains(member.id) },
                                set: { if $0 { selected.insert(member.id) } else { selected.remove(member.id) } }
                            )) {
                                HStack(spacing: 12) {
                                    Avatar(name: member.name, id: member.id, size: 32)
                                    Text(member.name)
                                }
                            }
                            .padding(14)
                            .disabled(splitLoadState != .loaded)
                            if member.id != members.last?.id { Divider().padding(.leading, 58) }
                        }
                    }
                    if splitLoadState == .loading {
                        ProgressView("Loading split…")
                    } else if splitLoadState == .failed {
                        Button("Retry loading split") { Task { await loadSplit() } }
                    }
                    if willRecalculateSplit {
                        Text("Changing the amount or participants will replace the existing split with an equal split.")
                            .font(.footnote).foregroundStyle(Theme.warning)
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.negative) }
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle(editing == nil ? "New expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving || splitLoadState != .loaded)
                }
            }
            .task { if editing != nil { await loadSplit() } }
        }
        .tint(Theme.accent)
    }

    private var willRecalculateSplit: Bool {
        guard let editing, splitLoadState == .loaded else { return false }
        return group.currency.parse(minorUnits: amount) != editing.amountMinor ||
            selected != Set(originalSplits.map(\.userID))
    }

    private func loadSplit() async {
        guard let editing else { return }
        splitLoadState = .loading
        message = nil
        do {
            guard let repository = model.expenseRepository else {
                splitLoadState = .failed
                message = "Could not load this expense's split. Try again."
                return
            }
            let splits = try await repository.splits(of: editing.id)
            originalSplits = splits
            selected = Set(splits.map(\.userID))
            splitLoadState = .loaded
        } catch {
            splitLoadState = .failed
            message = "Could not load this expense's split. Try again."
        }
    }

    private func save() async {
        guard !isSaving, splitLoadState == .loaded else { return }
        guard let minor = group.currency.parse(minorUnits: amount), minor > 0 else {
            message = "Enter a valid amount."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let participants = members.map(\.id).filter { selected.contains($0) }
            if let editing {
                try await model.updateExpense(id: editing.id, paidBy: payerID, title: title,
                                              amountMinor: minor, originalAmountMinor: editing.amountMinor,
                                              originalSplits: originalSplits, participants: participants)
            } else {
                try await model.addExpense(groupID: group.id, paidBy: payerID, title: title,
                                           amountMinor: minor, splitEquallyAmong: participants)
            }
            dismiss()
        } catch DomainError.emptyTitle { message = "Enter a title." }
        catch DomainError.noParticipants { message = "Select at least one participant." }
        catch { message = "The expense could not be saved." }
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
