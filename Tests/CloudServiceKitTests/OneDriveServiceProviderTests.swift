//
//  OneDriveServiceProviderTests.swift
//  CloudServiceKitTests
//
//  Created by Antigravity on 2026/7/5.
//

import XCTest
@testable import CloudServiceKit

@MainActor
final class OneDriveServiceProviderTests: XCTestCase {
    
    private var provider: OneDriveServiceProvider!
    private var originalSession: URLSession!
    
    override func setUp() async throws {
        try await super.setUp()
        originalSession = Just.adaptor.session
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        Just.adaptor.session = URLSession(configuration: configuration, delegate: Just.adaptor, delegateQueue: nil)
        
        let credential = URLCredential(user: "user", password: "token", persistence: .none)
        provider = OneDriveServiceProvider(credential: credential)
    }
    
    override func tearDown() async throws {
        provider = nil
        Just.adaptor.session = originalSession
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }
    
    func testContentsOfDirectory() async throws {
        let jsonResponse = """
        {
            "value": [
                {
                    "id": "file-456",
                    "name": "presentation.pptx",
                    "size": 2048000,
                    "file": {
                        "hashes": {
                            "sha1Hash": "789abc"
                        }
                    }
                }
            ]
        }
        """
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1.0/me/drive/root/children")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse.data(using: .utf8))
        }
        
        let directory = CloudItem(id: "root", name: "root", path: "/", isDirectory: true)
        let items = try await provider.contentsOfDirectory(directory)
        
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "file-456")
        XCTAssertEqual(items.first?.name, "presentation.pptx")
        XCTAssertFalse(items.first!.isDirectory)
        XCTAssertEqual(items.first?.size, 2048000)
    }
}
