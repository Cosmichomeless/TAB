import Foundation

/// Why a shared file or link could not be used. The app turns each case into a clear message.
public enum SnapshotError: Error, Equatable, Sendable {
    /// Not a TAB file at all (wrong or missing format marker).
    case notATabFile
    /// Written by a newer version of TAB than this one understands.
    case newerVersion(Int)
    /// Not valid JSON, or fields are missing or have the wrong type.
    case unreadable
    /// More data than a real group can have.
    case tooLarge
    case emptyGroupName
    case noParticipants
    case invalidParticipant
    case duplicateParticipant(UUID)
    case unknownParticipant(UUID)
    case duplicateExpense(UUID)
    case invalidAmount(expense: UUID)
    case splitsDoNotAddUp(expense: UUID)
    case balancesDoNotMatch
    /// The group already exists here with another currency, so its expenses cannot be replaced.
    case currencyMismatch
}

/// A group, its participants and its expenses at one moment, in a form that travels as a file, a QR code or a
/// link. Balances are derived data: they are included for readers of the file and checked on import.
public struct GroupSnapshot: Codable, Equatable, Sendable {
    public static let format = "tab.group"
    public static let currentSchemaVersion = 1

    public struct GroupInfo: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var currency: Currency
        public var createdBy: UUID
        /// Milliseconds since the Unix epoch.
        public var createdAt: Int64

