import Foundation

public enum AuthError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredentials
    case emailAlreadyRegistered
    case weakPassword
    case confirmationRequired
    case notSignedIn
    case offline
    case server(status: Int, message: String)
}

/// Registration and login against Supabase Auth (GoTrue). The session is persisted through a
/// `SessionStore` and refreshed shortly before it expires.
public actor AuthClient {
    private let config: SupabaseConfig
    private let transport: any HTTPTransport
    private let store: any SessionStore
    private let now: @Sendable () -> Date
    /// Refresh when fewer than this many seconds of validity remain.
    private let refreshMargin: TimeInterval = 60

    public init(
        config: SupabaseConfig,
        transport: any HTTPTransport = URLSession.shared,
        store: any SessionStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.store = store
        self.now = now
    }

    public func currentSession() throws -> AuthSession? {
        try store.load()
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws -> AuthSession {
        let data = try await post("auth/v1/signup", body: ["email": email, "password": password])
        // With email confirmation enabled GoTrue answers with the user but no tokens.
        guard let session = try Self.decodeSession(data, now: now()) else { throw AuthError.confirmationRequired }
        try store.save(session)
        return session
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> AuthSession {
        let data = try await post("auth/v1/token?grant_type=password", body: ["email": email, "password": password])
        guard let session = try Self.decodeSession(data, now: now()) else { throw AuthError.invalidCredentials }
        try store.save(session)
        return session
    }

    /// A session that is valid for at least the refresh margin, refreshing it first if needed.
    public func validSession() async throws -> AuthSession {
        guard let session = try store.load() else { throw AuthError.notSignedIn }
        if session.expiresAt.timeIntervalSince(now()) > refreshMargin { return session }

        do {
            let data = try await post(
                "auth/v1/token?grant_type=refresh_token", body: ["refresh_token": session.refreshToken]
            )
            guard let refreshed = try Self.decodeSession(data, now: now()) else { throw AuthError.notSignedIn }
            try store.save(refreshed)
            return refreshed
        } catch AuthError.invalidCredentials {
            // The refresh token was revoked or already used: the user must sign in again.
            try store.clear()
            throw AuthError.notSignedIn
        }
    }

    /// Signs out locally even when the server cannot be reached; the stale token expires on its own.
    public func signOut() async {
        if let session = try? store.load() {
            _ = try? await post("auth/v1/logout", body: nil, bearer: session.accessToken)
        }
        try? store.clear()
    }

    // MARK: - HTTP

    private func post(_ path: String, body: [String: String]?, bearer: String? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: config.url.appendingPathComponent("/"))?.absoluteURL else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer ?? config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where Self.isConnectivity(error) {
            throw AuthError.offline
        }
        guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    private static func isConnectivity(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed]
            .contains(error.code)
    }

    private static func error(status: Int, data: Data) -> AuthError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["error_code"] as? String ?? object?["error"] as? String ?? ""
        let message = object?["error_description"] as? String ?? object?["msg"] as? String
            ?? object?["message"] as? String ?? "HTTP \(status)"
        switch code {
        case "invalid_credentials", "invalid_grant", "refresh_token_not_found", "refresh_token_already_used":
            return .invalidCredentials
        case "user_already_exists", "email_exists": return .emailAlreadyRegistered
        case "weak_password": return .weakPassword
        default: return .server(status: status, message: message)
        }
    }

    private struct Payload: Decodable {
        struct User: Decodable {
            let id: UUID
            let email: String?
        }
        let access_token: String?
        let refresh_token: String?
        let expires_in: TimeInterval?
        let expires_at: TimeInterval?
        let user: User?
    }

    static func decodeSession(_ data: Data, now: Date) throws -> AuthSession? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let access = payload.access_token, let refresh = payload.refresh_token, let user = payload.user else {
            return nil
        }
        let expiry = payload.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval(payload.expires_in ?? 3600)
        return AuthSession(accessToken: access, refreshToken: refresh, expiresAt: expiry, userID: user.id, email: user.email)
    }
}
