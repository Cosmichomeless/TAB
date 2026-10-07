import SwiftUI
import TABCore

struct GroupListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewGroup = false
    @State private var showingAccount = false

    var body: some View {
        List(model.groups) { group in
            NavigationLink(value: group) {
                VStack(alignment: .leading) {
                    Text(group.name).font(.headline)
                    Text(group.currency.code).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.groups.isEmpty {
                ContentUnavailableView("No groups yet", systemImage: "person.3", description: Text("Create a group to start splitting expenses."))
            }
        }
        .navigationTitle("Groups")
        .navigationDestination(for: ExpenseGroup.self) { GroupDetailView(group: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New group", systemImage: "plus") { showingNewGroup = true }
            }
        }
        .sheet(isPresented: $showingNewGroup) { NewGroupView() }
        .sheet(isPresented: $showingAccount) { AccountView() }
    }
}

struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currency = Currency.eur
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                Picker("Currency", selection: $currency) {
                    ForEach(Currency.supported, id: \.code) { Text($0.code).tag($0) }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("New group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await model.createGroup(name: name, currency: currency)
                                dismiss()
                            } catch {
                                errorMessage = "Enter a group name."
                            }
                        }
                    }
                }
            }
        }
    }
}
