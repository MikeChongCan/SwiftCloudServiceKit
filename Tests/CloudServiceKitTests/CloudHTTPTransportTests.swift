//
//  CloudHTTPTransportTests.swift
//  CloudServiceKitTests
//
//  Regression coverage for the upload-task body warning:
//  "The request of a upload task should not contain a body or a body stream."
//

import XCTest
@testable import CloudServiceKit

final class CloudHTTPTransportTests: XCTestCase {

    func test_uploadTaskRequest_stripsHTTPBody() {
        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(repeating: 0xAB, count: 512 * 1024)

        let uploadRequest = CloudHTTPTransport.uploadTaskRequest(strippingBodyFrom: request)

        // The request handed to the upload task must carry no body.
        XCTAssertNil(uploadRequest.httpBody)
        XCTAssertNil(uploadRequest.httpBodyStream)
        // Headers and method survive so the transfer is otherwise identical.
        XCTAssertEqual(uploadRequest.httpMethod, "PUT")
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(uploadRequest.url, request.url)
        // The original is untouched (the `data(for:)` fallback branch keeps its body).
        XCTAssertNotNil(request.httpBody)
    }

    func test_uploadTaskRequest_stripsHTTPBodyStream() {
        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data([0x01, 0x02, 0x03]))

        let uploadRequest = CloudHTTPTransport.uploadTaskRequest(strippingBodyFrom: request)

        XCTAssertNil(uploadRequest.httpBody)
        XCTAssertNil(uploadRequest.httpBodyStream)
        XCTAssertEqual(uploadRequest.httpMethod, "POST")
    }
}
