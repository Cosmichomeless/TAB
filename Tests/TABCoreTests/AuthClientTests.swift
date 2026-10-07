import Foundation
import Testing
@testable import TABCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let userID = UUID()
private func sessionJSON(access: String = "access-1", refresh: String = "refresh-1", expiresIn: Int = 3600) -> String {
    """
    {"access_token":"\(access)","refresh_token":"\(refresh)","expires_in":\(expiresIn),
     "user":{"id":"\(userID.uuidString)","email":"david@example.com"}}
    """
}

@Suite("Supabase auth client")
struct AuthClientTests {
    private let config = SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key")

    @Test func signUpStoresSessionAndSendsKeys() async throws {
        let transport = FakeTransport { _ in (200, sessionJSON()) }
        let store = InMemorySessionStore()
        let client = AuthClient(config: config, transport: transport, store: store)

        let session = try await client.signUp(email: "david@example.com", password: "s3cret-pass")

        #expect(session.userID == userID)
        #expect(try store.load() == session)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/signup")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["email": "david@example.com", "password": "s3cret-pass"])
    }

    @Test func signUpWithoutTokensMeansConfirmationRequired() async throws {
        let transport = FakeTransport { _ in (200, #"{"id":"\#(userID.uuidString)","email":"a@b.c"}"#) }
        let client = AuthClient(config: config, transport: transport, store: InMemorySessionStore())

        await #expect(throws: AuthError.confirmationRequired) {
            try await client.signUp(email: "a@b.c", password: "s3cret-pass")
        }
    }

    @Test func signInUsesPasswordGrantAndMapsBadCredentials() async throws {
        let transport = FakeTransport { request in
            #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=password")
            return (400, #"{"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
        }
        let store = InMemorySessionStore()
        let client = AuthClient(config: config, transport: transport, store: store)

        await #expect(throws: AuthError.invalidCredentials) {
            try await client.signIn(email: "a@b.c", password: "wrong")
        }
        #expect(try store.load() == nil)
    }

    @Test func mapsRegistrationErrors() async throws {
        let exists = FakeTransport { _ in (422, #"{"error_code":"user_already_exists","msg":"exists"}"#) }
        await #expect(throws: AuthError.emailAlreadyRegistered) {
            try await AuthClient(config: config, transport: exists, store: InMemorySessionStore())
                .signUp(email: "a@b.c", password: "s3cret-pass")
        }
        let weak = FakeTransport { _ in (422, #"{"error_code":"weak_password","msg":"too short"}"#) }
        await #expect(throws: AuthError.weakPassword) {
            try await AuthClient(config: config, transport: weak, store: InMemorySessionStore())
                .signUp(email: "a@b.c", password: "1")
        }
        let broken = FakeTransport { _ in (500, #"{"msg":"boom"}"#) }
        await #expect(throws: AuthError.server(status: 500, message: "boom")) {
            try await AuthClient(config: config, transport: broken, store: InMemorySessionStore())
                .signIn(email: "a@b.c", password: "x")
        }
    }

    @Test func connectivityFailureIsReportedAsOffline() async throws {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let client = AuthClient(config: config, transport: transport, store: InMemorySessionStore())

        await #expect(throws: AuthError.offline) {
            try await client.signIn(email: "a@b.c", password: "x")
        }
    }

    @Test func validSessionIsReusedWhileFresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(600), userID: userID, email: nil)
        let transport = FakeTransport { _ in (500, "unexpected call") }
        let client = AuthClient(config: config, transport: transport, store: InMemorySessionStore(session: fresh), now: { now })

        #expect(try await client.validSession() == fresh)
        #expect(transport.requests.isEmpty)
    }

    @Test func expiringSessionIsRefreshedAndPersisted() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = AuthSession(accessToken: "old", refreshToken: "refresh-0", expiresAt: now.addingTimeInterval(10), userID: userID, email: nil)
        let transport = FakeTransport { request in
            #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=refresh_token")
            return (200, sessionJSON(access: "new", refresh: "refresh-2"))
        }
        let store = InMemorySessionStore(session: stale)
        let client = AuthClient(config: config, transport: transport, store: store, now: { now })

        let refreshed = try await client.validSession()

        #expect(refreshed.accessToken == "new")
        #expect(refreshed.expiresAt == now.addingTimeInterval(3600))
        #expect(try store.load() == refreshed)
    }

    @Test func revokedRefreshTokenSignsTheUserOut() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = AuthSession(accessToken: "old", refreshToken: "r", expiresAt: now, userID: userID, email: nil)
        let transport = FakeTransport { _ in (400, #"{"error_code":"refresh_token_not_found"}"#) }
        let store = InMemorySessionStore(session: stale)
        let client = AuthClient(config: config, transport: transport, store: store, now: { now })

        await #expect(throws: AuthError.notSignedIn) { try await client.validSession() }
        #expect(try store.load() == nil)
    }

    @Test func offlineRefreshKeepsTheSession() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = AuthSession(accessToken: "old", refreshToken: "r", expiresAt: now, userID: userID, email: nil)
        let transport = FakeTransport { _ in throw URLError(.timedOut) }
        let store = InMemorySessionStore(session: stale)
        let client = AuthClient(config: config, transport: transport, store: store, now: { now })

        await #expect(throws: AuthError.offline) { try await client.validSession() }
        #expect(try store.load() == stale)
    }

    @Test func signOutClearsLocallyEvenIfServerFails() async throws {
        let session = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, userID: userID, email: nil)
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let store = InMemorySessionStore(session: session)
        let client = AuthClient(config: config, transport: transport, store: store)

        await client.signOut()

        #expect(try store.load() == nil)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer a")
    }

    @Test func notSignedInWithoutSession() async throws {
        let client = AuthClient(config: config, transport: FakeTransport { _ in (200, "") }, store: InMemorySessionStore())
        await #expect(throws: AuthError.notSignedIn) { try await client.validSession() }
    }

    @Test func configRequiresBothValues() {
        #expect(SupabaseConfig(bundle: Bundle(for: BundleMarker.self)) == nil)
    }
}

private final class BundleMarker {}
