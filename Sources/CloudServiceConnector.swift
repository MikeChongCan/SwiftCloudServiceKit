//
//  CloudServiceConnector.swift
//  CloudServiceKit
//
//  Created by alexiscn on 2021/8/26.
//

import Foundation
import OAuthSwift
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
public typealias UIViewController = NSViewController
public typealias UIWindow = NSWindow
#endif
import CryptoKit

@MainActor
public protocol CloudServiceOAuth {
    
    var authorizeUrl: String { get }
    
    var accessTokenUrl: String { get }

}

public struct CloudOAuthTokenResult: Sendable {
    public let oauthToken: String
    public let oauthTokenSecret: String
    public let oauthRefreshToken: String
}

@MainActor
public class CloudServiceConnector: CloudServiceOAuth, CloudServiceProviderDelegate, @unchecked Sendable {
    
    /// subclass must provide authorizeUrl
    public var authorizeUrl: String { return "" }
    
    /// subclass must provide accessTokenUrl
    public var accessTokenUrl: String { return "" }
    
    /// subclass can provide more custom parameters
    public var authorizeParameters: [String: String] { return [:] }
    
    public var tokenParameters: [String: String] { return [:] }
    
    public var appId: String
    
    public var appSecret: String
    
    public var callbackUrl: String
    
    public var responseType: String
    
    public var scope: String
    
    public var state: String
    
    public var oauth: OAuth2Swift?
    
    #if targetEnvironment(macCatalyst) || os(iOS)
    public var customURLHandler: OAuthSwiftURLHandlerType?
    #endif
    
    ///   - appId: The client ID
    ///   - appSecret: The client secret
    ///   - callbackUrl: The redirect url
    ///   - responseType: The response type.  The default value is `code`.
    ///   - scope: The scope your app use for the service.
    ///   - state: The state information. The default value is empty.
    public init(appId: String, appSecret: String, callbackUrl: String, responseType: String = "code", scope: String = "", state: String = "") {
        self.appId = appId
        self.appSecret = appSecret
        self.callbackUrl = callbackUrl
        self.responseType = responseType
        self.scope = scope
        self.state = state
    }
    
