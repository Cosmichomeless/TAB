import SwiftUI
import TABCore

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if !model.isBackendConfigured {
                    Section {
                        Text("Backend not configured. TAB keeps working fully offline on this device.")
                            .foregroundStyle(.secondary)
                    }
                } else if let session = model.session {
                    Section("Signed in") {
                        Text(session.email ?? session.userID.uuidString)
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    }
                } else {
                    Section("Account") {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                    Section {
                        Button("Sign in") { run { try await model.signIn(email: email, password: password) } }
                        Button("Create account") { run { try await model.signUp(email: email, password: password) } }
                    }
                    .disabled(isBusy || email.isEmpty || password.isEmpty)
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do { try await action() } catch { message = Self.describe(error) }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? AuthError {
        case .invalidCredentials: "Wrong email or password."
        case .emailAlreadyRegistered: "That email is already registered. Try signing in."
        case .weakPassword: "Choose a longer password."
        case .confirmationRequired: "Check your email to confirm the account, then sign in."
        case .offline: "You are offline. Your data is safe on this device; try again when connected."
        case .notConfigured: "Backend not configured."
        default: "Something went wrong. Please try again."
        }
    }
}
