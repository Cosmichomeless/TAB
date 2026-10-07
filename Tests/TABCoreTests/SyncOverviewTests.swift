import Testing
@testable import TABCore

@Suite("Sync overview")
struct SyncOverviewTests {
    private func summary(pending: Int = 0, failed: Int = 0, conflicts: Int = 0) -> SyncSummary {
        var summary = SyncSummary()
        summary.pending = pending
        summary.failed = failed
        summary.conflicts = conflicts
        return summary
    }

    @Test func fullySyncedWhenIdleAndNothingIsWaiting() {
        #expect(SyncOverview(phase: .idle, summary: summary()).headline == .synced)
    }

    @Test func pendingChangesAreWaitingNotFailed() {
        #expect(SyncOverview(phase: .idle, summary: summary(pending: 3)).headline == .waiting(3))
    }

    @Test func conflictsOutrankFailuresAndFailuresOutrankPending() {
        #expect(SyncOverview(phase: .idle, summary: summary(pending: 1, failed: 2, conflicts: 1)).headline == .conflicts(1))
        #expect(SyncOverview(phase: .idle, summary: summary(pending: 1, failed: 2)).headline == .failed(2))
    }

    @Test func offlineKeepsTheCountOfChangesSavedOnTheDevice() {
        #expect(SyncOverview(phase: .offline, summary: summary(pending: 2, failed: 1)).headline == .offline(waiting: 3))
        #expect(SyncOverview(phase: .offline, summary: summary()).headline == .offline(waiting: 0))
    }

    @Test func signInAndAccountProblemsAreNeverHiddenByCounters() {
        #expect(SyncOverview(phase: .needsSignIn, summary: summary(pending: 4)).headline == .needsSignIn(waiting: 4))
        #expect(SyncOverview(phase: .accountMismatch, summary: summary(conflicts: 1)).headline == .accountMismatch)
    }

    @Test func unexpectedErrorShowsUnlessMoreSpecificStatusExists() {
        #expect(SyncOverview(phase: .failed("boom"), summary: summary()).headline == .error("boom"))
        #expect(SyncOverview(phase: .failed("boom"), summary: summary(failed: 1)).headline == .failed(1))
    }

    @Test func syncingAndLocalOnlyOverrideEverythingElse() {
        #expect(SyncOverview(phase: .syncing, summary: summary(failed: 5)).headline == .syncing)
        #expect(SyncOverview(phase: .localOnly, summary: summary(pending: 5)).headline == .localOnly)
    }
}
