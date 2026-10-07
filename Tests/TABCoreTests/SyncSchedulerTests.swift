import Foundation
import Testing
@testable import TABCore

/// Stands in for `Task.sleep`: records every requested delay and suspends until the test calls `fire()`
/// (or the scheduler cancels it), so the test decides exactly when a wake-up happens.
private actor FakeSleeper {
    private(set) var delays: [TimeInterval] = []
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation

    init() { (gate, opener) = AsyncStream.makeStream(of: Void.self) }

    func sleep(_ delay: TimeInterval) async throws {
        delays.append(delay)
        for await _ in gate { break }
        try Task.checkCancellation()
    }

    nonisolated func fire() { opener.yield() }

    /// The scheduler records its wake-up just after publishing the report, so tests wait for it.
    func delays(count: Int) async -> [TimeInterval] {
        while delays.count < count { try? await Task.sleep(for: .milliseconds(5)) }
        return delays
    }
}

private final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private struct Rig {
    let database: Database
    let groups: SQLiteGroupRepository
    let outbox: OutboxStore
    let backend: InMemoryBackend
    let scheduler: SyncScheduler
    let sleeper: FakeSleeper

    init() throws {
        let clock = FixedClock()
        database = try Database.inMemory()
        groups = SQLiteGroupRepository(database: database)
        outbox = OutboxStore(database: database)
        backend = InMemoryBackend(server: InMemoryServer(), account: UUID())
        sleeper = FakeSleeper()
        let sleeper = sleeper
        let engine = SyncEngine(database: database, backend: backend, now: { clock.now })
        scheduler = SyncScheduler(
            engine: engine, fallbackDelay: 30, now: { clock.now },
            sleep: { delay in
                clock.advance(delay) // the wake-up happens "later", so backoffs have expired by then
                try await sleeper.sleep(delay)
            }
        )
    }

    /// Waits until `count` cycles have finished and returns their reports.
    func reports(_ count: Int) async -> [SyncReport] {
        var reports: [SyncReport] = []
        for await event in scheduler.events {
            if case .finished(let report) = event {
                reports.append(report)
                if reports.count == count { break }
            }
        }
        return reports
    }
}

@Suite("Sync scheduler", .timeLimit(.minutes(1)))
struct SyncSchedulerTests {
    @Test func requestSyncPushesLocalWritesWithoutBlockingTheCaller() async throws {
        let rig = try Rig()
        let user = try await rig.groups.createUser(name: "David", email: nil)
        _ = try await rig.groups.createGroup(name: "Trip", currency: .eur, createdBy: user.id)

        rig.scheduler.requestSync()
        let report = try #require(await rig.reports(1).first)

        #expect(report.outcome == .completed)
        #expect(report.pushed == 3)
        #expect(try await rig.outbox.summary().isFullySynced)
        await rig.scheduler.stop()
    }

    @Test func offlineFallsBackToASlowPollAndRecoversWhenItFires() async throws {
        let rig = try Rig()
        await rig.backend.setOnline(false)
        _ = try await rig.groups.createUser(name: "David", email: nil)

        rig.scheduler.requestSync()
        let first = try #require(await rig.reports(1).first)
        #expect(first.outcome == .offline)
        #expect(await rig.sleeper.delays(count: 1).first == 30)

        // The slow poll fires and finds the connection back.
        await rig.backend.setOnline(true)
        rig.sleeper.fire()
        let second = try #require(await rig.reports(1).first)
        #expect(second.outcome == .completed)
        #expect(try await rig.outbox.summary().isFullySynced)
        await rig.scheduler.stop()
    }

    @Test func aBackoffWakesTheSchedulerWhenItExpires() async throws {
        let rig = try Rig()
        await rig.backend.inject(.fail(.server(sqlState: nil, status: 503, message: "unavailable")))
        _ = try await rig.groups.createUser(name: "David", email: nil)

        rig.scheduler.requestSync()
        let first = try #require(await rig.reports(1).first)
        #expect(first.retrying == 1)
        #expect(first.nextRetryAt != nil)
        #expect(await rig.sleeper.delays(count: 1).first == 2) // backoff after the first failed attempt

        rig.sleeper.fire()
        let second = try #require(await rig.reports(1).first)
        #expect(second.outcome == .completed)
        #expect(second.pushed == 1)
        #expect(try await rig.outbox.summary().isFullySynced)
        await rig.scheduler.stop()
    }

    @Test func missingSessionWaitsForTheUserInsteadOfPolling() async throws {
        let rig = try Rig()
        await rig.backend.setSignedIn(false)
        _ = try await rig.groups.createUser(name: "David", email: nil)

        rig.scheduler.requestSync()
        let first = try #require(await rig.reports(1).first)
        #expect(first.outcome == .unauthenticated)
        #expect(await rig.sleeper.delays.isEmpty)

        await rig.backend.setSignedIn(true)
        rig.scheduler.sessionChanged()
        let second = try #require(await rig.reports(1).first)
        #expect(second.outcome == .completed)
        await rig.scheduler.stop()
    }

    @Test func connectivityRestoredCancelsThePendingWakeAndSyncsNow() async throws {
        let rig = try Rig()
        await rig.backend.setOnline(false)
        _ = try await rig.groups.createUser(name: "David", email: nil)

        rig.scheduler.requestSync()
        #expect(try #require(await rig.reports(1).first).outcome == .offline)

        await rig.backend.setOnline(true)
        rig.scheduler.connectivityRestored()
        #expect(try #require(await rig.reports(1).first).outcome == .completed)
        await rig.scheduler.stop()
    }

    @Test func groupStatusIsTheMostSevereStatusOfItsOperations() async throws {
        let rig = try Rig()
        let user = try await rig.groups.createUser(name: "David", email: nil)
        let busy = try await rig.groups.createGroup(name: "Busy", currency: .eur, createdBy: user.id)
        let quiet = try await rig.groups.createGroup(name: "Quiet", currency: .eur, createdBy: user.id)

        var statuses = try await rig.outbox.groupStatuses(of: [busy.id, quiet.id])
        #expect(statuses[busy.id] == .pending)
        #expect(statuses[quiet.id] == .pending)

        rig.scheduler.requestSync()
        _ = await rig.reports(1)
        statuses = try await rig.outbox.groupStatuses(of: [busy.id, quiet.id])
        #expect(statuses[busy.id] == .synced)
        #expect(statuses[quiet.id] == .synced)

        _ = try await rig.groups.addParticipant(name: "Ana", email: nil, to: busy.id)
        await rig.backend.inject(.fail(.server(sqlState: "22023", status: 400, message: "invalid")))
        rig.scheduler.requestSync()
        _ = await rig.reports(1)
        statuses = try await rig.outbox.groupStatuses(of: [busy.id, quiet.id])
        #expect(statuses[busy.id] == .failed)
        #expect(statuses[quiet.id] == .synced)
        #expect(try await rig.outbox.groupStatuses(of: []).isEmpty)
        await rig.scheduler.stop()
    }

    @Test func phaseMirrorsTheReportOutcome() {
        #expect(SyncPhase(.completed) == .idle)
        #expect(SyncPhase(.offline) == .offline)
        #expect(SyncPhase(.unauthenticated) == .needsSignIn)
        #expect(SyncPhase(.accountMismatch) == .accountMismatch)
        #expect(SyncPhase(.failed("boom")) == .failed("boom"))
    }
}
