import SwiftUI
import TABCore
import UniformTypeIdentifiers

extension UTType {
    static let tabGroup = UTType(exportedAs: "com.cosmichomeless.tab.group", conformingTo: .json)
    static let tabBackup = UTType(exportedAs: "com.cosmichomeless.tab.backup", conformingTo: .json)
}

/// Shows a group as a QR code and as a file or link to send. It is a copy of the group as it is now.
struct ShareGroupView: View {
    let group: ExpenseGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shared: Shared?
    @State private var failure: String?
    @State private var copied = false

    struct Shared {
        let link: URL
        let file: URL
        let qr: UIImage?
        let summary: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let shared {
                        CardSection("QR code") {
                            qrCode(shared.qr).padding(16)
                        }
                        CardSection("Who owes whom") {
                            ShareLink(item: shared.summary, subject: Text(group.name)) {
                                row("Share summary as text", systemImage: "text.bubble")
                            }
                            .accessibilityIdentifier("shareSummary")
                            Text(shared.summary)
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 14)
                                .accessibilityIdentifier("summaryText")
                        }
                        CardSection("Send") {
                            ShareLink(item: shared.file, subject: Text(group.name)) {
                                row("Share as file", systemImage: "doc")
                            }
                            Divider().padding(.leading, 52)
                            ShareLink(item: shared.link, subject: Text(group.name)) {
                                row("Share link", systemImage: "link")
                            }
                            Divider().padding(.leading, 52)
                            Button {
                                UIPasteboard.general.string = shared.link.absoluteString
                                copied = true
                            } label: {
                                row(copied ? "Link copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            // UI tests cannot read the pasteboard of another process without a system prompt.
                            .accessibilityValue(CommandLine.arguments.contains("-exposeShareLink") ? shared.link.absoluteString : "")
                        }
                        Text("This is a copy of the group as it is now. Changes made later are not shared automatically. Nothing is uploaded: the file, the link and the QR code contain the group itself.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    } else if let failure {
                        Text(failure).foregroundStyle(Theme.negative)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .brandScreen()
            .navigationTitle("Share group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func qrCode(_ image: UIImage?) -> some View {
        if let image {
            VStack(spacing: 10) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text("QR code for the group \(group.name)"))
                Text("Open the iPhone camera and point it at this code to import the group in TAB.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("This group is too big for a QR code. Share it as a file or a link instead.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).frame(width: 28).foregroundStyle(Theme.accent)
            Text(title).foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func load() async {
        guard let archive = model.archive else { return }
        do {
            let snapshot = try await archive.snapshot(of: group.id)
            let link = try snapshot.link()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(Self.fileName(for: group.name)).appendingPathExtension("tabgroup")
            try snapshot.fileData().write(to: file, options: .atomic)
            shared = Shared(
                link: link, file: file, qr: QRCode.image(for: link.absoluteString),
                summary: SettlementText.text(for: snapshot, phrases: .localized)
            )
        } catch {
            failure = error.localizedDescription
        }
    }

    static func fileName(for groupName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = groupName.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "TAB group" : String(cleaned.prefix(60))
    }
}

extension SettlementText.Phrases {
    /// The summary in the language of the app.
    static var localized: Self {
        Self(
            title: { String(localized: "\($0) – who owes whom") },
            payment: { String(localized: "\($0) owes \($1) \($2)") },
            settled: String(localized: "Everyone is settled up.")
        )
    }
}
