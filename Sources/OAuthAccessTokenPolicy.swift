import Foundation

/// Shared OAuth access-token refresh timing helpers.
///
/// Microsoft Graph access tokens are short-lived and refresh tokens rotate on each use.
/// Callers should refresh proactively before expiry and avoid refresh storms after
/// spurious 401 responses from non-Graph upload URLs.
public enum OAuthAccessTokenPolicy: Sendable {
    /// Refresh this many seconds before `accessTokenExpiresAt`.
    public static let refreshBuffer: TimeInterval = 5 * 60

    public static func needsRefresh(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= refreshBuffer
    }

    /// After a Graph API 401, refresh only if the stored access token is near expiry.
    public static func shouldRefreshAfterUnauthorized(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= refreshBuffer
    }
}
