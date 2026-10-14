import Foundation
import Observation
import TABCore
#if SYNC
import Network
import TABSync
#endif

/// `Group` is also a SwiftUI type, so the domain entity gets an unambiguous alias in the app.
typealias ExpenseGroup = TABCore.Group

struct GroupSummary: Equatable {
    var memberCount = 0
    var expenseCount = 0
    var totalMinor: Int64 = 0
    /// Positive: the others owe you. Negative: you owe them.
    var myBalanceMinor: Int64 = 0
}

@MainActor
@Observable
final class AppModel {
    enum State {
        case loading
        case needsProfile
        case ready(User)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var groups: [ExpenseGroup] = []
    private(set) var repository: SQLiteGroupRepository?
    private(set) var expenseRepository: SQLiteExpenseRepository?
    #if SYNC
    // The sync build adds an account, an outbox and a scheduler on top of the local database (see App/Sync).
    /// `nil` when no Supabase URL/key was injected at build time: the app then runs purely offline.
    let config: SupabaseConfig?
    let auth: AuthClient?
    var session: AuthSession?

    var syncPhase: SyncPhase = .localOnly
    var syncSummary = SyncSummary()
    var lastSyncedAt: Date?
    /// Worst sync status of each group, for the badges in the group list.
    var groupStatuses: [UUID: SyncStatus] = [:]
    /// Bumped whenever a sync cycle finishes, so screens can refresh their per-row badges.
    var syncRevision = 0
    #endif

    /// A shared group or backup that was opened and is waiting for the user to confirm the import.
    var pendingImport: PendingImport?
    /// Why the last file or link could not be opened, shown once.
    var incomingError: String?

    /// What the group list shows for each group without opening it.
    private(set) var summaries: [UUID: GroupSummary] = [:]

    @ObservationIgnored private(set) var database: Database?
    #if SYNC
    @ObservationIgnored var outbox: OutboxStore?
    @ObservationIgnored var scheduler: SyncScheduler?
    @ObservationIgnored var demoBackend: (any RemoteBackend)?
    @ObservationIgnored var eventsTask: Task<Void, Never>?
    @ObservationIgnored var pathMonitor: NWPathMonitor?

    var isBackendConfigured: Bool { auth != nil }
    var syncOverview: SyncOverview { SyncOverview(phase: syncPhase, summary: syncSummary) }
    #endif
    var archive: GroupArchive? { database.map { GroupArchive(database: $0) } }
    var currentUser: User? {
        if case .ready(let user) = state { user } else { nil }
    }

    init() {
        #if SYNC
        let config = SupabaseConfig(bundle: .main)
        self.config = config
        self.auth = config.map { AuthClient(config: $0, store: KeychainSessionStore()) }
        #endif
    }

    static let currentUserKey = "currentUserID"

