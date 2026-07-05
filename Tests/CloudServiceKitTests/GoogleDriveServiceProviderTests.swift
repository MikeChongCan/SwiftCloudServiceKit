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
    
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        
        let credential = URLCredential(user: "user", password: "token", persistence: .none)
        provider = GoogleDriveServiceProvider(credential: credential)
    }
    
    override func tearDown() async throws {
        provider = nil
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
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
    
    func test_HTTPResult_headerLookupIsCaseInsensitive() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Location": "https://example.com/upload", "Content-Type": "application/json"]
        )!
        let result = HTTPResult(data: nil, response: response)
        
        XCTAssertEqual(result.header("Location"), "https://example.com/upload")
        XCTAssertEqual(result.header("location"), "https://example.com/upload")
        XCTAssertEqual(result.header("LOCATION"), "https://example.com/upload")
        XCTAssertEqual(result.header("Content-Type"), "application/json")
        XCTAssertEqual(result.header("content-type"), "application/json")
    }
    
    func test_GoogleDrive_uploadFile_extractsResumableLocation() async throws {
        var createSessionCalled = false
        var uploadChunkCalled = false
        
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("/files") == true && request.httpMethod == "POST" {
                createSessionCalled = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["location": "https://example.com/resumable-upload-url"]
                )!
                return (response, nil)
            } else if request.url?.absoluteString == "https://example.com/resumable-upload-url" {
                uploadChunkCalled = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                let jsonResponse = """
                {
                    "id": "file_id_123",
                    "name": "test.txt"
                }
                """
                return (response, jsonResponse.data(using: .utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!
            return (response, nil)
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "hello world".data(using: .utf8)?.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        let targetDirectory = CloudItem(id: "parent_id_456", name: "parent", path: "/parent")
        let response = try await provider.uploadFile(fileURL, to: targetDirectory, progressHandler: nil)
        
        XCTAssertTrue(createSessionCalled)
        XCTAssertTrue(uploadChunkCalled)
        if case .success(let result) = response.result {
            XCTAssertEqual(result.statusCode, 200)
        } else {
            XCTFail("Upload failed: \(response)")
        }
    }
}
