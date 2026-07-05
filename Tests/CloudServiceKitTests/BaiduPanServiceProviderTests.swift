//
//  BaiduPanServiceProviderTests.swift
//  CloudServiceKitTests
//

import XCTest
@testable import CloudServiceKit

@MainActor
final class BaiduPanServiceProviderTests: XCTestCase {
    
    private var provider: BaiduPanServiceProvider!
    
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        provider = BaiduPanServiceProvider(credential: URLCredential(user: "user", password: "test_token", persistence: .none))
    }
    
    override func tearDown() async throws {
        provider = nil
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        try await super.tearDown()
    }
    
    func test_BaiduPan_requestsIncludeAccessToken() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("access_token=test_token") == true)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {"list": [], "errno": 0}
            """
            return (response, body.data(using: .utf8))
        }
        
        let directory = CloudItem(id: "0", name: "root", path: "/", isDirectory: true)
        _ = try await provider.contentsOfDirectory(directory)
    }
}
