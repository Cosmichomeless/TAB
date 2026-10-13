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

    func addParticipant(name: String, email: String?, to groupID: UUID) async throws {
        guard let repository else { return }
        _ = try await repository.addParticipant(name: name, email: email, to: groupID)
        requestSync()
    }

    func addExpense(
        groupID: UUID, paidBy: UUID, title: String, amountMinor: Int64, splitEquallyAmong participants: [UUID]
    ) async throws {
        guard let expenseRepository else { return }
        _ = try await expenseRepository.createExpense(
            groupID: groupID, paidBy: paidBy, title: title, amountMinor: amountMinor,
            splitEquallyAmong: participants
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
