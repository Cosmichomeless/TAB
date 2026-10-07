import SwiftUI
import TABCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ZStack {
                BrandBackground().ignoresSafeArea()
                ProgressView().tint(.white)
            }
        case .needsProfile:
            OnboardingView()
        case .ready:
            NavigationStack { GroupListView() }
                .tint(Theme.accent)
        case .failed(let message):
            ContentUnavailableView("Could not open your data", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}

/// First launch: the icon's colours and motif, one question, no account needed.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            BrandBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                LogoMark().frame(width: 150, height: 150)
                Text("TAB")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text("Split expenses with friends.\nEverything works offline.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 4)
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 12) {
                    Text("What should we call you?").font(.headline).foregroundStyle(.primary)
                    TextField("Your name", text: $name)
                        .textContentType(.givenName)
                        .focused($focused)
                        .submitLabel(.continue)
                        .onSubmit(create)
                        .padding(14)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.negative)
                    }
                    Button("Continue", action: create).buttonStyle(PrimaryButtonStyle())
                }
                .padding(20)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func create() {
        Task {
            do {
                try await model.createProfile(name: name)
            } catch {
                message = "Enter a name to continue."
            }
        }
    }
}
