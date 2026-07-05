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
    
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        
        let credential = URLCredential(user: "user", password: "token", persistence: .none)
        provider = OneDriveServiceProvider(credential: credential)
    }
    
    override func tearDown() async throws {
        provider = nil
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
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

    func testBeginUploadUsesPathSyntaxAndMinimalBody() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("A001_07042151_C002.mov")
        try Data(repeating: 0xAB, count: 5 * 1024 * 1024).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Upload-Complete"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Upload-Draft-Interop-Version"))
            XCTAssertEqual(
                request.url?.path,
                "/v1.0/me/drive/items/folder-123:/A001_07042151_C002.mov:/createUploadSession"
            )

            if let body = request.httpBody ?? request.httpBodyStreamData(),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let item = json["item"] as? [String: Any] {
                XCTAssertEqual(item["@microsoft.graph.conflictBehavior"] as? String, "rename")
                XCTAssertNil(item["name"])
            } else {
                XCTFail("Missing createUploadSession JSON body")
            }

            let responseBody = """
            {"uploadUrl":"https://example.sharepoint.com/upload","expirationDateTime":"2026-07-06T00:00:00.000Z"}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody.data(using: .utf8))
        }

        let directory = CloudItem(id: "folder-123", name: "QCam", path: "/QCam", isDirectory: true)
        let session = try await provider.beginUpload(
            fileURL: fileURL,
            filename: "A001_07042151_C002.mov",
            to: directory,
            contentType: "video/quicktime"
        )

        XCTAssertEqual(session.provider, "OneDrive")
        XCTAssertEqual(session.filename, "A001_07042151_C002.mov")
        XCTAssertTrue(session.sessionToken.contains("example.sharepoint.com"))
    }
}