    func start() async {
        guard repository == nil else { return }
        #if SYNC
        session = try? await auth?.currentSession()
        #endif
        #if DEBUG
        // UI tests start from a clean install: `-resetData` drops the local database and the current user.
        if CommandLine.arguments.contains("-resetData") { Self.resetLocalData() }
        #endif
        do {
            let database = try Database(path: try Self.databaseURL().path)
            self.database = database
            #if DEBUG
            // `-demoData` fills the app with a realistic trip (see DemoData.swift).
            if CommandLine.arguments.contains("-demoData") {
                #if SYNC
                demoBackend = try await DemoData.install(
                    in: database, offline: CommandLine.arguments.contains("-demoOffline"),
                    userKey: Self.currentUserKey
                )
                #else
                try await DemoData.install(in: database, userKey: Self.currentUserKey)
                #endif
            }
            #endif
            let repository = SQLiteGroupRepository(database: database)
            self.repository = repository
            self.expenseRepository = SQLiteExpenseRepository(database: database)
            #if SYNC
            self.outbox = OutboxStore(database: database)
            startSync(database: database)
            #endif

            if let raw = UserDefaults.standard.string(forKey: Self.currentUserKey),
               let id = UUID(uuidString: raw),
               let user = try await repository.user(id: id) {
                state = .ready(user)
            } else {
                state = .needsProfile
            }
            try await reloadGroups()
            #if DEBUG
            // UI tests open a link as if it came from the camera or Messages: `-incomingURL tab://group?d=...`.
            if let index = CommandLine.arguments.firstIndex(of: "-incomingURL"),
               CommandLine.arguments.indices.contains(index + 1),
               let url = URL(string: CommandLine.arguments[index + 1]) {
                handleIncoming(url)
            }
            #endif

            for await _ in repository.changes() {
                try? await reloadGroups()
                #if SYNC
                await refreshSyncState()
                #endif
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Asks the scheduler to sync and returns immediately: local writes never wait for the network.
    /// Nothing to do in the local build, where the data never leaves the device.
    func requestSync() {
        #if SYNC
        scheduler?.requestSync()
        #endif
    }

    func createProfile(name: String) async throws {
        guard let repository else { return }
        let user = try await repository.createUser(name: name, email: nil)
        UserDefaults.standard.set(user.id.uuidString, forKey: Self.currentUserKey)
        state = .ready(user)
        requestSync()
    }

    func createGroup(name: String, currency: Currency) async throws {
        guard let repository, case .ready(let user) = state else { return }
        _ = try await repository.createGroup(name: name, currency: currency, createdBy: user.id)
        requestSync()
    }

    func importGroup(_ snapshot: GroupSnapshot, mode: GroupArchive.ImportMode, asParticipant: UUID?) async throws {
        guard let archive, case .ready(let user) = state else { return }
        try await archive.importGroup(snapshot, mode: mode, me: user.id, asParticipant: asParticipant)
    }

    /// Writes every group to a `.tabbackup` file in a temporary folder and returns it, ready to share.
    func makeBackupFile() async throws -> URL {
        guard let archive, case .ready(let user) = state else { throw SnapshotError.unreadable }
        let backup = try await archive.backup(me: user.id)
        let directory = Self.temporaryDirectory("backup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let file = directory.appendingPathComponent("TAB backup \(day)").appendingPathExtension("tabbackup")
        try backup.fileData().write(to: file, options: .atomic)
        return file
    }

    /// Replaces everything on this iPhone with the backup and continues as the profile it was made with.
    func restore(_ backup: BackupFile) async throws {
        guard let archive, let repository else { return }
        let id = try await archive.restore(backup)
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentUserKey)
        guard let user = try await repository.user(id: id) else { throw SnapshotError.unreadable }
        state = .ready(user)
        try await reloadGroups()
    }

    /// Removes the database, the profile and every temporary file TAB wrote, and goes back to the first launch.
    func deleteAllData() async throws {
        guard let archive else { return }
        try await archive.deleteAllData()
        UserDefaults.standard.removeObject(forKey: Self.currentUserKey)
        for name in ["backup", "share"] {
            try? FileManager.default.removeItem(at: Self.temporaryDirectory(name))
        }
        pendingImport = nil
        groups = []
        summaries = [:]
        state = .needsProfile
    }

    static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func addParticipant(name: String, email: String?, to groupID: UUID) async throws {
        guard let repository else { return }
        _ = try await repository.addParticipant(name: name, email: email, to: groupID)
        requestSync()
    }

    func addExpense(
        groupID: UUID, paidBy: UUID, title: String, amountMinor: Int64, method: SplitMethod
    ) async throws {
        guard let expenseRepository else { return }
        _ = try await expenseRepository.createExpense(
            groupID: groupID, paidBy: paidBy, title: title, amountMinor: amountMinor, method: method
        )
        requestSync()
    }

    func updateExpense(
        id: UUID, paidBy: UUID, title: String, amountMinor: Int64,
        originalAmountMinor: Int64, originalSplits: [ExpenseSplit], participants: [UUID]
    ) async throws {
        guard let expenseRepository else { return }
        _ = try await expenseRepository.updateExpense(
            id: id, paidBy: paidBy, title: title, amountMinor: amountMinor,
            originalAmountMinor: originalAmountMinor, originalSplits: originalSplits, participants: participants
        )
        requestSync()
    }

    /// Replaces the split with the one `method` gives. Use the overload above to keep an existing split
    /// when neither the amount nor the participants changed.
    func updateExpense(id: UUID, paidBy: UUID, title: String, amountMinor: Int64, method: SplitMethod) async throws {
        guard let expenseRepository else { return }
        _ = try await expenseRepository.updateExpense(
            id: id, paidBy: paidBy, title: title, amountMinor: amountMinor, method: method
        )
        requestSync()
    }

    func deleteExpense(id: UUID) async throws {
        guard let expenseRepository else { return }
        try await expenseRepository.deleteExpense(id: id)
        requestSync()
    }

    private func reloadGroups() async throws {
        guard let repository else { return }
        groups = try await repository.groups()
        await refreshSummaries()
    }

    private func refreshSummaries() async {
        guard let repository, let expenseRepository, let me = currentUser else { return }
        var result: [UUID: GroupSummary] = [:]
        for group in groups {
            guard let members = try? await repository.members(of: group.id),
                  let ledger = try? await expenseRepository.ledger(in: group.id) else { continue }
            let balances = BalanceCalculator.balances(for: ledger, members: members.map(\.id))
            result[group.id] = GroupSummary(
                memberCount: members.count,
                expenseCount: ledger.count,
                totalMinor: ledger.reduce(0) { $0 + $1.expense.amountMinor },
                myBalanceMinor: balances.first { $0.userID == me.id }?.netMinor ?? 0
            )
        }
        summaries = result
    }

    #if DEBUG
    private static func resetLocalData() {
        UserDefaults.standard.removeObject(forKey: currentUserKey)
        guard let url = try? databaseURL() else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
    #endif

    private static func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent("tab.sqlite")
    }
}
