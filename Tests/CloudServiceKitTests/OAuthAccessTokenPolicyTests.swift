import XCTest
@testable import CloudServiceKit

final class OAuthAccessTokenPolicyTests: XCTestCase {
    func testNeedsRefreshWhenInsideBuffer() {
        let expiresAt = Date().addingTimeInterval(60)
        XCTAssertTrue(OAuthAccessTokenPolicy.needsRefresh(expiresAt: expiresAt))
    }

    func testDoesNotNeedRefreshWhenOutsideBuffer() {
        let expiresAt = Date().addingTimeInterval(30 * 60)
        XCTAssertFalse(OAuthAccessTokenPolicy.needsRefresh(expiresAt: expiresAt))
    }

    func testShouldRefreshAfterUnauthorizedWhenMissingExpiry() {
        XCTAssertTrue(OAuthAccessTokenPolicy.shouldRefreshAfterUnauthorized(expiresAt: nil))
    }

    func testShouldNotRefreshAfterUnauthorizedWhenTokenStillValid() {
        let expiresAt = Date().addingTimeInterval(30 * 60)
        XCTAssertFalse(OAuthAccessTokenPolicy.shouldRefreshAfterUnauthorized(expiresAt: expiresAt))
    }
}
