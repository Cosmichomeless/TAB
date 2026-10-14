import Foundation
import Testing
@testable import TABCore

@Suite("Sharing groups as files and links")
struct SharingTests {
    struct Fixture {
        let database: Database
        let groups: SQLiteGroupRepository
        let expenses: SQLiteExpenseRepository
        let archive: GroupArchive
        let group: Group
        let david: User
        let ana: User
        let leo: User
    }

    private func makeFixture(people: Int = 3, expenseCount: Int = 2) async throws -> Fixture {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let expenses = SQLiteExpenseRepository(database: database)
        let david = try await groups.createUser(name: "David", email: "david@example.com")
        let group = try await groups.createGroup(name: "Lisboa 🇵🇹", currency: .eur, createdBy: david.id)
        let ana = try await groups.addParticipant(name: "Ana", email: nil, to: group.id)
        let leo = try await groups.addParticipant(name: "Léo", email: nil, to: group.id)
        _ = try await expenses.createExpense(
            groupID: group.id, paidBy: david.id, title: "Cena", amountMinor: 9000,
            shares: [david, ana, leo].map { SplitShare(userID: $0.id, amountMinor: 3000) }
        )
        _ = try await expenses.createExpense(
            groupID: group.id, paidBy: ana.id, title: "Taxi", amountMinor: 1001,
            shares: [SplitShare(userID: david.id, amountMinor: 501), SplitShare(userID: ana.id, amountMinor: 500)]
        )
        return Fixture(
            database: database, groups: groups, expenses: expenses, archive: GroupArchive(database: database),
            group: group, david: david, ana: ana, leo: leo
        )
    }

    private func freshDatabase(profile name: String = "Marta") async throws -> (GroupArchive, SQLiteGroupRepository, User, SQLiteExpenseRepository) {
        let database = try Database.inMemory()
        let groups = SQLiteGroupRepository(database: database)
        let me = try await groups.createUser(name: name, email: nil)
        return (GroupArchive(database: database), groups, me, SQLiteExpenseRepository(database: database))
    }

    private func balances(_ groupID: UUID, groups: SQLiteGroupRepository, expenses: SQLiteExpenseRepository) async throws -> [UUID: Int64] {
        let ledger = try await expenses.ledger(in: groupID)
        let members = try await groups.members(of: groupID).map(\.id)
        return Dictionary(uniqueKeysWithValues: BalanceCalculator.balances(for: ledger, members: members).map { ($0.userID, $0.netMinor) })
    }

    // MARK: - Snapshot

