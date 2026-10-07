import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .needsProfile:
            OnboardingView()
        case .ready:
            NavigationStack { GroupListView() }
        case .failed(let message):
            ContentUnavailableView("Could not open the database", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What should we call you?") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Welcome to TAB")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        Task {
                            do { try await model.createProfile(name: name) }
                            catch { errorMessage = "Enter a name to continue." }
                        }
                    }
                }
            }
        }
    }
}
