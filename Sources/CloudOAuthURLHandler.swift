//
//  CloudOAuthURLHandler.swift
//  CloudServiceKit
//

import Foundation
import OAuthSwift

/// Fallback router for OAuth redirect URLs when they arrive through app/scene open-URL handlers.
///
/// `connectWithASWebAuthenticationSession` uses `DirectCallbackASWebAuthenticationURLHandler`
/// (0.2.2+) so most apps no longer need this. Keep wiring it in `onOpenURL` /
/// `application(_:open:options:)` if you use the Safari handler or custom URL flows.
public enum CloudOAuthURLHandler {
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard looksLikeOAuthCallback(url) else { return false }
        OAuthSwift.handle(url: url)
        return true
    }

    private static func looksLikeOAuthCallback(_ url: URL) -> Bool {
        if url.scheme?.hasPrefix("com.googleusercontent.apps.") == true,
           url.host == "oauth2redirect" || url.path == "/oauth2redirect" {
            return true
        }

        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           queryItems.contains(where: { $0.name == "code" || $0.name == "error" }) {
            return true
        }

        return false
    }
}
