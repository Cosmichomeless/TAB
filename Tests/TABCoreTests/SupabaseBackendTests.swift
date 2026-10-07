import Foundation
import Testing
@testable import TABCore

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (status, body) = try handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let accountID = UUID()
private let config = SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key")

private func makeBackend(_ transport: StubTransport, session: AuthSession? = nil) -> SupabaseBackend {
    let session = session ?? AuthSession(
        accessToken: "access-token", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600),
        userID: accountID, email: "david@example.com"
    )
    let auth = AuthClient(config: config, transport: transport, store: InMemorySessionStore(session: session))
    return SupabaseBackend(config: config, auth: auth, transport: transport)
}

private func operation(_ kind: OperationKind, payload: any Encodable, entityID: UUID = UUID(), groupID: UUID? = nil) throws -> PendingOperation {
    PendingOperation(
        id: UUID(), seq: 1, kind: kind, entityID: entityID, groupID: groupID, payload: try JSONEncoder().encode(payload),
        status: .pending, attempts: 0, nextAttemptAt: Date(timeIntervalSince1970: 0), lastError: nil, createdAt: Date()
    )
}

@Suite("Supabase backend")
struct SupabaseBackendTests {
    private let expense = UpsertExpensePayload(
        id: UUID(), groupID: UUID(), paidBy: UUID(), title: "Dinner", amountMinor: 3000,
        createdAt: 1_800_000_000_000, updatedAt: 1_800_000_001_000, deletedAt: nil,
        splits: [.init(id: UUID(), userID: UUID(), amountMinor: 3000)]
    )

    // MARK: - Requests

    @Test func expenseOperationBecomesAnRPCCallWithBaseVersion() throws {
        let op = try operation(.upsertExpense, payload: expense)
        let (function, arguments) = try SupabaseBackend.call(for: op, baseVersion: 3)

        #expect(function == "upsert_expense")
        #expect(arguments["p_id"] as? String == expense.id.uuidString.lowercased())
        #expect(arguments["p_base_version"] as? Int64 == 3)
        #expect(arguments["p_amount_minor"] as? Int64 == 3000)
        #expect(arguments["p_deleted_at"] is NSNull)
        #expect(arguments["p_created_at"] as? String == "2027-01-15T08:00:00.000Z")
        let splits = try #require(arguments["p_splits"] as? [[String: Any]])
        #expect(splits.count == 1)
        #expect(splits.first?["amount_minor"] as? Int64 == 3000)
    }

    @Test func everyOperationKindMapsToItsFunction() throws {
        let user = UpsertParticipantPayload(id: UUID(), name: "Ana", email: nil, createdAt: 0)
        let group = CreateGroupPayload(id: UUID(), name: "Trip", currency: "EUR", createdBy: UUID(), createdAt: 0)
        let member = AddMemberPayload(id: UUID(), groupID: UUID(), userID: UUID(), createdAt: 0)

        #expect(try SupabaseBackend.call(for: operation(.claimUser, payload: user), baseVersion: 0).0 == "claim_user")
        #expect(try SupabaseBackend.call(for: operation(.upsertParticipant, payload: user), baseVersion: 0).0 == "upsert_participant")
        #expect(try SupabaseBackend.call(for: operation(.createGroup, payload: group), baseVersion: 0).0 == "create_group")
        #expect(try SupabaseBackend.call(for: operation(.addMember, payload: member), baseVersion: 0).0 == "add_member")
        let claim = try SupabaseBackend.call(for: operation(.claimUser, payload: user), baseVersion: 0).1
        #expect(claim["p_email"] is NSNull)
    }

