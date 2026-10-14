import Compression
import Foundation

/// A group as a `tab://group?d=...` link, which is also what a QR code carries. Opening the link in TAB imports
/// the group; nothing is sent anywhere.
///
/// The payload is deliberately compact so that ordinary groups fit in a QR code: participants are referenced by
/// position instead of by UUID, ids are 22-character base64url strings, balances are left out (they are derived)
/// and the JSON is deflated.
extension GroupSnapshot {
    public static let linkScheme = "tab"
    public static let linkHost = "group"

    /// Longest link payload that is read. Real groups are far smaller.
    static let maximumLinkPayload = 1_000_000

    public func link() throws -> URL {
        let json = try JSONEncoder.compact.encode(CompactSnapshot(self))
        let packed = try Deflate.compress(json)
        var components = URLComponents()
        components.scheme = Self.linkScheme
        components.host = Self.linkHost
        components.queryItems = [URLQueryItem(name: "d", value: packed.base64URLEncodedString())]
        guard let url = components.url else { throw SnapshotError.unreadable }
        return url
    }

    /// Reads and validates a group link.
    public static func decode(link url: URL) throws -> GroupSnapshot {
        guard url.scheme?.lowercased() == linkScheme, url.host?.lowercased() == linkHost,
            let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "d" })?.value
        else { throw SnapshotError.notATabFile }
        guard payload.utf8.count <= maximumLinkPayload else { throw SnapshotError.tooLarge }
        guard let packed = Data(base64URLEncoded: payload) else { throw SnapshotError.unreadable }
        let json = try Deflate.decompress(packed, limit: maximumFileSize)
        let snapshot: GroupSnapshot
        do {
            let compact = try JSONDecoder().decode(CompactSnapshot.self, from: json)
            guard compact.v <= currentSchemaVersion else { throw SnapshotError.newerVersion(compact.v) }
            snapshot = try compact.snapshot()
        } catch let error as SnapshotError {
            throw error
        } catch {
            throw SnapshotError.unreadable
        }
        try snapshot.validate()
        return snapshot
    }
}

// MARK: - Compact form

private struct CompactSnapshot: Codable {
    struct Person: Codable {
        var i: String
        var n: String
        var m: String?
        var a: Int64
    }

    struct Expense: Codable {
        var i: String
        /// Index of the payer in `p`.
        var p: Int
        var t: String
        var m: Int64
        var a: Int64
        /// `updatedAt - createdAt`.
        var d: Int64
        /// Pairs of participant index and amount.
        var s: [[Int64]]
    }

    var v: Int
    var t: Int64
    var i: String
    var n: String
    var c: Currency
    /// Index of the creator in `p`.
    var b: Int
    var a: Int64
    var p: [Person]
    var e: [Expense]

    init(_ snapshot: GroupSnapshot) {
        let index = Dictionary(uniqueKeysWithValues: snapshot.participants.enumerated().map { ($1.id, $0) })
        v = snapshot.schemaVersion
        t = snapshot.exportedAt
        i = snapshot.group.id.shortString
        n = snapshot.group.name
        c = snapshot.group.currency
        b = index[snapshot.group.createdBy] ?? 0
        a = snapshot.group.createdAt
        p = snapshot.participants.map { Person(i: $0.id.shortString, n: $0.name, m: $0.email, a: $0.createdAt) }
        e = snapshot.expenses.map { expense in
            Expense(
                i: expense.id.shortString, p: index[expense.paidBy] ?? 0, t: expense.title, m: expense.amountMinor,
                a: expense.createdAt, d: expense.updatedAt - expense.createdAt,
                s: expense.splits.map { [Int64(index[$0.userID] ?? 0), $0.amountMinor] }
            )
        }
    }

    func snapshot() throws -> GroupSnapshot {
        guard let groupID = UUID(shortString: i) else { throw SnapshotError.unreadable }
        let ids = try p.map { person -> UUID in
            guard let id = UUID(shortString: person.i) else { throw SnapshotError.unreadable }
            return id
        }
        func participant(_ index: Int) throws -> UUID {
            guard ids.indices.contains(index) else { throw SnapshotError.unreadable }
            return ids[index]
        }
        let expenses = try e.map { entry -> GroupSnapshot.ExpenseEntry in
            guard let id = UUID(shortString: entry.i) else { throw SnapshotError.unreadable }
            let splits = try entry.s.map { pair -> GroupSnapshot.SplitEntry in
                guard pair.count == 2, let index = Int(exactly: pair[0]) else { throw SnapshotError.unreadable }
                return GroupSnapshot.SplitEntry(userID: try participant(index), amountMinor: pair[1])
            }
            return GroupSnapshot.ExpenseEntry(
                id: id, paidBy: try participant(entry.p), title: entry.t, amountMinor: entry.m,
                createdAt: entry.a, updatedAt: entry.a + entry.d, splits: splits
            )
        }
        let people = zip(ids, p).map { GroupSnapshot.Participant(id: $0, name: $1.n, email: $1.m, createdAt: $1.a) }
        var snapshot = GroupSnapshot(
            exportedAt: t,
            group: GroupSnapshot.GroupInfo(id: groupID, name: n, currency: c, createdBy: try participant(b), createdAt: a),
            participants: people,
            expenses: expenses
        )
        snapshot.schemaVersion = v
        return snapshot
    }
}

// MARK: - Encoding helpers

extension JSONEncoder {
    fileprivate static var compact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension UUID {
    /// 22 characters instead of 36: the 16 bytes as base64url.
    var shortString: String {
        withUnsafeBytes(of: uuid) { Data($0) }.base64URLEncodedString()
    }

    init?(shortString: String) {
        guard let data = Data(base64URLEncoded: shortString), data.count == 16 else { return nil }
        self = data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }
}

/// Raw deflate (RFC 1951) through the system Compression framework.
enum Deflate {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // Deflate can expand incompressible data slightly.
        let capacity = data.count + data.count / 8 + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw SnapshotError.unreadable }
        return output.prefix(written)
    }

    /// Inflates at most `limit` bytes; anything that would expand further is refused.
    static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty else { throw SnapshotError.unreadable }
        var output = Data(count: limit + 1)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, limit + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw SnapshotError.unreadable }
        guard written <= limit else { throw SnapshotError.tooLarge }
        return output.prefix(written)
    }
}
