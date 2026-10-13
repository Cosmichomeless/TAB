#if DEBUG
import Foundation
import TABCore
#if SYNC
import TABSync
#endif

/// A realistic dataset for screenshots and demos, behind the `-demoData` launch argument (debug builds only).
///
/// The sync build talks to an in-memory server instead of Supabase, so the sync badges, the status bar and a
/// lost-edit conflict are real results of the real engine rather than painted states. `-demoOffline`
/// additionally cuts the connection and records one more expense, which stays waiting on the device.
enum DemoData {
    #if SYNC
    static func install(in database: Database, offline: Bool, userKey: String) async throws -> any RemoteBackend {
        let server = InMemoryServer()
        let backend = InMemoryBackend(server: server)
        let engine = SyncEngine(database: database, backend: backend)
        let seeded = try await populate(database, userKey: userKey)

        // Everything above reaches the server.
        await engine.sync()

        // Bruno edits the taxi on another device while David edits it here: David's version loses.
        let expenses = SQLiteExpenseRepository(database: database)
        if let taxi = seeded.ids["Taxi to the airport"] {
            await server.editExpense(taxi, title: "Taxi to Humberto Delgado airport")
            _ = try await expenses.updateExpense(
                id: taxi, paidBy: seeded.bruno, title: "Taxi (night fare)", amountMinor: 3_100, splitEquallyAmong: seeded.everyone
            )
            await engine.sync()
        }

        if offline {
            await backend.setOnline(false)
            _ = try await expenses.createExpense(
                groupID: seeded.lisbon, paidBy: seeded.david, title: "Pastéis de nata", amountMinor: 1_250,
                splitEquallyAmong: seeded.everyone
            )
        }
        return backend
    }
    #else
    static func install(in database: Database, userKey: String) async throws {
        _ = try await populate(database, userKey: userKey)
    }
    #endif

    private struct Seeded {
        let ids: [String: UUID]
        let david: UUID, bruno: UUID
        let everyone: [UUID]
        let lisbon: UUID
    }

    private static func populate(_ database: Database, userKey: String) async throws -> Seeded {
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)

        let david = try await groups.createUser(name: "David", email: nil)
        UserDefaults.standard.set(david.id.uuidString, forKey: userKey)

        // Lisbon trip: four people, a handful of expenses.
        let lisbon = try await groups.createGroup(name: "Lisbon trip", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: lisbon.id)
        let marta = try await groups.addParticipant(name: "Marta", email: nil, to: lisbon.id)
        let bruno = try await groups.addParticipant(name: "Bruno", email: nil, to: lisbon.id)
        let everyone = [david.id, ana.id, marta.id, bruno.id]

        var ids: [String: UUID] = [:]
        func add(_ title: String, _ amount: Int64, paidBy: User, among: [UUID], daysAgo: Int, in group: ExpenseGroup) async throws {
            let expense = try await expenses.createExpense(
                groupID: group.id, paidBy: paidBy.id, title: title, amountMinor: amount, splitEquallyAmong: among
            )
            ids[title] = expense.id
            let when = Int64((Date().addingTimeInterval(-Double(daysAgo) * 86_400).timeIntervalSince1970 * 1000).rounded())
            try await database.execute(
                "UPDATE expenses SET created_at = ?, updated_at = ? WHERE id = ?", [.int(when), .int(when), .text(expense.id.uuidString)]
            )
        }
        try await add("Airbnb in Alfama", 64_000, paidBy: david, among: everyone, daysAgo: 6, in: lisbon)
        try await add("Dinner at Time Out Market", 18_640, paidBy: ana, among: everyone, daysAgo: 5, in: lisbon)
        try await add("Tram 28 tickets", 2_400, paidBy: marta, among: [marta.id, bruno.id, ana.id], daysAgo: 4, in: lisbon)
        try await add("Taxi to the airport", 2_280, paidBy: bruno, among: everyone, daysAgo: 1, in: lisbon)

        // A flat shared with Ana.
        let flat = try await groups.createGroup(name: "Flat", currency: .eur, createdBy: david.id)
        let flatAna = try await groups.addParticipant(name: "Ana", email: nil, to: flat.id)
        try await add("Electricity", 8_450, paidBy: david, among: [david.id, flatAna.id], daysAgo: 12, in: flat)
        try await add("Groceries", 5_120, paidBy: flatAna, among: [david.id, flatAna.id], daysAgo: 3, in: flat)

        // Tokyo, in a currency with no decimals.
        let tokyo = try await groups.createGroup(name: "Tokyo 2027", currency: .jpy, createdBy: david.id)
        let sato = try await groups.addParticipant(name: "Sato", email: nil, to: tokyo.id)
        try await add("Ramen night", 6_800, paidBy: sato, among: [david.id, sato.id], daysAgo: 2, in: tokyo)

        return Seeded(ids: ids, david: david.id, bruno: bruno.id, everyone: everyone, lisbon: lisbon.id)
    }
}
#endif
