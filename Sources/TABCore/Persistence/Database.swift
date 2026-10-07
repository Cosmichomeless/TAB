import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
}

public struct Row: Sendable {
    fileprivate let values: [String: SQLValue]

    public func int(_ column: String) -> Int64 {
        if case .int(let value)? = values[column] { return value }
        return 0
    }

    public func text(_ column: String) -> String {
        if case .text(let value)? = values[column] { return value }
        return ""
    }

    public func optionalText(_ column: String) -> String? {
        if case .text(let value)? = values[column] { return value }
        return nil
    }

    public func optionalInt(_ column: String) -> Int64? {
        if case .int(let value)? = values[column] { return value }
        return nil
    }

    public func uuid(_ column: String) -> UUID {
        UUID(uuidString: text(column)) ?? UUID(uuid: UUID_NULL)
    }

    public func date(_ column: String) -> Date {
        Date(timeIntervalSince1970: Double(int(column)) / 1000)
    }
}

public enum DatabaseError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(sql: String, message: String)
}

extension Date {
    /// Milliseconds since the Unix epoch, the representation used in SQLite.
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}

/// A single SQLite connection. All access is serialized by the actor.
public actor Database {
    private nonisolated(unsafe) let handle: OpaquePointer
    private let broadcaster = ChangeBroadcaster()

    /// Opens (creating if needed) a database file and applies pending migrations.
    public init(path: String) throws {
        try self.init(location: path)
    }

    /// Opens a private in-memory database. Intended for tests.
    public static func inMemory() throws -> Database {
        try Database(location: ":memory:")
    }

    private init(location: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(location, &connection) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(connection)
            throw DatabaseError.openFailed(message)
        }
        self.handle = connection
        try Database.run("PRAGMA foreign_keys = ON", on: connection)
        if location != ":memory:" {
            try Database.run("PRAGMA journal_mode = WAL", on: connection)
        }
        try Migrator.migrate(connection)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Emits a value after every committed write.
    public nonisolated func changes() -> AsyncStream<Void> {
        broadcaster.stream()
    }

    // MARK: - Statements

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        _ = try Database.query(sql, parameters, on: connection())
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        try Database.query(sql, parameters, on: connection())
    }

    /// Runs `body` inside a transaction. Any thrown error rolls the transaction back.
    public func transaction<T: Sendable>(_ body: @Sendable (isolated Database) throws -> T) throws -> T {
        let connection = try connection()
        try Database.run("BEGIN IMMEDIATE", on: connection)
        do {
            let result = try body(self)
            try Database.run("COMMIT", on: connection)
            broadcaster.send()
            return result
        } catch {
            try? Database.run("ROLLBACK", on: connection)
            throw error
        }
    }

    // MARK: - Internals

    private func connection() throws -> OpaquePointer {
        handle
    }

    static func run(_ sql: String, on connection: OpaquePointer) throws {
        _ = try query(sql, [], on: connection)
    }

    static func query(_ sql: String, _ parameters: [SQLValue], on connection: OpaquePointer) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed(sql: sql, message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            }
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var values: [String: SQLValue] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                    default: values[name] = .null
                    }
                }
                rows.append(Row(values: values))
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError.statementFailed(sql: sql, message: String(cString: sqlite3_errmsg(connection)))
            }
        }
    }
}

/// Fans out "something changed" signals to any number of observers.
final class ChangeBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func stream() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send() {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield() }
    }
}
