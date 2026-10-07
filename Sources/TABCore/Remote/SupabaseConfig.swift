import Foundation

/// Where the Supabase project lives. Nothing here is a secret: the anon key is meant to ship in the app
/// and access is enforced by row level security. It is still not committed; it is injected per build.
public struct SupabaseConfig: Sendable, Equatable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Reads `SupabaseURL` and `SupabaseAnonKey` from a bundle's Info.plist. Returns `nil` when either is
    /// missing or empty, which the app treats as "backend not configured" and keeps working offline.
    public init?(bundle: Bundle) {
        guard
            let rawURL = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !rawURL.isEmpty, !key.isEmpty,
            let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true
        else { return nil }
        self.init(url: url, anonKey: key)
    }
}