    @Test func requestsCarryBothKeysAndHitTheRPCEndpoint() async throws {
        let transport = StubTransport { _ in (200, #"{"version":1,"server_seq":7}"#) }
        let backend = makeBackend(transport)

        let ack = try await backend.send(operation(.upsertExpense, payload: expense), baseVersion: 0)

        #expect(ack == RemoteAck(version: 1, serverSeq: 7))
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/rpc/upsert_expense")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }

    @Test func groupAckCarriesTheInviteCode() async throws {
        let invite = UUID()
        let transport = StubTransport { _ in (200, #"{"version":1,"server_seq":2,"invite_code":"\#(invite.uuidString)"}"#) }
        let group = CreateGroupPayload(id: UUID(), name: "Trip", currency: "EUR", createdBy: UUID(), createdAt: 0)

        let ack = try await makeBackend(transport).send(operation(.createGroup, payload: group), baseVersion: 0)

        #expect(ack.inviteCode == invite)
    }

    @Test func accountIDIsTheSessionUser() async throws {
        let backend = makeBackend(StubTransport { _ in (500, "{}") })
        #expect(try await backend.accountID() == accountID.uuidString)
    }

    // MARK: - Errors

    @Test func rpcErrorsKeepTheirSQLState() async throws {
        let transport = StubTransport { _ in (409, #"{"code":"40001","message":"version conflict: current version is 4"}"#) }
        let backend = makeBackend(transport)

        do {
            _ = try await backend.send(operation(.upsertExpense, payload: expense), baseVersion: 2)
            Issue.record("expected an error")
        } catch let error as RemoteError {
            #expect(error == .server(sqlState: "40001", status: 409, message: "version conflict: current version is 4"))
            #expect(error.currentVersion == 4)
        }
    }

    @Test func postgrestErrorsWithoutSQLStateFallBackToTheStatus() async throws {
        let transport = StubTransport { _ in (401, #"{"code":"PGRST301","message":"JWT expired"}"#) }
        do {
            _ = try await makeBackend(transport).pull(since: 0, limit: 10, groupID: nil)
            Issue.record("expected an error")
        } catch let error as RemoteError {
            #expect(error == .server(sqlState: nil, status: 401, message: "JWT expired"))
            #expect(FailureClass.classify(sqlState: nil, httpStatus: 401) == .unauthenticated)
        }
    }

    @Test func connectivityFailuresAreOffline() async throws {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: RemoteError.offline) {
            try await makeBackend(transport).send(operation(.upsertExpense, payload: expense), baseVersion: 0)
        }
    }

    @Test func aMissingSessionLooksLikeA401() async throws {
        let auth = AuthClient(config: config, transport: StubTransport { _ in (500, "{}") }, store: InMemorySessionStore())
        let backend = SupabaseBackend(config: config, auth: auth, transport: StubTransport { _ in (500, "{}") })
        await #expect(throws: RemoteError.server(sqlState: "28000", status: 401, message: "not signed in")) {
            try await backend.accountID()
        }
    }

    @Test func anUnreadablePayloadIsPermanent() async throws {
        var op = try operation(.upsertExpense, payload: expense)
        op = PendingOperation(
            id: op.id, seq: 1, kind: .upsertExpense, entityID: op.entityID, groupID: nil, payload: Data("{}".utf8),
            status: .pending, attempts: 0, nextAttemptAt: Date(timeIntervalSince1970: 0), lastError: nil, createdAt: Date()
        )
        let transport = StubTransport { _ in (200, "{}") }
        do {
            _ = try await makeBackend(transport).send(op, baseVersion: 0)
            Issue.record("expected an error")
        } catch let error as RemoteError {
            guard case .server(let state, _, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(FailureClass.classify(sqlState: state) == .permanent)
            #expect(transport.requests.isEmpty)
        }
    }

    // MARK: - Pull decoding

    @Test func decodesAPullResponseWithPostgresTimestamps() throws {
        let group = UUID(), user = UUID(), member = UUID(), expenseID = UUID(), split = UUID()
        let json = """
        [
          {"entity":"user","server_seq":1,"payload":{"id":"\(user)","name":"David","email":null,
            "created_at":"2026-10-07T10:00:00.123456+00:00","version":1,"server_seq":1,"extra":"ignored"}},
          {"entity":"group","server_seq":2,"payload":{"id":"\(group)","name":"Trip","currency":"EUR","created_by":"\(user)",
            "created_at":"2026-10-07T10:00:01+00:00","invite_code":"\(UUID())","version":1,"server_seq":2}},
          {"entity":"group_member","server_seq":3,"payload":{"id":"\(member)","group_id":"\(group)","user_id":"\(user)",
            "created_at":"2026-10-07T10:00:02.5Z","version":1,"server_seq":3}},
          {"entity":"expense","server_seq":4,"payload":{"id":"\(expenseID)","group_id":"\(group)","paid_by":"\(user)",
            "title":"Dinner","amount_minor":3000,"currency":"EUR","created_at":"2026-10-07T10:00:03.000001+00:00",
            "updated_at":"2026-10-07T10:00:04+00:00","deleted_at":null,"version":2,"server_seq":4,
            "splits":[{"id":"\(split)","user_id":"\(user)","amount_minor":3000}]}},
          {"entity":"something_new","server_seq":5,"payload":{"id":"\(UUID())"}}
        ]
        """

        let changes = try SupabaseBackend.decodeChanges(Data(json.utf8))

        #expect(changes.map(\.serverSeq) == [1, 2, 3, 4])
        guard case .user(let decodedUser) = changes[0], case .expense(let decodedExpense) = changes[3] else {
            Issue.record("unexpected entities")
            return
        }
        #expect(decodedUser.id == user)
        #expect(decodedUser.email == nil)
        #expect(abs(decodedUser.createdAt.timeIntervalSince1970 - 1_791_367_200.123456) < 0.001)
        #expect(decodedExpense.version == 2)
        #expect(decodedExpense.currency == "EUR")
        #expect(decodedExpense.splits.map(\.amountMinor) == [3000])
        #expect(decodedExpense.deletedAt == nil)
    }

    @Test func pullSendsTheCursorAndGroup() async throws {
        let transport = StubTransport { _ in (200, "[]") }
        let group = UUID()

        let changes = try await makeBackend(transport).pull(since: 42, limit: 500, groupID: group)

        #expect(changes.isEmpty)
        let body = try #require(transport.requests.last?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["p_since"] as? Int == 42)
        #expect(object["p_limit"] as? Int == 500)
        #expect(object["p_group_id"] as? String == group.uuidString.lowercased())
    }

    @Test func dateRoundTripKeepsMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.456)
        let parsed = try #require(RemoteDate.parse(RemoteDate.format(date)))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
        #expect(RemoteDate.parse("2026-10-07T10:00:00Z") != nil)
        #expect(RemoteDate.parse("not a date") == nil)
    }
}
