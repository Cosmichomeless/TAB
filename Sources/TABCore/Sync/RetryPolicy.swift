import Foundation

/// How the sync engine reacts to something that went wrong with one operation.
public enum FailureClass: Equatable, Sendable {
    /// Network or server trouble that is expected to pass: retry with backoff, keep the order.
    case retry
    /// The session is missing or expired: pause synchronization, refresh, then retry. Does not count as an attempt.
    case unauthenticated
    /// The entity changed remotely since the operation's base version.
    case conflict
    /// The backend will never accept this operation as it is.
    case permanent

    /// Maps the SQLSTATE returned by the RPCs, or an HTTP status when there is none, to a reaction.
    /// Unknown errors are treated as transient on purpose: losing data is worse than retrying once more.
    public static func classify(sqlState: String?, httpStatus: Int? = nil) -> FailureClass {
        switch sqlState {
        case "40001": return .conflict
        case "28000": return .unauthenticated
        case "42501", "22023", "23505", "23503", "23514": return .permanent
        case "P0002": return .retry // parent not synced yet; the group ordering rule normally prevents this
        default: break
        }
        switch httpStatus {
        case 401: return .unauthenticated
        case 400, 403, 404, 409, 422: return .permanent
        default: return .retry // 5xx, 429, timeouts, unknown
        }
    }
}

/// Exponential backoff with a cap. Pure, so it is easy to test and to reason about.
public struct RetryPolicy: Sendable, Equatable {
    public let base: TimeInterval
    public let cap: TimeInterval

    public static let standard = RetryPolicy(base: 2, cap: 300)

    public init(base: TimeInterval, cap: TimeInterval) {
        self.base = base
        self.cap = cap
    }

    /// Delay before the next attempt, given how many attempts have already failed (`>= 1`).
    public func delay(afterFailedAttempts attempts: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempts - 1, 30)))
        return min(cap, base * pow(2, exponent))
    }
}
