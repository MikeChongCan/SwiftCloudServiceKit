//
//  DirectCallbackASWebAuthenticationURLHandler.swift
//  CloudServiceKit
//

#if targetEnvironment(macCatalyst) || os(iOS)

import AuthenticationServices
import Foundation
import OAuthSwift
import UIKit

/// Routes `ASWebAuthenticationSession` callbacks directly to OAuthSwift.
///
/// OAuthSwift's stock `ASWebAuthenticationURLHandler` re-opens the callback via
/// `UIApplication.shared.open`, which leaves `connectWithASWebAuthenticationSession`
/// hanging unless the host app also forwards those URLs to `OAuthSwift.handle(url:)`.
@available(iOS 13.0, macCatalyst 13.0, *)
final class DirectCallbackASWebAuthenticationURLHandler: OAuthSwiftURLHandlerType {
    private var webAuthSession: ASWebAuthenticationSession?
    private let prefersEphemeralWebBrowserSession: Bool
    private let callbackUrlScheme: String
    private weak var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?

    init(
        callbackUrlScheme: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding?,
        prefersEphemeralWebBrowserSession: Bool = false
    ) {
        self.callbackUrlScheme = callbackUrlScheme
        self.presentationContextProvider = presentationContextProvider
        self.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
    }

    func handle(_ url: URL) {
        webAuthSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackUrlScheme,
            completionHandler: { [callbackUrlScheme] callback, error in
                if let error {
                    let msg = error.localizedDescription.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
                    let nsError = error as NSError
                    let urlString = "\(callbackUrlScheme):?error=\(msg ?? "UNKNOWN")&error_domain=\(nsError.domain)&error_code=\(nsError.code)"
                    if let url = URL(string: urlString) {
                        OAuthSwift.handle(url: url)
                    }
                } else if let successURL = callback {
                    OAuthSwift.handle(url: successURL)
                }
            }
        )
        webAuthSession?.presentationContextProvider = presentationContextProvider
        webAuthSession?.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
        _ = webAuthSession?.start()
    }
}

#endif
