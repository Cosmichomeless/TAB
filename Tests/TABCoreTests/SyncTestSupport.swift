import Foundation
import Testing
@testable import TABCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct Device {
    let database: Database
    let groups: SQLiteGroupRepository
    let expenses: SQLiteExpenseRepository
    let outbox: OutboxStore
    let backend: InMemoryBackend
    let engine: SyncEngine
    let clock: TestClock
    let account: UUID
    var resolver: ConflictResolver { ConflictResolver(database: database) }

    init(server: InMemoryServer, account: UUID = UUID(), clock: TestClock = TestClock(), pageSize: Int = 500,
         conflictPolicy: ConflictPolicy = .remoteWins) throws {
        database = try Database.inMemory()
        groups = SQLiteGroupRepository(database: database)
        expenses = SQLiteExpenseRepository(database: database)
        outbox = OutboxStore(database: database)
        backend = InMemoryBackend(server: server, account: account)
        self.account = account
        self.clock = clock
        let clock = clock
        engine = SyncEngine(
            database: database, backend: backend, pageSize: pageSize, conflictPolicy: conflictPolicy, now: { clock.now }
        )
    }

    /// The same database after the app was closed and opened again: a new backend session and a new engine,
    /// nothing in memory survives.
    init(restarting other: Device, server: InMemoryServer, pageSize: Int = 500) {
        database = other.database
        groups = other.groups
        expenses = other.expenses
        outbox = other.outbox
        backend = InMemoryBackend(server: server, account: other.account)
        account = other.account
        clock = other.clock
        let clock = other.clock
        engine = SyncEngine(database: database, backend: backend, pageSize: pageSize, now: { clock.now })
    }

    struct Trip {
        let david: User, ana: User, group: Group
    }

    func makeTrip() async throws -> Trip {
        let david = try await groups.createUser(name: "David", email: nil)
        let group = try await groups.createGroup(name: "Trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)
        return Trip(david: david, ana: ana, group: group)
    }

    @discardableResult
    func addExpense(_ trip: Trip, title: String = "Dinner", amountMinor: Int64 = 3000) async throws -> Expense {
        try await expenses.createExpense(
            groupID: trip.group.id, paidBy: trip.david.id, title: title, amountMinor: amountMinor,
            shares: [
                SplitShare(userID: trip.david.id, amountMinor: amountMinor / 2),
                SplitShare(userID: trip.ana.id, amountMinor: amountMinor - amountMinor / 2),
            ]
        )
    }

    func version(of expense: UUID) async throws -> Int64 {
        try await database.query("SELECT version FROM expenses WHERE id = ?", [.text(expense.uuidString)]).first?.int("version") ?? -1
    }

    func title(of expense: UUID) async throws -> String? {
        try await database.query("SELECT title FROM expenses WHERE id = ?", [.text(expense.uuidString)]).first?.text("title")
    }

    func count(_ table: String) async throws -> Int64 {
        try await database.query("SELECT COUNT(*) AS n FROM \(table)").first?.int("n") ?? 0
    }
}

let serviceUnavailable = RemoteError.server(sqlState: nil, status: 503, message: "unavailable")

/// What a device (or the server) holds about expenses, in a form that can be compared for equality.
struct ExpenseState: Equatable, Comparable, CustomStringConvertible {
    let id: UUID
    let title: String
    let amountMinor: Int64
    let deleted: Bool
    let version: Int64
    let splits: [String]

    var description: String { "\(title) \(amountMinor) deleted=\(deleted) v\(version) \(splits)" }

    static func < (lhs: ExpenseState, rhs: ExpenseState) -> Bool { lhs.id.uuidString < rhs.id.uuidString }

    init(_ row: RemoteExpense) {
        id = row.id
        title = row.title
        amountMinor = row.amountMinor
        deleted = row.deletedAt != nil
        version = row.version
        splits = row.splits.map { "\($0.userID):\($0.amountMinor)" }.sorted()
    }

    init(row: Row, splits: [Row]) {
        id = row.uuid("id")
        title = row.text("title")
        amountMinor = row.int("amount_minor")
        deleted = row.optionalInt("deleted_at") != nil
        version = row.int("version")
        self.splits = splits.map { "\($0.uuid("user_id")):\($0.int("amount_minor"))" }.sorted()
    }
}

extension Device {
    func expenseStates() async throws -> [ExpenseState] {
        var states: [ExpenseState] = []
        for row in try await database.query("SELECT * FROM expenses") {
            let splits = try await database.query(
                "SELECT * FROM expense_splits WHERE expense_id = ?", [.text(row.uuid("id").uuidString)]
            )
            states.append(ExpenseState(row: row, splits: splits))
        }
        return states.sorted()
    }

    /// Every group's balances, which are derived from the ledger and so must agree wherever the ledger does.
    func balances(in groupID: UUID) async throws -> [Balance] {
        let members = try await groups.members(of: groupID).map(\.id).sorted { $0.uuidString < $1.uuidString }
        return BalanceCalculator.balances(for: try await expenses.ledger(in: groupID), members: members)
    }
}

extension InMemoryServer {
    func expenseStates() -> [ExpenseState] {
        expenseRows.map(ExpenseState.init).sorted()
    }
}

/// Lets time pass and syncs every device until nothing is left to send and nothing new arrives, which is what
/// "eventually" means in the tests. Fails the test if that takes unreasonably long.
func settle(_ devices: [Device], rounds: Int = 30, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    var quiet = 0
    for _ in 0..<rounds {
        var changed = false
        for device in devices {
            device.clock.advance(600)
            let report = await device.engine.sync()
            let summary = try await device.outbox.summary()
            if report.outcome != .completed || report.pushed > 0 || report.pulled > 0 || !summary.isFullySynced {
                changed = true
            }
        }
        quiet = changed ? 0 : quiet + 1
        if quiet == 2 { return }
    }
    Issue.record("The devices did not settle in \(rounds) rounds", sourceLocation: sourceLocation)
}
