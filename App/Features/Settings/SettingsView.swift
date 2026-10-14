import SwiftUI
import TABCore

/// Where the user controls their data: a backup file, a restore from one, and a way to erase everything.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var backupFile: URL?
    @State private var showingImporter = false
    @State private var confirmingDelete = false
    @State private var confirmingDeleteForGood = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CardSection("Your data") {
                    Text("Your groups and expenses are stored only on this iPhone. TAB has no accounts and never uploads them. They are included in the backup that iOS makes of your iPhone to iCloud or to your computer, under your own Apple settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(16)
                        .accessibilityIdentifier("dataExplanation")
                }

                CardSection("Backup") {
                    if let backupFile {
                        ShareLink(item: backupFile) {
                            row("Export all groups", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("exportBackup")
                    } else {
                        row("Export all groups", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    Divider().padding(.leading, 56)
                    Button { showingImporter = true } label: {
                        row("Restore from a backup", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                }
                Text("A backup is a file with every group on this iPhone. Keep it wherever you like, or use it to move your groups to another iPhone. Restoring replaces what is on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)

                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.negative).padding(.horizontal, 4)
                }

                CardSection("Delete") {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        row("Delete all data", systemImage: "trash", tint: Theme.negative)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.negative)
                }
                Text("Removes every group, expense and your profile from this iPhone. Uninstalling TAB does the same.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)

                CardSection("About") {
                    Link(destination: Self.privacyURL) {
                        row("Privacy policy", systemImage: "hand.raised")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("privacyPolicy")
                    Divider().padding(.leading, 56)
                    Link(destination: Self.supportURL) {
                        row("Support", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("support")
                }
            }
            .padding(16)
        }
        .brandScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepareBackup() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.tabBackup, .json]) { result in
            switch result {
            case .success(let url): model.handleIncoming(url)
            case .failure: message = AppModel.message(for: SnapshotError.unreadable)
            }
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { confirmingDeleteForGood = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every group, expense and your profile will be removed from this iPhone. Export a backup first if you want to keep them.")
        }
        .alert("Delete everything for good?", isPresented: $confirmingDeleteForGood) {
            Button("Delete all data", role: .destructive, action: deleteEverything)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// Opened in Safari by the user; the app itself makes no network request (see docs/privacy.md).
    private static let privacyURL = URL(string: "https://cosmichomeless.github.io/TAB/privacy/")!
    private static let supportURL = URL(string: "https://cosmichomeless.github.io/TAB/support/")!

    private func row(_ title: LocalizedStringKey, systemImage: String, tint: Color = Theme.accent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).frame(width: 28).foregroundStyle(tint)
            Text(title)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func prepareBackup() async {
        do { backupFile = try await model.makeBackupFile() }
        catch { message = AppModel.message(for: error) }
    }

    private func deleteEverything() {
        Task {
            do { try await model.deleteAllData() }
            catch { message = AppModel.message(for: error) }
        }
    }
}

/// Shows what a backup contains and asks before it replaces everything on this iPhone.
struct RestoreBackupView: View {
    let backup: BackupFile
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var message: String?
    @State private var working = false

    private var expenseCount: Int { backup.groups.reduce(0) { $0 + $1.expenses.count } }
    private var exportedOn: String {
        Date(timeIntervalSince1970: TimeInterval(backup.exportedAt) / 1000).formatted(date: .abbreviated, time: .omitted)
    }

    /// "2 groups · 1 expense": each count agrees in number on its own, so the sentence works in every language.
    private var countsLine: String {
        let groups = String(localized: "\(backup.groups.count) groups")
        let expenses = String(localized: "\(expenseCount) expenses")
        return "\(groups) · \(expenses)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CardSection("Backup") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(backup.me.name).font(.title2.weight(.semibold))
                            Text(countsLine)
                                .foregroundStyle(.secondary)
                            Text("Made on \(exportedOn)").foregroundStyle(.secondary)
                            if !backup.groups.isEmpty {
                                Text(backup.groups.map(\.group.name).formatted(.list(type: .and)))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityElement(children: .combine)
                    }
                    Text("Restoring replaces every group, expense and the profile on this iPhone with the ones in this backup.")
                        .font(.footnote).foregroundStyle(Theme.warning).padding(.horizontal, 4)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.negative).padding(.horizontal, 4)
                    }
                    Button("Restore backup") { confirming = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working)
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingImport = nil } }
            }
            .confirmationDialog("Replace everything on this iPhone?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Replace with this backup", role: .destructive, action: restore)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("What is on this iPhone now will be deleted. This cannot be undone.")
            }
        }
        .tint(Theme.accent)
    }

    private func restore() {
        working = true
        Task {
            do {
                try await model.restore(backup)
                model.pendingImport = nil
            } catch {
                message = AppModel.message(for: error)
                working = false
            }
        }
    }
}
