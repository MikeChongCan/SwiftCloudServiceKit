//
//  GoogleDriveServiceProviderTests.swift
//  CloudServiceKitTests
//
//  Created by Antigravity on 2026/7/5.
//

import XCTest
@testable import CloudServiceKit

@MainActor
final class GoogleDriveServiceProviderTests: XCTestCase {
    
    private var provider: GoogleDriveServiceProvider!
    private var originalSession: URLSession!
    
    override func setUp() async throws {
        try await super.setUp()
        originalSession = Just.adaptor.session
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        Just.adaptor.session = URLSession(configuration: configuration, delegate: Just.adaptor, delegateQueue: nil)
        
        let credential = URLCredential(user: "user", password: "token", persistence: .none)
        provider = GoogleDriveServiceProvider(credential: credential)
    }
    
    override func tearDown() async throws {
        provider = nil
        Just.adaptor.session = originalSession
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }
    
    func testGetCurrentUserInfo() async throws {
        let jsonResponse = """
        {
            "user": {
                "displayName": "Test Google User",
                "emailAddress": "test@gmail.com"
            }
        }
        """
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse.data(using: .utf8))
        }
        
        let user = try await provider.getCurrentUserInfo()
        XCTAssertEqual(user.username, "Test Google User")
    }
    
    func testContentsOfDirectory() async throws {
        let jsonResponse = """
        {
            "files": [
                {
                    "id": "file-123",
                    "name": "document.pdf",
                    "mimeType": "application/pdf",
                    "size": "500000"
                }
            ]
        }
        """
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse.data(using: .utf8))
        }
        
        let directory = CloudItem(id: "root-dir", name: "root", path: "/root-dir", isDirectory: true)
        let items = try await provider.contentsOfDirectory(directory)
        
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "file-123")
        XCTAssertEqual(items.first?.name, "document.pdf")
        XCTAssertFalse(items.first!.isDirectory)
        XCTAssertEqual(items.first?.size, 500000)
    }
}
