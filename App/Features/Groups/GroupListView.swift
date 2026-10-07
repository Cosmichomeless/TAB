import SwiftUI
import TABCore

struct GroupListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewGroup = false
    @State private var showingAccount = false

    var body: some View {
        ScrollView {
            if model.groups.isEmpty {
                EmptyGroups { showingNewGroup = true }
                    .padding(.top, 40)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(model.groups) { group in
                        NavigationLink(value: group) {
                            GroupCard(group: group, summary: model.summaries[group.id], status: model.groupStatuses[group.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .brandScreen()
        .navigationTitle("Groups")
        .navigationDestination(for: ExpenseGroup.self) { GroupDetailView(group: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New group", systemImage: "plus") { showingNewGroup = true }
            }
        }
        .sheet(isPresented: $showingNewGroup) { NewGroupView() }
        .sheet(isPresented: $showingAccount) { AccountView() }
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
    }
}

private struct EmptyGroups: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gradient)
                LogoMark().frame(width: 74, height: 74)
            }
            .frame(width: 110, height: 110)
            Text("No groups yet").font(.title2.weight(.semibold))
            Text("Create a group for a trip, a flat or a night out, and add the people you share expenses with.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("New group", action: create)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 60)
                .padding(.top, 6)
        }
    }
}

private struct GroupCard: View {
    let group: ExpenseGroup
    let summary: GroupSummary?
    let status: SyncStatus?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gradient)
                Text(String(group.name.prefix(1)).uppercased())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(Theme.amber).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name).font(.headline).foregroundStyle(.primary)
                    if let status { SyncBadge(status: status) }
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let summary {
                balance(summary)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        guard let summary else { return group.currency.code }
        let people = summary.memberCount == 1 ? "1 person" : "\(summary.memberCount) people"
        return "\(people) · \(group.currency.format(minorUnits: summary.totalMinor))"
    }

    @ViewBuilder
    private func balance(_ summary: GroupSummary) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if summary.myBalanceMinor == 0 {
                Text("Settled").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Text(summary.myBalanceMinor > 0 ? "You are owed" : "You owe")
                    .font(.caption).foregroundStyle(.secondary)
                Text(group.currency.format(minorUnits: abs(summary.myBalanceMinor)))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(summary.myBalanceMinor > 0 ? Theme.positive : Theme.negative)
            }
        }
    }
}

struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currency = Currency.eur
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(Theme.gradient)
                            LogoMark().frame(width: 58, height: 58)
                        }
                        .frame(width: 88, height: 88)
                        Spacer()
                    }
                    CardSection("Name") {
                        TextField("Group name", text: $name)
                            .padding(16)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.negative)
                                .padding([.horizontal, .bottom], 16)
                        }
                    }
                    CardSection("Currency") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                            ForEach(Currency.supported, id: \.code) { option in
                                Button { currency = option } label: {
                                    Text(option.code)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .foregroundStyle(currency == option ? Color.white : Color.primary)
                                        .background(
                                            currency == option ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.background),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(currency == option ? .isSelected : [])
                            }
                        }
                        .padding(14)
                    }
                    Text("Every expense in the group uses this currency.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create) }
            }
        }
        .tint(Theme.accent)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            message = "Enter a group name."
            return
        }
        Task {
            do {
                try await model.createGroup(name: name, currency: currency)
                dismiss()
            } catch {
                message = "Enter a group name."
            }
        }
    }
}