    @Test func snapshotCapturesGroupPeopleExpensesAndBalances() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)

        #expect(snapshot.format == "tab.group")
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.group.name == "Lisboa 🇵🇹")
        #expect(snapshot.group.currency == .eur)
        #expect(snapshot.participants.map(\.name) == ["David", "Ana", "Léo"])
        #expect(snapshot.expenses.map(\.title) == ["Cena", "Taxi"])
        #expect(snapshot.expenses[1].splits.map(\.amountMinor) == [501, 500])
        let net = Dictionary(uniqueKeysWithValues: (snapshot.balances ?? []).map { ($0.userID, $0.netMinor) })
        let expectedDavid: Int64 = 9000 - 3000 - 501
        #expect(net[f.david.id] == expectedDavid)
        #expect(net[f.ana.id] == 1001 - 3000 - 500)
        #expect(net.values.reduce(0, +) == 0)
    }

    @Test func deletedExpensesAreNotExported() async throws {
        let f = try await makeFixture()
        let all = try await f.expenses.expenses(in: f.group.id)
        try await f.expenses.deleteExpense(id: all[0].id)

        let snapshot = try await f.archive.snapshot(of: f.group.id)
        #expect(snapshot.expenses.count == 1)
    }

    @Test func unknownGroupIsAnError() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.groupNotFound(UUID(uuid: UUID_NULL))) {
            _ = try await f.archive.snapshot(of: UUID(uuid: UUID_NULL))
        }
    }

    // MARK: - Files

    @Test func fileRoundTripKeepsEverything() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)

        let decoded = try GroupSnapshot.decode(fileData: try snapshot.fileData())
        #expect(decoded == snapshot)
    }

    @Test func fileIsReadableJSONWithAFormatMarker() async throws {
        let f = try await makeFixture()
        let data = try await f.archive.snapshot(of: f.group.id).fileData()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "tab.group")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["expenses"] is [Any])
    }

    @Test func rejectsFilesThatAreNotTabFiles() throws {
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(fileData: Data("hello".utf8)) }
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(fileData: Data()) }
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(fileData: Data("[1,2]".utf8)) }
        #expect(throws: SnapshotError.notATabFile) {
            try GroupSnapshot.decode(fileData: Data(#"{"format":"other","schemaVersion":1}"#.utf8))
        }
    }

    @Test func rejectsFilesFromNewerVersions() throws {
        let data = Data(#"{"format":"tab.group","schemaVersion":99,"whatever":true}"#.utf8)
        #expect(throws: SnapshotError.newerVersion(99)) { try GroupSnapshot.decode(fileData: data) }
    }

    @Test func rejectsTruncatedAndOversizedFiles() async throws {
        let f = try await makeFixture()
        let data = try await f.archive.snapshot(of: f.group.id).fileData()
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(fileData: data.prefix(data.count / 2)) }
        let huge = Data(repeating: 0x20, count: GroupSnapshot.maximumFileSize + 1)
        #expect(throws: SnapshotError.tooLarge) { try GroupSnapshot.decode(fileData: huge) }
    }

    @Test func rejectsTamperedContent() async throws {
        let f = try await makeFixture()
        var snapshot = try await f.archive.snapshot(of: f.group.id)

        var wrongSplits = snapshot
        wrongSplits.expenses[0].splits[0].amountMinor += 1
        #expect(throws: SnapshotError.self) { try wrongSplits.validate() }

        var wrongBalances = snapshot
        wrongBalances.balances?[0].netMinor += 1
        #expect(throws: SnapshotError.balancesDoNotMatch) { try wrongBalances.validate() }

        var stranger = snapshot
        stranger.expenses[0].paidBy = UUID()
        #expect(throws: SnapshotError.self) { try stranger.validate() }

        var emptyName = snapshot
        emptyName.group.name = "   "
        #expect(throws: SnapshotError.emptyGroupName) { try emptyName.validate() }

        var negative = snapshot
        negative.expenses[0].amountMinor = -5
        #expect(throws: SnapshotError.self) { try negative.validate() }

        snapshot.expenses.append(snapshot.expenses[0])
        #expect(throws: SnapshotError.duplicateExpense(snapshot.expenses[0].id)) { try snapshot.validate() }
    }

    // MARK: - Links

    @Test func linkRoundTripKeepsEverything() async throws {
        let f = try await makeFixture()
        var snapshot = try await f.archive.snapshot(of: f.group.id)
        let url = try snapshot.link()

        #expect(url.scheme == "tab")
        #expect(url.host == "group")
        let decoded = try GroupSnapshot.decode(link: url)
        snapshot.balances = nil
        #expect(decoded == snapshot)
    }

    @Test func linkSurvivesBeingPastedAsText() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let text = try snapshot.link().absoluteString
        let url = try #require(URL(string: text))
        #expect(try GroupSnapshot.decode(link: url).expenses.count == 2)
    }

    @Test func rejectsForeignAndBrokenLinks() async throws {
        #expect(throws: SnapshotError.notATabFile) { try GroupSnapshot.decode(link: URL(string: "https://example.com")!) }
        #expect(throws: SnapshotError.notATabFile) { try GroupSnapshot.decode(link: URL(string: "tab://group")!) }
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(link: URL(string: "tab://group?d=!!!")!) }
        #expect(throws: SnapshotError.unreadable) { try GroupSnapshot.decode(link: URL(string: "tab://group?d=AAAA")!) }
    }

    @Test func linkDoesNotInflateWithoutBound() throws {
        let bomb = try Deflate.compress(Data(repeating: 0x41, count: GroupSnapshot.maximumFileSize + 1024))
        var components = URLComponents()
        components.scheme = "tab"
        components.host = "group"
        components.queryItems = [URLQueryItem(name: "d", value: bomb.base64URLEncodedString())]
        #expect(throws: SnapshotError.tooLarge) { try GroupSnapshot.decode(link: components.url!) }
    }

    @Test func demoSizedGroupFitsInAQRCode() async throws {
        // A QR code (version 40, low correction) holds 2,953 bytes. The link is what the code carries.
        let f = try await makeFixture()
        for index in 0..<8 {
            _ = try await f.expenses.createExpense(
                groupID: f.group.id, paidBy: [f.david, f.ana, f.leo][index % 3].id, title: "Gasto número \(index)",
                amountMinor: Int64(1000 + index * 137),
                shares: try EqualSplit.shares(amountMinor: Int64(1000 + index * 137), among: [f.david.id, f.ana.id, f.leo.id])
            )
        }
        let url = try await f.archive.snapshot(of: f.group.id).link()
        #expect(url.absoluteString.utf8.count < 2_000, "link is \(url.absoluteString.utf8.count) bytes")
    }

    // MARK: - Import

    @Test func importCreatesTheGroupAndAddsTheUserAsMember() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let (archive, groups, me, expenses) = try await freshDatabase()

        let id = try await archive.importGroup(snapshot, mode: .updateExisting, me: me.id)

        #expect(id == f.group.id)
        let imported = try #require(try await groups.group(id: id))
        #expect(imported.name == "Lisboa 🇵🇹")
        #expect(imported.currency == .eur)
        let members = try await groups.members(of: id)
        #expect(members.map(\.name) == ["David", "Ana", "Léo", "Marta"])
        #expect(try await expenses.expenses(in: id).count == 2)
        let net = try await balances(id, groups: groups, expenses: expenses)
        #expect(net[f.david.id] == Int64(5499))
        #expect(net[me.id] == Int64(0))
    }

    @Test func importAttributesTheChosenPersonToTheLocalUser() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let (archive, groups, me, expenses) = try await freshDatabase()

        let id = try await archive.importGroup(snapshot, mode: .updateExisting, me: me.id, asParticipant: f.ana.id)

        let members = try await groups.members(of: id)
        #expect(members.map(\.name) == ["David", "Marta", "Léo"])
        let net = try await balances(id, groups: groups, expenses: expenses)
        #expect(net[me.id] == Int64(-2499))
        #expect(net[f.ana.id] == nil)
    }

    @Test func importRejectsAParticipantThatIsNotInTheFile() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let (archive, _, me, _) = try await freshDatabase()
        let stranger = UUID()
        await #expect(throws: SnapshotError.unknownParticipant(stranger)) {
            try await archive.importGroup(snapshot, mode: .updateExisting, me: me.id, asParticipant: stranger)
        }
    }

    @Test func importingTwiceUpdatesInsteadOfDuplicating() async throws {
        let f = try await makeFixture()
        let first = try await f.archive.snapshot(of: f.group.id)
        let (archive, groups, me, expenses) = try await freshDatabase()
        let id = try await archive.importGroup(first, mode: .updateExisting, me: me.id)

        _ = try await f.expenses.createExpense(
            groupID: f.group.id, paidBy: f.leo.id, title: "Museo", amountMinor: 600,
            shares: [SplitShare(userID: f.leo.id, amountMinor: 300), SplitShare(userID: f.david.id, amountMinor: 300)]
        )
        let second = try await f.archive.snapshot(of: f.group.id)
        let again = try await archive.importGroup(second, mode: .updateExisting, me: me.id)

        #expect(again == id)
        #expect(try await groups.groups().count == 1)
        #expect(try await expenses.expenses(in: id).count == 3)
        #expect(try await groups.members(of: id).count == 4)
    }

    @Test func updateDropsExpensesRemovedFromTheFile() async throws {
        let f = try await makeFixture()
        let first = try await f.archive.snapshot(of: f.group.id)
        let (archive, _, me, expenses) = try await freshDatabase()
        let id = try await archive.importGroup(first, mode: .updateExisting, me: me.id)

        try await f.expenses.deleteExpense(id: try await f.expenses.expenses(in: f.group.id)[0].id)
        _ = try await archive.importGroup(try await f.archive.snapshot(of: f.group.id), mode: .updateExisting, me: me.id)

        #expect(try await expenses.expenses(in: id).count == 1)
    }

    @Test func addAsCopyNeverTouchesTheOriginal() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)

        let copyID = try await f.archive.importGroup(snapshot, mode: .addAsCopy, me: f.david.id)

        #expect(copyID != f.group.id)
        #expect(try await f.groups.groups().count == 2)
        #expect(try await f.expenses.expenses(in: f.group.id).count == 2)
        #expect(try await f.expenses.expenses(in: copyID).count == 2)
        let copyMembers = try await f.groups.members(of: copyID)
        #expect(copyMembers.contains { $0.id == f.david.id })
        #expect(Set(copyMembers.map(\.id)).intersection([f.ana.id, f.leo.id]).isEmpty)
        let original = try await balances(f.group.id, groups: f.groups, expenses: f.expenses)
        let copy = try await balances(copyID, groups: f.groups, expenses: f.expenses)
        #expect(original[f.david.id] == copy[f.david.id])
    }

    @Test func importRefusesToReplaceAGroupWithAnotherCurrency() async throws {
        let f = try await makeFixture()
        var snapshot = try await f.archive.snapshot(of: f.group.id)
        snapshot = GroupSnapshot(
            exportedAt: snapshot.exportedAt,
            group: .init(id: snapshot.group.id, name: snapshot.group.name, currency: .usd,
                         createdBy: snapshot.group.createdBy, createdAt: snapshot.group.createdAt),
            participants: snapshot.participants, expenses: snapshot.expenses
        )
        await #expect(throws: SnapshotError.currencyMismatch) {
            try await f.archive.importGroup(snapshot, mode: .updateExisting, me: f.david.id)
        }
        #expect(try await f.expenses.expenses(in: f.group.id).count == 2)
    }

    @Test func aFailedImportLeavesNothingBehind() async throws {
        let f = try await makeFixture()
        var snapshot = try await f.archive.snapshot(of: f.group.id)
        snapshot.balances = nil
        let (archive, groups, _, _) = try await freshDatabase()
        // The profile does not exist in this database.
        await #expect(throws: DomainError.self) {
            try await archive.importGroup(snapshot, mode: .updateExisting, me: UUID())
        }
        #expect(try await groups.groups().isEmpty)
    }

    @Test func importedDataIsNotQueuedForSync() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let database = try Database.inMemory()
        let me = try await SQLiteGroupRepository(database: database).createUser(name: "Marta", email: nil)
        let before = try await database.query("SELECT COUNT(*) AS n FROM pending_operation")[0].int("n")

        _ = try await GroupArchive(database: database).importGroup(snapshot, mode: .updateExisting, me: me.id)

        #expect(try await database.query("SELECT COUNT(*) AS n FROM pending_operation")[0].int("n") == before)
    }

    // MARK: - Backup, restore and delete

    @Test func backupAndRestoreRebuildEverything() async throws {
        let f = try await makeFixture()
        _ = try await f.groups.createGroup(name: "Casa", currency: .usd, createdBy: f.david.id)
        let backup = try await f.archive.backup(me: f.david.id)
        #expect(backup.groups.count == 2)

        let data = try backup.fileData()
        let decoded = try BackupFile.decode(fileData: data)
        #expect(decoded == backup)

        let (archive, groups, _, expenses) = try await freshDatabase(profile: "Someone else")
        let me = try await archive.restore(decoded)

        #expect(me == f.david.id)
        #expect(try await groups.user(id: me)?.name == "David")
        #expect(try await groups.groups().count == 2)
        #expect(try await groups.members(of: f.group.id).map(\.name) == ["David", "Ana", "Léo"])
        #expect(try await expenses.expenses(in: f.group.id).count == 2)
        let original = try await balances(f.group.id, groups: f.groups, expenses: f.expenses)
        let restored = try await balances(f.group.id, groups: groups, expenses: expenses)
        #expect(original == restored)
        #expect(try await groups.user(id: UUID()) == nil)
    }

    @Test func restoreReplacesWhatWasThere() async throws {
        let f = try await makeFixture()
        let backup = try await f.archive.backup(me: f.david.id)
        _ = try await f.groups.createGroup(name: "Extra", currency: .eur, createdBy: f.david.id)

        _ = try await f.archive.restore(backup)

        #expect(try await f.groups.groups().map(\.name) == ["Lisboa 🇵🇹"])
    }

    @Test func backupRejectsBrokenFilesAndGroupFilesAreNotBackups() async throws {
        let f = try await makeFixture()
        let group = try await f.archive.snapshot(of: f.group.id).fileData()
        #expect(throws: SnapshotError.notATabFile) { try BackupFile.decode(fileData: group) }
        #expect(throws: SnapshotError.unreadable) { try BackupFile.decode(fileData: Data("nope".utf8)) }
        #expect(throws: SnapshotError.newerVersion(7)) {
            try BackupFile.decode(fileData: Data(#"{"format":"tab.backup","schemaVersion":7}"#.utf8))
        }
        let backupData = try await f.archive.backup(me: f.david.id).fileData()
        #expect(throws: SnapshotError.notATabFile) { try GroupSnapshot.decode(fileData: backupData) }
    }

    @Test func aBadBackupDoesNotWipeTheCurrentData() async throws {
        let f = try await makeFixture()
        var backup = try await f.archive.backup(me: f.david.id)
        backup.groups[0].expenses[0].amountMinor += 1  // splits no longer add up
        await #expect(throws: SnapshotError.self) { try await f.archive.restore(backup) }
        #expect(try await f.groups.groups().count == 1)
        #expect(try await f.expenses.expenses(in: f.group.id).count == 2)
    }

    @Test func deleteAllDataLeavesAnEmptyDatabase() async throws {
        let f = try await makeFixture()
        try await f.archive.deleteAllData()

        #expect(try await f.groups.groups().isEmpty)
        #expect(try await f.groups.user(id: f.david.id) == nil)
        #expect(try await f.expenses.expenses(in: f.group.id).isEmpty)
        #expect(try await f.database.query("SELECT COUNT(*) AS n FROM pending_operation")[0].int("n") == 0)
        // The database is still usable.
        let again = try await f.groups.createUser(name: "New", email: nil)
        #expect(try await f.groups.user(id: again.id)?.name == "New")
    }

    @Test func summaryListsTheSameSuggestedPaymentsAsTheGroupScreen() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let text = SettlementText.text(for: snapshot)
        let eur = Currency.eur

        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "Lisboa 🇵🇹 – who owes whom")
        #expect(lines.contains("Léo owes David \(eur.format(minorUnits: 3000))"))
        #expect(lines.contains("Ana owes David \(eur.format(minorUnits: 2499))"))
        #expect(lines.count == 3)
    }

    @Test func summaryOfASettledGroupSaysSo() async throws {
        let (archive, groups, me, _) = try await freshDatabase(profile: "Marta")
        let group = try await groups.createGroup(name: "Casa", currency: .eur, createdBy: me.id)
        let snapshot = try await archive.snapshot(of: group.id)
        #expect(SettlementText.text(for: snapshot) == "Casa – who owes whom\nEveryone is settled up.")
    }

    @Test func summaryUsesTheGivenPhrases() async throws {
        let f = try await makeFixture()
        let snapshot = try await f.archive.snapshot(of: f.group.id)
        let phrases = SettlementText.Phrases(
            title: { "Resumen de \($0)" }, payment: { "\($0) debe a \($1): \($2)" }, settled: "Todo saldado."
        )
        let text = SettlementText.text(for: snapshot, phrases: phrases)
        #expect(text.hasPrefix("Resumen de Lisboa 🇵🇹\nLéo debe a David: "))
    }
}

@Suite("Opening TAB files")
struct TABFileTests {
    @Test func tellsGroupsAndBackupsApart() throws {
        let me = GroupSnapshot.Participant(id: UUID(), name: "Me", createdAt: 0)
        let group = GroupSnapshot(
            exportedAt: 0,
            group: .init(id: UUID(), name: "G", currency: .eur, createdBy: me.id, createdAt: 0),
            participants: [me], expenses: []
        )
        let backup = BackupFile(exportedAt: 0, me: me, groups: [group])

        #expect(try TABFile.decode(fileData: try group.fileData()) == .group(group))
        #expect(try TABFile.decode(fileData: try backup.fileData()) == .backup(backup))
    }

    @Test func refusesEverythingElse() {
        #expect(throws: SnapshotError.unreadable) { try TABFile.decode(fileData: Data("plain text".utf8)) }
        #expect(throws: SnapshotError.notATabFile) { try TABFile.decode(fileData: Data(#"{"format":"x"}"#.utf8)) }
        #expect(throws: SnapshotError.newerVersion(5)) {
            try TABFile.decode(fileData: Data(#"{"format":"tab.group","schemaVersion":5}"#.utf8))
        }
    }
}
