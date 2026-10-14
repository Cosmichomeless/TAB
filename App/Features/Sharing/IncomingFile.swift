import Foundation
import TABCore

/// Something opened from outside the app (a file, a link or a QR code) that is waiting for confirmation.
struct PendingImport: Identifiable {
    let id = UUID()
    let file: TABFile
}

extension AppModel {
    /// Handles `tab://` links and `.tabgroup` / `.tabbackup` files. Nothing is changed until the user confirms.
    func handleIncoming(_ url: URL) {
        do {
            if url.isFileURL {
                pendingImport = PendingImport(file: try Self.readFile(at: url))
            } else {
                pendingImport = PendingImport(file: .group(try GroupSnapshot.decode(link: url)))
            }
        } catch {
            incomingError = Self.message(for: error)
        }
    }

    private static func readFile(at url: URL) throws -> TABFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= BackupFile.maximumFileSize else { throw SnapshotError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.unreadable }
        return try TABFile.decode(fileData: data)
    }

    static func message(for error: Error) -> String {
        switch error as? SnapshotError {
        case .notATabFile:
            String(localized: "This is not a TAB file.")
        case .newerVersion:
            String(localized: "This file was made by a newer version of TAB. Update the app and try again.")
        case .unreadable:
            String(localized: "The file is damaged or incomplete, so it could not be read.")
        case .tooLarge:
            String(localized: "This file is too large to be a TAB group.")
        case .currencyMismatch:
            String(localized: "This group already exists on this iPhone with another currency. Import it as a copy instead.")
        case .some:
            String(localized: "The contents of the file do not add up, so nothing was imported.")
        case nil:
            error.localizedDescription
        }
    }
}
