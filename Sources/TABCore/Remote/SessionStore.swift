import Foundation

public struct AuthSession: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let userID: UUID
    public let email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

/// Where the session survives app restarts. The app provides a Keychain implementation.
public protocol SessionStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    public init(session: AuthSession? = nil) {
        self.session = session
    }

    public func load() throws -> AuthSession? { lock.withLock { session } }
    public func save(_ session: AuthSession) throws { lock.withLock { self.session = session } }
    public func clear() throws { lock.withLock { session = nil } }
}
