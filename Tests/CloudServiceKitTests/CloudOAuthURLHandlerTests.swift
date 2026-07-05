import CloudServiceKit
import XCTest

final class CloudOAuthURLHandlerTests: XCTestCase {
    func testGoogleRedirectIsRecognized() {
        let url = URL(string: "com.googleusercontent.apps.test:/oauth2redirect?code=abc")!
        XCTAssertTrue(CloudOAuthURLHandler.handle(url))
    }

    func testUnrelatedURLIsIgnored() {
        let url = URL(string: "qcam://import/script")!
        XCTAssertFalse(CloudOAuthURLHandler.handle(url))
    }
}
