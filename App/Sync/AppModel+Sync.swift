#if SYNC
import Foundation
import Network
import TABCore
import TABSync

extension AppModel {
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

    /// Sync status of each entity (all `synced` when nothing is queued). Empty when sync is not available,
    /// so a local-only build does not show every row as "waiting" forever.
    func syncStatuses(of ids: [UUID]) async -> [UUID: SyncStatus] {
        guard scheduler != nil, let outbox else { return [:] }
        return (try? await outbox.statuses(of: ids)) ?? [:]
    }

    func startSync(database: Database) {
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

    func handle(_ event: SyncScheduler.Event) async {
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

    func refreshSyncState() async {
        guard scheduler != nil, let outbox else { return }
        if let summary = try? await outbox.summary() { syncSummary = summary }
        groupStatuses = (try? await outbox.groupStatuses(of: groups.map(\.id))) ?? groupStatuses
    }
}
#endif
