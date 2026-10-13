import Foundation

/// Where repositories record every local change, inside their own write transaction. The rows wait in
/// `pending_operation`; only the sync engine (the `TABSync` target) reads and drains them, so a build without it
/// keeps a small, harmless history that a later sync can still send.
public enum Outbox {
    public static func enqueue<Payload: Encodable>(
        _ kind: OperationKind, entityID: UUID, groupID: UUID?, payload: Payload, in db: isolated Database
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let now = Date().millisecondsSince1970
        try db.execute(
            """
            INSERT INTO pending_operation (id, kind, entity_id, group_id, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString), .text(kind.rawValue), .text(entityID.uuidString),
                groupID.map { .text($0.uuidString) } ?? .null, .text(json), .int(now), .int(now),
            ]
        )
    }
}