    public func connect(viewController: UIViewController) async throws -> CloudOAuthTokenResult {
        try await withCheckedThrowingContinuation { continuation in
            connect(viewController: viewController) { result in
                switch result {
                case .success(let token):
                    let res = CloudOAuthTokenResult(
                        oauthToken: token.credential.oauthToken,
                        oauthTokenSecret: token.credential.oauthTokenSecret,
                        oauthRefreshToken: token.credential.oauthRefreshToken
                    )
                    continuation.resume(returning: res)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func connect(viewController: UIViewController,
                        completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        let oauth = OAuth2Swift(consumerKey: appId, consumerSecret: appSecret, authorizeUrl: authorizeUrl, accessTokenUrl: accessTokenUrl, responseType: responseType, contentType: nil)
        oauth.allowMissingStateCheck = true
        #if os(iOS)
        oauth.authorizeURLHandler = customURLHandler ?? SafariURLHandler(viewController: viewController, oauthSwift: oauth)
        #endif
        self.oauth = oauth
        _ = oauth.authorize(withCallbackURL: URL(string: callbackUrl), scope: scope, state: state, parameters: authorizeParameters, completionHandler: { result in
            switch result {
            case .success(let token):
                completion(.success(token))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }
    
    public func connectWithASWebAuthenticationSession(viewController: UIViewController, prefersEphemeralWebBrowserSession: Bool = false) async throws -> CloudOAuthTokenResult {
        try await withCheckedThrowingContinuation { continuation in
            connectWithASWebAuthenticationSession(viewController: viewController, prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession) { result in
                switch result {
                case .success(let token):
                    let res = CloudOAuthTokenResult(
                        oauthToken: token.credential.oauthToken,
                        oauthTokenSecret: token.credential.oauthTokenSecret,
                        oauthRefreshToken: token.credential.oauthRefreshToken
                    )
                    continuation.resume(returning: res)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Show a modal view  to authenticate a user through a Web Service
    public func connectWithASWebAuthenticationSession(viewController: UIViewController,
                                                      prefersEphemeralWebBrowserSession: Bool = false,
                                                      completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        let oauth = OAuth2Swift(consumerKey: appId, consumerSecret: appSecret, authorizeUrl: authorizeUrl, accessTokenUrl: accessTokenUrl, responseType: responseType, contentType: nil)
        oauth.allowMissingStateCheck = true
        #if os(iOS)
        var callbackUrlScheme = callbackUrl
        if let range = callbackUrl.range(of: ":/") {
            callbackUrlScheme = String(callbackUrl[..<range.lowerBound])
        }
        oauth.authorizeURLHandler = DirectCallbackASWebAuthenticationURLHandler(callbackUrlScheme: callbackUrlScheme,
                                                                              presentationContextProvider: viewController,
                                                                              prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession)
        #endif
        self.oauth = oauth
        _ = oauth.authorize(withCallbackURL: URL(string: callbackUrl), scope: scope, state: state, parameters: authorizeParameters, completionHandler: { result in
            switch result {
            case .success(let token):
                completion(.success(token))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }
    
    public func renewToken(with refreshToken: String) async throws -> CloudOAuthTokenResult {
        try await withCheckedThrowingContinuation { continuation in
            renewToken(with: refreshToken) { result in
                switch result {
                case .success(let token):
                    let res = CloudOAuthTokenResult(
                        oauthToken: token.credential.oauthToken,
                        oauthTokenSecret: token.credential.oauthTokenSecret,
                        oauthRefreshToken: token.credential.oauthRefreshToken
                    )
                    continuation.resume(returning: res)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func renewToken(with refreshToken: String, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        let oauth = OAuth2Swift(consumerKey: appId, consumerSecret: appSecret, authorizeUrl: authorizeUrl, accessTokenUrl: accessTokenUrl, responseType: responseType, contentType: nil)
        oauth.allowMissingStateCheck = true
        oauth.renewAccessToken(withRefreshToken: refreshToken, parameters: tokenParameters) { result in
            switch result {
            case .success(let token):
                completion(.success(token))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        self.oauth = oauth
    }
}

// MARK: - CloudServiceProviderDelegate
extension CloudServiceConnector {
    
    public func renewAccessToken(withRefreshToken refreshToken: String) async throws -> URLCredential {
        let token = try await renewToken(with: refreshToken)
        return URLCredential(user: "user", password: token.oauthToken, persistence: .permanent)
    }
    
}

// MARK: - AliyunDriveConnector
public class AliyunDriveConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        "https://open.aliyundrive.com/oauth/authorize"
    }
    
    public override var accessTokenUrl: String {
        "https://open.aliyundrive.com/oauth/access_token"
    }
    
    public override var scope: String {
        get { return "user:base,file:all:read,file:all:write" }
        set { }
    }
}

// MARK: - BaiduPanConnector
public class BaiduPanConnector: CloudServiceConnector, @unchecked Sendable {
    
    /// The OAuth2 url, which is `https://openapi.baidu.com/oauth/2.0/authorize`.
    public override var authorizeUrl: String {
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "https://openapi.baidu.com/oauth/2.0/authorize?display=pad&force_login=1"
        }
        #endif
        return "https://openapi.baidu.com/oauth/2.0/authorize?display=mobile&force_login=1"
    }
    
    /// The access token url, which is `https://openapi.baidu.com/oauth/2.0/token`.
    public override var accessTokenUrl: String {
        return "https://openapi.baidu.com/oauth/2.0/token"
    }
    
    /// The scope to access baidu pan service. The default and only value is `basic,netdisk`.
    public override var scope: String {
        get { return "basic,netdisk" }
        set {  }
    }
}

// MARK: - BoxConnector
public class BoxConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return "https://account.box.com/api/oauth2/authorize"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.box.com/oauth2/token"
    }
    
    private var defaultScope = "root_readwrite"
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}

// MARK: - DropboxConnector
public class DropboxConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return "https://www.dropbox.com/oauth2/authorize?token_access_type=offline"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.dropbox.com/oauth2/token"
    }
}

// MARK: - GoogleDriveConnector
public class GoogleDriveConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return "https://accounts.google.com/o/oauth2/auth"
    }
    
    public override var accessTokenUrl: String {
        return "https://accounts.google.com/o/oauth2/token"
    }
    
    private var defaultScope = "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/userinfo.profile"
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}


// MARK: - OneDriveConnector
public class OneDriveConnector: CloudServiceConnector, @unchecked Sendable {

    public override var authorizeUrl: String {
        return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    }

    public override var accessTokenUrl: String {
        return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    }

    private var defaultScope = "offline_access User.Read Files.ReadWrite.All"
    /// The scope to access OneDrive service. The default value is `offline_access User.Read Files.ReadWrite.All`.
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}

// MARK: - PCloudConnector
public class PCloudConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return "https://my.pcloud.com/oauth2/authorize"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.pcloud.com/oauth2_token"
    }
    
    public override func renewToken(with refreshToken: String, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        // pCloud OAuth does not respond with a refresh token, so renewToken is unsupported.
        completion(.failure(CloudServiceError.unsupported))
    }
}

// MARK: - Drive115Connector
public class Drive115Connector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return ""
    }
    
    public override var accessTokenUrl: String {
        return ""
    }
    
    public override func renewToken(with refreshToken: String, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        Task {
            do {
                let payload = try await refreshAccessToken(refreshToken: refreshToken)
                let credential = OAuthSwiftCredential(consumerKey: self.appId, consumerSecret: "")
                credential.oauthToken = payload.accessToken
                credential.oauthRefreshToken = payload.refreshToken
                
                let success: OAuthSwift.TokenSuccess = (
                    credential: credential,
                    response: nil,
                    parameters: [:]
                )
                completion(.success(success))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public struct QRCode {
        public let uid: String
        public let qrcode: String
        public let sign: String
        public let time: Int64
    }
    
    public var codeVerifier: String?
    
    public var headers: [String: String] {
        ["Content-Type": "application/x-www-form-urlencoded"]
    }
    
    public func fetchAuthQRCode() async throws -> QRCode {
        let codeVerifier = try OAuthPKCE.generateCodeVerifier(byteCount: 32)
        self.codeVerifier = codeVerifier
        let codeChallenge = OAuthPKCE.codeChallenge(fromVerifier: codeVerifier)
        return try await generateDeviceCode(appId: appId, codeChallenge: codeChallenge)
    }
    public func generateDeviceCode(appId: String, codeChallenge: String) async throws -> QRCode {
        let url = URL(string: "https://passportapi.115.com/open/authDeviceCode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        var data = [String: Any]()
        data["client_id"] = appId
        data["code_challenge"] = codeChallenge
        data["code_challenge_method"] = "sha256"
        
        var parts: [String] = []
        for (key, val) in data {
            parts.append("\(key)=\(val)")
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid response")
        }
        
        let result = HTTPResult(data: responseData, response: httpResponse)
        if let object = result.json as? [String: Any],
           let dataObject = object["data"] as? [String: Any],
           let uid = dataObject["uid"] as? String,
           let qrcode = dataObject["qrcode"] as? String,
           let time = dataObject["time"] as? Int64,
           let sign = dataObject["sign"] as? String {
            return QRCode(uid: uid, qrcode: qrcode, sign: sign, time: time)
        } else {
            throw CloudServiceError.responseDecodeError(result)
        }
    }
    
    public struct AuthStatus {
        public let status: Int
        public let msg: String?
    }
    
    public func refreshAuthStatus(uid: String, time: Int64, sign: String) async throws -> AuthStatus {
        var comps = URLComponents(string: "https://qrcodeapi.115.com/get/status/")!
        comps.queryItems = [
            URLQueryItem(name: "uid", value: uid),
            URLQueryItem(name: "time", value: String(time)),
            URLQueryItem(name: "sign", value: sign)
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid response")
        }
        
        let result = HTTPResult(data: responseData, response: httpResponse)
        if let object = result.json as? [String: Any],
           let dataObject = object["data"] as? [String: Any],
           let status = dataObject["status"] as? Int {
            let msg = dataObject["msg"] as? String
            return AuthStatus(status: status, msg: msg)
        } else {
            throw CloudServiceError.responseDecodeError(result)
        }
    }
    
    public struct AccessTokenPayload {
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: Int
    }
    
    public func getAccessToken(uid: String, codeVerifier: String) async throws -> AccessTokenPayload {
        let url = URL(string: "https://passportapi.115.com/open/deviceCodeToToken")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        var data = [String: Any]()
        data["uid"] = uid
        data["code_verifier"] = codeVerifier
        
        var parts: [String] = []
        for (key, val) in data {
            parts.append("\(key)=\(val)")
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid response")
        }
        
        let result = HTTPResult(data: responseData, response: httpResponse)
        if let object = result.json as? [String: Any],
           let dataObject = object["data"] as? [String: Any],
           let accessToken = dataObject["access_token"] as? String,
           let refreshToken = dataObject["refresh_token"] as? String,
           let expires = dataObject["expires_in"] as? Int {
            return AccessTokenPayload(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expires)
        } else {
            throw CloudServiceError.responseDecodeError(result)
        }
    }
    
    public func refreshAccessToken(refreshToken: String) async throws -> AccessTokenPayload {
        let url = URL(string: "https://passportapi.115.com/open/refreshToken")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        var data = [String: Any]()
        data["refresh_token"] = refreshToken
        
        var parts: [String] = []
        for (key, val) in data {
            parts.append("\(key)=\(val)")
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid response")
        }
        
        let result = HTTPResult(data: responseData, response: httpResponse)
        if let object = result.json as? [String: Any],
           let dataObject = object["data"] as? [String: Any],
           let accessToken = dataObject["access_token"] as? String,
           let refreshToken = dataObject["refresh_token"] as? String,
           let expires = dataObject["expires_in"] as? Int {
            return AccessTokenPayload(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expires)
        } else {
            throw CloudServiceError.responseDecodeError(result)
        }
    }
}

/// PKCE helpers shared by OAuth connectors (RFC 7636).
enum OAuthPKCE {
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func generateCodeVerifier(byteCount: Int) throws -> String {
        var octets = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, octets.count, &octets)
        guard status == errSecSuccess else {
            throw CloudServiceError.serviceError(Int(status), "SecRandomCopyBytes failed")
        }
        return base64URLEncode(Data(octets))
    }

    static func codeChallenge(fromVerifier verifier: String) -> String {
        let verifierData = verifier.data(using: .ascii)!
        let challengeHashed = SHA256.hash(data: verifierData)
        return base64URLEncode(Data(challengeHashed))
    }
}

// MARK: - Drive123Connector

public class Drive123Connector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        "https://www.123pan.com/auth"
    }
    
    public override var accessTokenUrl: String {
        "https://open-api.123pan.com/api/v1/oauth2/access_token"
    }
    
    private var defaultScope = "user:base,file:all:read,file:all:write"
    /// The scope to access 123Pan service.
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}

// MARK: - WebDAVConnector

public class WebDAVConnector: CloudServiceConnector, @unchecked Sendable {
    
    public override var authorizeUrl: String {
        return ""
    }
    
    public override var accessTokenUrl: String {
        return ""
    }
    
    public override func connect(viewController: UIViewController) async throws -> CloudOAuthTokenResult {
        return CloudOAuthTokenResult(oauthToken: "webdav", oauthTokenSecret: "", oauthRefreshToken: "")
    }
    
    public override func connect(viewController: UIViewController, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        completion(.failure(CloudServiceError.unsupported))
    }
}

