import Foundation
import Network
import Observation
import TABCore

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
    /// `nil` when no Supabase URL/key was injected at build time: the app then runs purely offline.
    private let config: SupabaseConfig?
    private let auth: AuthClient?
    private(set) var session: AuthSession?

    // MARK: Synchronization (read-only for the UI; the scheduler owns when to sync)

    private(set) var syncPhase: SyncPhase = .localOnly
    private(set) var syncSummary = SyncSummary()
    private(set) var lastSyncedAt: Date?
    /// Worst sync status of each group, for the badges in the group list.
    private(set) var groupStatuses: [UUID: SyncStatus] = [:]
    /// Bumped whenever a sync cycle finishes, so screens can refresh their per-row badges.
    private(set) var syncRevision = 0

    /// What the group list shows for each group without opening it.
    private(set) var summaries: [UUID: GroupSummary] = [:]

    @ObservationIgnored private var database: Database?
    @ObservationIgnored private var outbox: OutboxStore?
    @ObservationIgnored private var scheduler: SyncScheduler?
    @ObservationIgnored private var demoBackend: (any RemoteBackend)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    var isBackendConfigured: Bool { auth != nil }
    var currentUser: User? {
        if case .ready(let user) = state { user } else { nil }
    }
    var syncOverview: SyncOverview { SyncOverview(phase: syncPhase, summary: syncSummary) }

    init() {
        let config = SupabaseConfig(bundle: .main)
        self.config = config
        self.auth = config.map { AuthClient(config: $0, store: KeychainSessionStore()) }
    }

    private static let currentUserKey = "currentUserID"

    func start() async {
        guard repository == nil else { return }
        session = try? await auth?.currentSession()
        #if DEBUG
        // UI tests start from a clean install: `-resetData` drops the local database and the current user.
        if CommandLine.arguments.contains("-resetData") { Self.resetLocalData() }
        #endif
        do {
            let database = try Database(path: try Self.databaseURL().path)
            self.database = database
            #if DEBUG
            // `-demoData` fills the app with a realistic trip against an in-memory server (see DemoData.swift).
            if CommandLine.arguments.contains("-demoData") {
                demoBackend = try await DemoData.install(
                    in: database, offline: CommandLine.arguments.contains("-demoOffline"),
                    userKey: Self.currentUserKey
                )
            }
            #endif
            let repository = SQLiteGroupRepository(database: database)
            self.repository = repository
            self.expenseRepository = SQLiteExpenseRepository(database: database)
            self.outbox = OutboxStore(database: database)
            startSync(database: database)

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
                await refreshSyncState()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signUp(email: String, password: String) async throws {
        guard let auth else { throw AuthError.notConfigured }
        session = try await auth.signUp(email: email, password: password)
        scheduler?.sessionChanged()
    }

    func signIn(email: String, password: String) async throws {
        guard let auth else { throw AuthError.notConfigured }
        session = try await auth.signIn(email: email, password: password)
        scheduler?.sessionChanged()
    }

    func signOut() async {
        await auth?.signOut()
        session = nil
        scheduler?.sessionChanged()
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

    // MARK: - Conflicts

    /// Changes of this group that lost to another device's edit (or still wait for a decision), newest first.
    func conflicts(in groupID: UUID) async -> [Conflict] {
        guard let database else { return [] }
        let all = (try? await ConflictResolver(database: database).conflicts()) ?? []
        return all.filter { ($0.local ?? $0.remote)?.groupID == groupID }
    }

    func restoreConflict(_ id: UUID) async throws {
        guard let database else { return }
        let resolver = ConflictResolver(database: database)
        let conflict = try await resolver.conflicts().first { $0.id == id }
        if conflict?.status == .open {
            try await resolver.keepLocal(id)
        } else {
            try await resolver.restoreLocal(id)
        }
        requestSync()
    }

    // MARK: - Synchronization

    /// Asks the scheduler to sync and returns immediately: local writes never wait for the network.
    func requestSync() {
        scheduler?.requestSync()
    }

    /// Sync status of each entity (all `synced` when nothing is queued). Empty when sync is not available,
    /// so a local-only build does not show every row as "waiting" forever.
    func syncStatuses(of ids: [UUID]) async -> [UUID: SyncStatus] {
        guard scheduler != nil, let outbox else { return [:] }
        return (try? await outbox.statuses(of: ids)) ?? [:]
    }

    private func startSync(database: Database) {
        let backend: any RemoteBackend
        if let demoBackend {
            backend = demoBackend
        } else if let config, let auth {
            backend = SupabaseBackend(config: config, auth: auth)
        } else {
            return
        }
        let engine = SyncEngine(database: database, backend: backend)
        let scheduler = SyncScheduler(engine: engine)
        self.scheduler = scheduler
        syncPhase = .idle

        eventsTask = Task { [weak self] in
            for await event in scheduler.events {
                await self?.handle(event)
            }
        }

        // The system tells us when a connection appears; the scheduler also polls slowly as a fallback.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { scheduler.connectivityRestored() }
        }
        monitor.start(queue: DispatchQueue(label: "tab.network-monitor"))
        pathMonitor = monitor

        scheduler.requestSync()
    }

    private func handle(_ event: SyncScheduler.Event) async {
        switch event {
        case .started:
            syncPhase = .syncing
        case .finished(let report):
            syncPhase = SyncPhase(report.outcome)
            if report.outcome == .completed { lastSyncedAt = Date() }
            await refreshSyncState()
            syncRevision += 1
        }
    }

    private func refreshSyncState() async {
        guard scheduler != nil, let outbox else { return }
        if let summary = try? await outbox.summary() { syncSummary = summary }
        groupStatuses = (try? await outbox.groupStatuses(of: groups.map(\.id))) ?? groupStatuses
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
