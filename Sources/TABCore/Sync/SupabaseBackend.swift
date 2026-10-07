import Foundation

/// `RemoteBackend` over Supabase's PostgREST: every operation is one call to an RPC from
/// `supabase/migrations/20261007000200_rpc.sql`.
public struct SupabaseBackend: RemoteBackend {
    private let config: SupabaseConfig
    private let auth: AuthClient
    private let transport: any HTTPTransport

    public init(config: SupabaseConfig, auth: AuthClient, transport: any HTTPTransport = URLSession.shared) {
        self.config = config
        self.auth = auth
        self.transport = transport
    }

    public func accountID() async throws -> String {
        try await session().userID.uuidString
    }

    public func send(_ operation: PendingOperation, baseVersion: Int64) async throws -> RemoteAck {
        let function: String
        let arguments: [String: Any]
        do {
            (function, arguments) = try Self.call(for: operation, baseVersion: baseVersion)
        } catch {
            // A payload this version cannot read will never become valid by retrying.
            throw RemoteError.server(sqlState: "22023", status: nil, message: "unreadable operation payload")
        }
        let data = try await rpc(function, arguments)
        struct Row: Decodable {
            let version: Int64
            let serverSeq: Int64
            let inviteCode: UUID?
            enum CodingKeys: String, CodingKey {
                case version
                case serverSeq = "server_seq", inviteCode = "invite_code"
            }
        }
        do {
            let row = try JSONDecoder().decode(Row.self, from: data)
            return RemoteAck(version: row.version, serverSeq: row.serverSeq, inviteCode: row.inviteCode)
        } catch {
            throw RemoteError.server(sqlState: nil, status: 200, message: "unreadable response from \(function)")
        }
    }

    public func pull(since: Int64, limit: Int, groupID: UUID?) async throws -> [RemoteChange] {
        let data = try await rpc("pull_changes", [
            "p_since": since, "p_limit": limit, "p_group_id": Self.nullable(groupID.map(Self.id)),
        ])
        do {
            return try Self.decodeChanges(data)
        } catch {
            throw RemoteError.server(sqlState: nil, status: 200, message: "unreadable response from pull_changes")
        }
    }

    // MARK: - Mapping operations to RPC calls

    static func call(for operation: PendingOperation, baseVersion: Int64) throws -> (String, [String: Any]) {
        let decoder = JSONDecoder()
        switch operation.kind {
        case .claimUser, .upsertParticipant:
            let p = try decoder.decode(UpsertParticipantPayload.self, from: operation.payload)
            let name = operation.kind == .claimUser ? "claim_user" : "upsert_participant"
            return (name, [
                "p_id": id(p.id), "p_name": p.name, "p_email": nullable(p.email), "p_created_at": timestamp(p.createdAt),
            ])
        case .createGroup:
            let p = try decoder.decode(CreateGroupPayload.self, from: operation.payload)
            return ("create_group", [
                "p_id": id(p.id), "p_name": p.name, "p_currency": p.currency, "p_created_by": id(p.createdBy),
                "p_created_at": timestamp(p.createdAt),
            ])
        case .addMember:
            let p = try decoder.decode(AddMemberPayload.self, from: operation.payload)
            return ("add_member", [
                "p_id": id(p.id), "p_group_id": id(p.groupID), "p_user_id": id(p.userID), "p_created_at": timestamp(p.createdAt),
            ])
        case .upsertExpense:
            let p = try decoder.decode(UpsertExpensePayload.self, from: operation.payload)
            return ("upsert_expense", [
                "p_id": id(p.id), "p_group_id": id(p.groupID), "p_paid_by": id(p.paidBy), "p_title": p.title,
                "p_amount_minor": p.amountMinor, "p_created_at": timestamp(p.createdAt),
                "p_updated_at": timestamp(p.updatedAt), "p_deleted_at": nullable(p.deletedAt.map(timestamp)),
                "p_splits": p.splits.map { ["id": id($0.id), "user_id": id($0.userID), "amount_minor": $0.amountMinor] },
                "p_base_version": baseVersion,
            ])
        }
    }

    static func decodeChanges(_ data: Data) throws -> [RemoteChange] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = RemoteDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return try rows.compactMap { row in
            guard let entity = row["entity"] as? String, let payload = row["payload"] else { return nil }
            let json = try JSONSerialization.data(withJSONObject: payload)
            switch entity {
            case "user": return .user(try decoder.decode(RemoteUser.self, from: json))
            case "group": return .group(try decoder.decode(RemoteGroup.self, from: json))
            case "group_member": return .member(try decoder.decode(RemoteMember.self, from: json))
            case "expense": return .expense(try decoder.decode(RemoteExpense.self, from: json))
            default: return nil // a newer server may know entities this version does not
            }
        }
    }

    private static func nullable(_ value: String?) -> Any { value ?? NSNull() }
    private static func id(_ id: UUID) -> String { id.uuidString.lowercased() }
    private static func timestamp(_ ms: Int64) -> String { RemoteDate.format(Date(timeIntervalSince1970: Double(ms) / 1000)) }

    // MARK: - HTTP

    private func session() async throws -> AuthSession {
        do {
            return try await auth.validSession()
        } catch AuthError.offline {
            throw RemoteError.offline
        } catch AuthError.notSignedIn, AuthError.invalidCredentials {
            throw RemoteError.server(sqlState: "28000", status: 401, message: "not signed in")
        }
    }

    private func rpc(_ function: String, _ arguments: [String: Any]) async throws -> Data {
        let session = try await session()
        guard let url = URL(string: "rest/v1/rpc/\(function)", relativeTo: config.url.appendingPathComponent("/"))?.absoluteURL else {
            throw RemoteError.server(sqlState: nil, status: nil, message: "invalid backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dataNotAllowed, .cancelled:
                throw RemoteError.offline
            default:
                throw RemoteError.server(sqlState: nil, status: nil, message: error.localizedDescription)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (body?["code"] as? String).flatMap { $0.hasPrefix("PGRST") ? nil : $0 }
            throw RemoteError.server(
                sqlState: code, status: response.statusCode, message: body?["message"] as? String ?? "HTTP \(response.statusCode)"
            )
        }
        return data
    }
}

/// Postgres `timestamptz` as JSON, and back.
enum RemoteDate {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    static func parse(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }

    static func format(_ date: Date) -> String {
        formatter(fractional: true).string(from: date)
    }
}
