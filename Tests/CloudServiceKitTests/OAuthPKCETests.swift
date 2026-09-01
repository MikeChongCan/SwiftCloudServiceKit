//
//  OAuthPKCETests.swift
//  CloudServiceKitTests
//

import XCTest
@testable import CloudServiceKit

final class OAuthPKCETests: XCTestCase {

    /// RFC 7636 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
    private let pkceUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func test_codeChallenge_matchesRFC7636AppendixBExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(OAuthPKCE.codeChallenge(fromVerifier: verifier), expectedChallenge)
    }

    func test_base64URLEncode_usesURLSafeAlphabetWithoutPadding() {
        let encoded = OAuthPKCE.base64URLEncode(Data([0xFB, 0xFF, 0xFE]))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func test_generateCodeVerifier_isRFC7636LengthAndCharset() throws {
        let verifier = try OAuthPKCE.generateCodeVerifier(byteCount: 32)
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { pkceUnreserved.contains($0) })
    }
}

@MainActor
final class CloudServiceConnectorPKCETests: XCTestCase {

    func test_oneDriveAuthorizeURL_includesPKCEChallenge() {
        let connector = OneDriveConnector(
            appId: "client-id",
            appSecret: "",
            callbackUrl: "qcam://oauth/onedrive"
        )
        XCTAssertTrue(connector.usesPKCE)
    }

    func test_googleDriveAuthorizeURL_omitsPKCEChallenge() {
        let connector = GoogleDriveConnector(
            appId: "client-id",
            appSecret: "secret",
            callbackUrl: "com.googleusercontent.apps.test:/oauth2redirect"
        )
        XCTAssertFalse(connector.usesPKCE)
    }
}