        public init(id: UUID, name: String, currency: Currency, createdBy: UUID, createdAt: Int64) {
            self.id = id
            self.name = name
            self.currency = currency
            self.createdBy = createdBy
            self.createdAt = createdAt
        }
    }

    public struct Participant: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var email: String?
        public var createdAt: Int64

        public init(id: UUID, name: String, email: String? = nil, createdAt: Int64) {
            self.id = id
            self.name = name
            self.email = email
            self.createdAt = createdAt
        }
    }

    public struct SplitEntry: Codable, Equatable, Sendable {
        public var userID: UUID
        public var amountMinor: Int64

        public init(userID: UUID, amountMinor: Int64) {
            self.userID = userID
            self.amountMinor = amountMinor
        }
    }

    public struct ExpenseEntry: Codable, Equatable, Sendable {
        public var id: UUID
        public var paidBy: UUID
        public var title: String
        public var amountMinor: Int64
        public var createdAt: Int64
        public var updatedAt: Int64
        public var splits: [SplitEntry]

        public init(
            id: UUID, paidBy: UUID, title: String, amountMinor: Int64, createdAt: Int64, updatedAt: Int64,
            splits: [SplitEntry]
        ) {
            self.id = id
            self.paidBy = paidBy
            self.title = title
            self.amountMinor = amountMinor
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.splits = splits
        }
    }

    public struct BalanceEntry: Codable, Equatable, Sendable {
        public var userID: UUID
        public var netMinor: Int64

        public init(userID: UUID, netMinor: Int64) {
            self.userID = userID
            self.netMinor = netMinor
        }
    }

    public var format: String
    public var schemaVersion: Int
    /// Milliseconds since the Unix epoch.
    public var exportedAt: Int64
    public var group: GroupInfo
    public var participants: [Participant]
    public var expenses: [ExpenseEntry]
    /// What each participant is owed (positive) or owes (negative). Omitted from links to keep QR codes small.
    public var balances: [BalanceEntry]?

    public init(
        exportedAt: Int64, group: GroupInfo, participants: [Participant], expenses: [ExpenseEntry],
        balances: [BalanceEntry]? = nil
    ) {
        self.format = Self.format
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.group = group
        self.participants = participants
        self.expenses = expenses
        self.balances = balances
    }

    /// The net balance of every participant, computed from the expenses alone.
    public func computedBalances() -> [BalanceEntry] {
        var net = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, Int64(0)) })
        for expense in expenses {
            net[expense.paidBy, default: 0] += expense.amountMinor
            for split in expense.splits { net[split.userID, default: 0] -= split.amountMinor }
        }
        return participants.map { BalanceEntry(userID: $0.id, netMinor: net[$0.id] ?? 0) }
    }

    /// Checks everything a file from outside can get wrong: format, version, references, amounts and balances.
    public func validate() throws {
        guard format == Self.format else { throw SnapshotError.notATabFile }
        guard schemaVersion >= 1 else { throw SnapshotError.unreadable }
        guard schemaVersion <= Self.currentSchemaVersion else { throw SnapshotError.newerVersion(schemaVersion) }
        guard participants.count <= Limits.participants, expenses.count <= Limits.expenses else {
            throw SnapshotError.tooLarge
        }
        guard Self.isValidName(group.name) else { throw SnapshotError.emptyGroupName }
        guard !participants.isEmpty else { throw SnapshotError.noParticipants }

        var known = Set<UUID>()
        for participant in participants {
            guard Self.isValidName(participant.name) else { throw SnapshotError.invalidParticipant }
            if let email = participant.email, !email.isEmpty, !email.contains("@") || email.count > Limits.text {
                throw SnapshotError.invalidParticipant
            }
            guard known.insert(participant.id).inserted else { throw SnapshotError.duplicateParticipant(participant.id) }
        }
        guard known.contains(group.createdBy) else { throw SnapshotError.unknownParticipant(group.createdBy) }

        var seenExpenses = Set<UUID>()
        for expense in expenses {
            guard seenExpenses.insert(expense.id).inserted else { throw SnapshotError.duplicateExpense(expense.id) }
            guard known.contains(expense.paidBy) else { throw SnapshotError.unknownParticipant(expense.paidBy) }
            guard expense.amountMinor > 0, Self.isValidName(expense.title), !expense.splits.isEmpty else {
                throw SnapshotError.invalidAmount(expense: expense.id)
            }
            var seenSplits = Set<UUID>()
            var total: Int64 = 0
            for split in expense.splits {
                guard known.contains(split.userID) else { throw SnapshotError.unknownParticipant(split.userID) }
                guard seenSplits.insert(split.userID).inserted else {
                    throw SnapshotError.duplicateParticipant(split.userID)
                }
                guard split.amountMinor >= 0 else { throw SnapshotError.invalidAmount(expense: expense.id) }
                let (sum, overflow) = total.addingReportingOverflow(split.amountMinor)
                guard !overflow else { throw SnapshotError.invalidAmount(expense: expense.id) }
                total = sum
            }
            guard total == expense.amountMinor else { throw SnapshotError.splitsDoNotAddUp(expense: expense.id) }
        }

        if let balances {
            let given = Dictionary(balances.map { ($0.userID, $0.netMinor) }, uniquingKeysWith: { _, last in last })
            let expected = Dictionary(uniqueKeysWithValues: computedBalances().map { ($0.userID, $0.netMinor) })
            guard balances.count == expected.count, given == expected else { throw SnapshotError.balancesDoNotMatch }
        }
    }

    enum Limits {
        static let participants = 500
        static let expenses = 20_000
        static let text = 1_000
    }

    private static func isValidName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= Limits.text
    }
}

// MARK: - Files and links

extension GroupSnapshot {
    /// Largest file or link payload that is read, so a hostile file cannot exhaust memory.
    public static let maximumFileSize = 8 * 1024 * 1024

    /// The `.tabgroup` file: readable, sorted JSON.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads and validates a `.tabgroup` file.
    public static func decode(fileData data: Data) throws -> GroupSnapshot {
        guard data.count <= maximumFileSize else { throw SnapshotError.tooLarge }
        let snapshot: GroupSnapshot
        do {
            // Look at the format and version first, so a newer file is reported as such even if its fields changed.
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.format == format else { throw SnapshotError.notATabFile }
            guard header.schemaVersion <= currentSchemaVersion else { throw SnapshotError.newerVersion(header.schemaVersion) }
            snapshot = try JSONDecoder().decode(GroupSnapshot.self, from: data)
        } catch let error as SnapshotError {
            throw error
        } catch {
            throw SnapshotError.unreadable
        }
        try snapshot.validate()
        return snapshot
    }

    private struct Header: Decodable {
        let format: String
        let schemaVersion: Int
    }
}
