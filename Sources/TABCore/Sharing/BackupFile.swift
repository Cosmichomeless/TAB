import Foundation

/// Everything on this iPhone in one file: the profile and every group with its participants and expenses.
/// It is a plain `.tabbackup` JSON file the user keeps wherever they like; TAB never uploads it.
public struct BackupFile: Codable, Equatable, Sendable {
    public static let format = "tab.backup"
    public static let currentSchemaVersion = 1
    /// Backups hold every group, so the limit is higher than for a single shared group.
    public static let maximumFileSize = 64 * 1024 * 1024
    static let maximumGroups = 2_000

    public var format: String
    public var schemaVersion: Int
    /// Milliseconds since the Unix epoch.
    public var exportedAt: Int64
    /// The person using this iPhone.
    public var me: GroupSnapshot.Participant
    public var groups: [GroupSnapshot]

    public init(exportedAt: Int64, me: GroupSnapshot.Participant, groups: [GroupSnapshot]) {
        self.format = Self.format
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.me = me
        self.groups = groups
    }

    public func validate() throws {
        guard format == Self.format else { throw SnapshotError.notATabFile }
        guard schemaVersion >= 1 else { throw SnapshotError.unreadable }
        guard schemaVersion <= Self.currentSchemaVersion else { throw SnapshotError.newerVersion(schemaVersion) }
        guard groups.count <= Self.maximumGroups else { throw SnapshotError.tooLarge }
        let name = me.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= GroupSnapshot.Limits.text else { throw SnapshotError.invalidParticipant }
        var seen = Set<UUID>()
        for group in groups {
            try group.validate()
            guard seen.insert(group.group.id).inserted else { throw SnapshotError.unreadable }
        }
    }

    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(fileData data: Data) throws -> BackupFile {
        guard data.count <= maximumFileSize else { throw SnapshotError.tooLarge }
        let backup: BackupFile
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.format == format else { throw SnapshotError.notATabFile }
            guard header.schemaVersion <= currentSchemaVersion else { throw SnapshotError.newerVersion(header.schemaVersion) }
            backup = try JSONDecoder().decode(BackupFile.self, from: data)
        } catch let error as SnapshotError {
            throw error
        } catch {
            throw SnapshotError.unreadable
        }
        try backup.validate()
        return backup
    }

    private struct Header: Decodable {
        let format: String
        let schemaVersion: Int
    }
}
