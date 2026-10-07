import SwiftUI
import TABCore

/// Where synchronization stands, in one line. Never modal: it informs, and tapping it syncs now.
struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let headline = model.syncOverview.headline
        Button {
            model.requestSync()
        } label: {
            HStack(spacing: 8) {
                if headline == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Self.icon(for: headline))
                }
                text(for: headline)
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Self.color(for: headline))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .buttonStyle(.plain)
        .disabled(headline == .localOnly)
        .accessibilityHint(headline == .localOnly ? "" : "Synchronizes now")
    }

    private func text(for headline: SyncHeadline) -> Text {
        switch headline {
        case .localOnly:
            Text("Local only · changes stay on this device")
        case .syncing:
            Text("Syncing…")
        case .needsSignIn(let waiting):
            Text("Sign in to sync") + Text(waiting > 0 ? " · \(waiting) saved on this device" : "")
        case .accountMismatch:
            Text("This device belongs to another account")
        case .conflicts(let count):
            Text("\(count) change(s) need your attention")
        case .failed(let count):
            Text("\(count) change(s) could not sync yet · will retry")
        case .offline(let waiting):
            Text("Offline") + Text(waiting > 0 ? " · \(waiting) saved on this device" : "")
        case .error(let message):
            Text("Sync problem: \(message)")
        case .waiting(let count):
            Text("\(count) change(s) waiting to sync")
        case .synced:
            if let date = model.lastSyncedAt {
                Text("Synced · ") + Text(date, format: .relative(presentation: .numeric))
            } else {
                Text("Synced")
            }
        }
    }

    private static func icon(for headline: SyncHeadline) -> String {
        switch headline {
        case .localOnly: "iphone"
        case .syncing: "arrow.triangle.2.circlepath"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .accountMismatch, .conflicts: "exclamationmark.triangle"
        case .failed, .error: "exclamationmark.icloud"
        case .offline: "icloud.slash"
        case .waiting: "icloud.and.arrow.up"
        case .synced: "checkmark.icloud"
        }
    }

    private static func color(for headline: SyncHeadline) -> Color {
        switch headline {
        case .conflicts, .accountMismatch: Theme.warning
        case .failed, .error: Theme.negative
        default: Theme.accent
        }
    }
}

/// Small per-row indicator. Icon plus an accessibility label, so it never relies on colour alone.
struct SyncBadge: View {
    let status: SyncStatus

    var body: some View {
        Image(systemName: icon)
            .font(.footnote)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    private var icon: String {
        switch status {
        case .synced: "checkmark.icloud"
        case .pending: "icloud.and.arrow.up"
        case .failed: "exclamationmark.icloud"
        case .conflict: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .synced, .pending: Theme.accent
        case .failed: Theme.negative
        case .conflict: Theme.warning
        }
    }

    private var label: LocalizedStringKey {
        switch status {
        case .synced: "Synced"
        case .pending: "Waiting to sync"
        case .failed: "Sync failed, will retry"
        case .conflict: "Needs your attention"
        }
    }
}
