import SwiftUI
import TABCore
#if SYNC
import TABSync
#endif

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: ExpenseGroup

    @State private var members: [User] = []
    @State private var expenses: [Expense] = []
    @State private var balances: [Balance] = []
    @State private var settlements: [Settlement] = []
    #if SYNC
    @State private var statuses: [UUID: SyncStatus] = [:]
    @State private var conflicts: [Conflict] = []
    @State private var showingConflicts = false
    #endif
    @State private var showingAddParticipant = false
    @State private var showingShare = false
    @State private var showingAddExpense = false
    @State private var editing: Expense?
    @State private var pendingDelete: Expense?
    @State private var settling: Settlement?
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                Hero(group: group, members: members, totalMinor: expenses.reduce(0) { $0 + $1.amountMinor },
                     myBalance: myBalance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            #if SYNC
            if attentionCount > 0 {
                Section {
                    ConflictBanner(count: attentionCount) { showingConflicts = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            #endif
            Section {
                if expenses.isEmpty {
                    Text("No expenses yet. Add the first one with the + button.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.card)
                }
                ForEach(expenses) { expense in
                    Button { editing = expense } label: {
                        #if SYNC
                        ExpenseRow(expense: expense, payer: member(expense.paidBy), status: statuses[expense.id])
                        #else
                        ExpenseRow(expense: expense, payer: member(expense.paidBy))
                        #endif
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
                        Button { settling = settlement } label: {
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
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settlement-\(name(of: settlement.from))-\(name(of: settlement.to))")
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
            Button("Share group", systemImage: "square.and.arrow.up") { showingShare = true }
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
        .sheet(isPresented: $showingShare) {
            ShareGroupView(group: group)
        }
        .sheet(item: $settling) { settlement in
            SettleUpView(
                group: group, settlement: settlement,
                from: name(of: settlement.from), to: name(of: settlement.to)
            )
        }
        #if SYNC
        .sheet(isPresented: $showingConflicts) {
            ConflictReviewView(group: group, members: members)
        }
        #endif
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
            #if SYNC
            Text("The balances are recalculated and the deletion syncs to the other devices.")
            #else
            Text("The balances are recalculated.")
            #endif
        }
        #if SYNC
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        #endif
        .alert("Could not delete", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        #if SYNC
        .task(id: model.syncRevision) {
            statuses = await model.syncStatuses(of: expenses.map(\.id))
            conflicts = await model.conflicts(in: group.id)
            if let repository = model.repository { await reload(repository) }
        }
        #endif
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

    #if SYNC
    /// Edits that lost and have not been restored, or that still wait for a decision.
    private var attentionCount: Int {
        conflicts.filter { $0.status == .open || $0.resolution == .remoteWins }.count
    }
    #endif

    private func reload(_ repository: SQLiteGroupRepository) async {
        members = (try? await repository.members(of: group.id)) ?? members
        if let expenseRepository = model.expenseRepository,
           let ledger = try? await expenseRepository.ledger(in: group.id) {
            expenses = ledger.map(\.expense)
            balances = BalanceCalculator.balances(for: ledger, members: members.map(\.id))
            settlements = BalanceCalculator.settlements(for: balances)
            #if SYNC
            statuses = await model.syncStatuses(of: expenses.map(\.id))
            #endif
        }
        #if SYNC
        conflicts = await model.conflicts(in: group.id)
        #endif
    }

    private func member(_ id: UUID) -> User? { members.first { $0.id == id } }

    private func name(of id: UUID) -> String { member(id)?.name ?? "Unknown" }

    private func signed(_ minor: Int64) -> String {
        (minor > 0 ? "+" : "") + group.currency.format(minorUnits: minor)
    }
}

extension Settlement: @retroactive Identifiable {
    public var id: Settlement { self }
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

struct ExpenseRow: View {
    let expense: Expense
    let payer: User?
    #if SYNC
    /// `nil` when sync is not available (nothing to show).
    var status: SyncStatus?
    #endif

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
                #if SYNC
                if let status { SyncBadge(status: status) }
                #endif
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
    @State private var mode: SplitMode = .equal
    @State private var entries: [UUID: String] = [:]
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
                    CardSection("Split") {
                        Picker("Split method", selection: $mode) {
                            Text("Equal").tag(SplitMode.equal)
                            Text("Shares").tag(SplitMode.shares)
                            Text("Percent").tag(SplitMode.percentages)
                            Text("Exact").tag(SplitMode.exact)
                        }
                        .pickerStyle(.segmented)
                        .padding(12)
                        .disabled(splitLoadState != .loaded)
                        .onChange(of: mode) { _, newMode in prepareEntries(for: newMode) }
                        Divider().padding(.leading, 16)
                        ForEach(members) { member in
                            memberRow(member)
                            if member.id != members.last?.id { Divider().padding(.leading, 58) }
                        }
                    }
                    if let hint = modeHint {
                        Text(hint.text).font(.footnote).foregroundStyle(hint.isProblem ? Theme.negative : Color.secondary)
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
                // Number pads have no return key, and the keyboard would otherwise cover the fields below.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .task { if editing != nil { await loadSplit() } }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func memberRow(_ member: User) -> some View {
        Group {
            if mode == .equal {
                Toggle(isOn: Binding(
                    get: { selected.contains(member.id) },
                    set: { if $0 { selected.insert(member.id) } else { selected.remove(member.id) } }
                )) {
                    memberLabel(member)
                }
            } else {
                HStack(spacing: 12) {
                    memberLabel(member)
                    Spacer()
                    TextField(entryPlaceholder, text: Binding(
                        get: { entries[member.id] ?? "" },
                        set: { entries[member.id] = $0 }
                    ))
                    .keyboardType(mode == .shares ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .accessibilityLabel(member.name)
                    Text(entrySuffix).foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(14)
        .disabled(splitLoadState != .loaded)
    }

    private func memberLabel(_ member: User) -> some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, id: member.id, size: 32)
            Text(member.name)
        }
    }

    private var entryPlaceholder: String { mode == .shares ? "0" : "0.00" }

    private var entrySuffix: String {
        switch mode {
        case .shares: String(localized: "parts")
        case .percentages: "%"
        case .exact: group.currency.code
        case .equal: ""
        }
    }

    /// What is still to assign (or too much assigned) in percent and exact modes.
    private var modeHint: (text: String, isProblem: Bool)? {
        guard splitLoadState == .loaded, mode != .equal else { return nil }
        guard mode != .shares else { return ("Each person pays in proportion to their parts. Leave a field empty to leave someone out.", false) }
        guard let minor = group.currency.parse(minorUnits: amount), minor > 0,
              let left = SplitInput.remaining(
                mode: mode, amountMinor: minor, participants: members.map(\.id), entries: entries, currency: group.currency
              ) else { return nil }
        let digits = mode == .percentages ? 2 : group.currency.minorUnitDigits
        let scale = (0..<digits).reduce(Int64(1)) { value, _ in value * 10 }
        let shown = Decimal(abs(left)) / Decimal(scale)
        let unit = mode == .percentages ? "%" : group.currency.code
        if left == 0 { return (String(localized: "Everything is assigned."), false) }
        if left > 0 { return (String(localized: "\(shown.formatted()) \(unit) left to assign."), true) }
        return (String(localized: "\(shown.formatted()) \(unit) over."), true)
    }

    /// Starts the fields of a method from something sensible instead of empty.
    private func prepareEntries(for newMode: SplitMode) {
        let people = members.map(\.id).filter { selected.contains($0) }
        switch newMode {
        case .equal:
            return
        case .shares:
            entries = Dictionary(uniqueKeysWithValues: people.map { ($0, "1") })
        case .percentages:
            let method = try? SplitCalculator.shares(amountMinor: SplitMethod.fullPercentage, method: .equal(among: people))
            entries = Dictionary(uniqueKeysWithValues: (method ?? []).map {
                ($0.userID, Currency.eur.input(minorUnits: $0.amountMinor))
            })
        case .exact:
            if !originalSplits.isEmpty, group.currency.parse(minorUnits: amount) == editing?.amountMinor {
                entries = SplitInput.exactEntries(for: originalSplits, currency: group.currency)
            } else if let minor = group.currency.parse(minorUnits: amount), minor > 0,
                      let equal = try? SplitCalculator.shares(amountMinor: minor, method: .equal(among: people)) {
                entries = Dictionary(uniqueKeysWithValues: equal.map { ($0.userID, group.currency.input(minorUnits: $0.amountMinor)) })
            } else {
                entries = [:]
            }
        }
    }

    private var willRecalculateSplit: Bool {
        guard mode == .equal, let editing, splitLoadState == .loaded else { return false }
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
            // An unequal split opens in exact mode so what was agreed stays visible and editable.
            if !SplitInput.isEqual(splits, amountMinor: editing.amountMinor) {
                entries = SplitInput.exactEntries(for: splits, currency: group.currency)
                mode = .exact
            }
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
            let participants = members.map(\.id).filter { mode == .equal ? selected.contains($0) : true }
            let method = try SplitInput.method(mode: mode, participants: participants, entries: entries, currency: group.currency)
            if let editing {
                if mode == .equal {
                    try await model.updateExpense(id: editing.id, paidBy: payerID, title: title,
                                                  amountMinor: minor, originalAmountMinor: editing.amountMinor,
                                                  originalSplits: originalSplits, participants: participants)
                } else {
                    try await model.updateExpense(id: editing.id, paidBy: payerID, title: title,
                                                  amountMinor: minor, method: method)
                }
            } else {
                try await model.addExpense(groupID: group.id, paidBy: payerID, title: title,
                                           amountMinor: minor, method: method)
            }
            dismiss()
        } catch DomainError.emptyTitle { message = "Enter a title." }
        catch DomainError.noParticipants { message = "Select at least one participant." }
        catch DomainError.invalidSplitWeight { message = "Check the numbers in the split: use positive numbers only." }
        catch DomainError.percentagesDoNotAddUp { message = "The percentages must add up to 100 %." }
        catch DomainError.splitsDoNotMatchAmount { message = "The amounts must add up to the expense total." }
        catch { message = "The expense could not be saved." }
    }
}
