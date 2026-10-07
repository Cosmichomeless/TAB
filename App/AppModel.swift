import Foundation
import Network
import Observation
import TABCore

/// `Group` is also a SwiftUI type, so the domain entity gets an unambiguous alias in the app.
typealias ExpenseGroup = TABCore.Group

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

    @ObservationIgnored private var outbox: OutboxStore?
    @ObservationIgnored private var scheduler: SyncScheduler?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    var isBackendConfigured: Bool { auth != nil }
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
        do {
            let database = try Database(path: try Self.databaseURL().path)
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
        guard let config, let auth else { return }
        let engine = SyncEngine(database: database, backend: SupabaseBackend(config: config, auth: auth))
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
    }

    private static func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent("tab.sqlite")
    }
}
