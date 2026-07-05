//
//  WebDAVServiceProviderTests.swift
//  CloudServiceKitTests
//
//  Created by Antigravity on 2026/7/5.
//

import XCTest
@testable import CloudServiceKit

@MainActor
final class WebDAVServiceProviderTests: XCTestCase {
    
    private var provider: WebDAVServiceProvider!
    private var session: URLSession!
    
    override func setUp() async throws {
        try await super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        
        let endpoint = URL(string: "http://localhost/dav/")!
        let credential = URLCredential(user: "user", password: "password", persistence: .none)
        provider = WebDAVServiceProvider(endpoint: endpoint, credential: credential, session: session)
    }
    
    override func tearDown() async throws {
        provider = nil
        session = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }
    
    func testGetCurrentUserInfo() async throws {
        let user = try await provider.getCurrentUserInfo()
        XCTAssertEqual(user.username, "user")
    }
    
    func testGetCloudSpaceInformation() async throws {
        let info = try await provider.getCloudSpaceInformation()
        XCTAssertEqual(info.totalSpace, 0)
        XCTAssertEqual(info.availableSpace, 0)
    }
    
    func testContentsOfDirectory() async throws {
        let xmlResponse = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
            <D:response>
                <D:href>/dav/folder1/</D:href>
                <D:propstat>
                    <D:prop>
                        <D:resourcetype><D:collection/></D:resourcetype>
                        <D:getlastmodified>Thu, 01 Jan 1970 00:00:00 GMT</D:getlastmodified>
                    </D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
            <D:response>
                <D:href>/dav/folder1/file1.txt</D:href>
                <D:propstat>
                    <D:prop>
                        <D:resourcetype/>
                        <D:getcontentlength>1234</D:getcontentlength>
                        <D:getlastmodified>Thu, 01 Jan 1970 00:00:00 GMT</D:getlastmodified>
                        <D:getetag>"abcdef"</D:getetag>
                    </D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
        </D:multistatus>
        """
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 207,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/xml"]
            )!
            return (response, xmlResponse.data(using: .utf8))
        }
        
        let directory = CloudItem(id: "/dav/folder1", name: "folder1", path: "/dav/folder1", isDirectory: true)
        let items = try await provider.contentsOfDirectory(directory)
        
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "file1.txt")
        XCTAssertEqual(items.first?.path, "/dav/folder1/file1.txt")
        XCTAssertFalse(items.first!.isDirectory)
    }
    
    func testCreateFolder() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "MKCOL")
            XCTAssertEqual(request.url?.path, "/dav/folder1/new_subfolder")
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, nil)
        }
        
        let parent = CloudItem(id: "/dav/folder1", name: "folder1", path: "/dav/folder1", isDirectory: true)
        let response = try await provider.createFolder("new_subfolder", at: parent)
        
        switch response.result {
        case .success:
            XCTAssertNotNil(response.response)
        case .failure(let error):
            XCTFail("Expected success but got error: \(error)")
        }
    }
    
    func testRemoveItem() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/dav/folder1/file1.txt")
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, nil)
        }
        
        let item = CloudItem(id: "/dav/folder1/file1.txt", name: "file1.txt", path: "/dav/folder1/file1.txt", isDirectory: false)
        let response = try await provider.removeItem(item)
        
        switch response.result {
        case .success:
            XCTAssertNotNil(response.response)
        case .failure(let error):
            XCTFail("Expected success but got error: \(error)")
        }
    }
    
    func testGetFileData() async throws {
        let expectedData = "Hello WebDAV!".data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/dav/folder1/file1.txt")
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, expectedData)
        }
        
        let item = CloudItem(id: "/dav/folder1/file1.txt", name: "file1.txt", path: "/dav/folder1/file1.txt", isDirectory: false)
        let data = try await provider.getFileData(item)
        XCTAssertEqual(data, expectedData)
    }
    
    func test_WebDAV_endpointWithBasePath_isPreserved() async throws {
        let customEndpoint = URL(string: "https://cloud.example.com/remote.php/dav/files/alice/")!
        let customCredential = URLCredential(user: "alice", password: "password", persistence: .none)
        let customProvider = WebDAVServiceProvider(endpoint: customEndpoint, credential: customCredential, session: session)
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://cloud.example.com/remote.php/dav/files/alice/folder1/file1.txt")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, nil)
        }
        
        let item = CloudItem(id: "folder1/file1.txt", name: "file1.txt", path: "folder1/file1.txt", isDirectory: false)
        let response = try await customProvider.removeItem(item)
        if case .failure(let error) = response.result {
            XCTFail("Request failed: \(error)")
        }
    }
}
