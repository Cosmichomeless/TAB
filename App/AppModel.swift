import Foundation
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

    private static let currentUserKey = "currentUserID"

    func start() async {
        guard repository == nil else { return }
        do {
            let database = try Database(path: try Self.databaseURL().path)
            let repository = SQLiteGroupRepository(database: database)
            self.repository = repository
            self.expenseRepository = SQLiteExpenseRepository(database: database)

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
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func createProfile(name: String) async throws {
        guard let repository else { return }
        let user = try await repository.createUser(name: name, email: nil)
        UserDefaults.standard.set(user.id.uuidString, forKey: Self.currentUserKey)
        state = .ready(user)
    }

    func createGroup(name: String, currency: Currency) async throws {
        guard let repository, case .ready(let user) = state else { return }
        _ = try await repository.createGroup(name: name, currency: currency, createdBy: user.id)
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
