//
//  OAuthPKCETests.swift
//  CloudServiceKitTests
//

import XCTest
@testable import CloudServiceKit

final class OAuthPKCETests: XCTestCase {

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

    func test_generateCodeVerifier_producesExpectedLength() throws {
        let verifier = try OAuthPKCE.generateCodeVerifier(byteCount: 32)
        // 32 raw bytes → 43 base64url characters (no padding)
        XCTAssertEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
        XCTAssertFalse(verifier.contains("="))
    }
}
