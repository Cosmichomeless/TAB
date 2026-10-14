import Foundation

/// Anything TAB can open: a shared group or a full backup. The file's own `format` marker decides which.
public enum TABFile: Equatable, Sendable {
    case group(GroupSnapshot)
    case backup(BackupFile)

    public static func decode(fileData data: Data) throws -> TABFile {
        guard data.count <= BackupFile.maximumFileSize else { throw SnapshotError.tooLarge }
        struct Marker: Decodable { let format: String }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data) else { throw SnapshotError.unreadable }
        switch marker.format {
        case GroupSnapshot.format: return .group(try GroupSnapshot.decode(fileData: data))
        case BackupFile.format: return .backup(try BackupFile.decode(fileData: data))
        default: throw SnapshotError.notATabFile
        }
    }
}
