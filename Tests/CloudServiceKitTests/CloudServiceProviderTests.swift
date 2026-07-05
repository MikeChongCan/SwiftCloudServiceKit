//
//  CloudServiceProviderTests.swift
//  CloudServiceKitTests
//
//  Created by Antigravity on 2026/7/5.
//

import XCTest
@testable import CloudServiceKit

@MainActor
class MockServiceProvider: CloudServiceProvider {
    var session: URLSession = .shared
    var delegate: CloudServiceProviderDelegate?
    var name: String { "Mock" }
    var credential: URLCredential?
    var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    var rootItem: CloudItem { CloudItem(id: "root", name: "root", path: "/") }
    
    required init(credential: URLCredential?) {
        self.credential = credential
    }
    
    func attributesOfItem(_ item: CloudItem) async throws -> CloudItem { item }
    func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] { [] }
    func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        CloudSpaceInformation(totalSpace: 0, availableSpace: 0, json: [:])
    }
    func getCurrentUserInfo() async throws -> CloudUser {
        CloudUser(username: "", json: [:])
    }
    func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func searchFiles(keyword: String) async throws -> [CloudItem] { [] }
    func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    static func cloudItemFromJSON(_ json: [String: Any]) -> CloudItem? { nil }
    
    func testPost(url: URL, data: [String: Any]) async throws -> HTTPResult {
        let response = try await post(url: url, data: data)
        switch response.result {
        case .success(let res):
            return res
        case .failure(let err):
            throw err
        }
    }
    
    func testQuery(_ params: [String: Any]) -> String {
        return query(params)
    }
}

@MainActor
final class CloudServiceProviderTests: XCTestCase {
    
    private var provider: MockServiceProvider!
    
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let credential = URLCredential(user: "user", password: "old_token", persistence: .none)
        provider = MockServiceProvider(credential: credential)
    }
    
    override func tearDown() async throws {
        provider = nil
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        try await super.tearDown()
    }
    
    func test_401Retry_preservesPOSTBody() async throws {
        var attempts = 0
        var bodySentInSecondRequest: String?
        
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!
                return (response, nil)
            } else {
                if let bodyData = request.httpBodyStreamData() ?? request.httpBody {
                    bodySentInSecondRequest = String(data: bodyData, encoding: .utf8)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                return (response, "{}".data(using: .utf8))
            }
        }
        
        provider.refreshAccessTokenHandler = {
            return URLCredential(user: "user", password: "new_token", persistence: .none)
        }
        
        let result = try await provider.testPost(url: URL(string: "https://example.com/api")!, data: ["hello": "world"])
        
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(bodySentInSecondRequest, "hello=world")
    }
    
    func test_401Retry_stopsAfterOneAttempt() async throws {
        var attempts = 0
        
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!
            return (response, nil)
        }
        
        provider.refreshAccessTokenHandler = {
            return URLCredential(user: "user", password: "new_token", persistence: .none)
        }
        
        let result = try await provider.testPost(url: URL(string: "https://example.com/api")!, data: ["hello": "world"])
        XCTAssertEqual(result.statusCode, 401)
        XCTAssertEqual(attempts, 2) // Original attempt + 1 retry = 2 attempts total
    }
    
    func test_query_encodesReservedCharacters() {
        let params: [String: Any] = ["a": "hello world", "b": "foo&bar", "c": "1+2=3"]
        let queryString = provider.testQuery(params)
        
        // Assert keys/values are properly percent encoded according to RFC 3986
        XCTAssertTrue(queryString.contains("a=hello%20world") || queryString.contains("a=hello%22world"))
        XCTAssertTrue(queryString.contains("b=foo%26bar"))
        XCTAssertTrue(queryString.contains("c=1%2B2%3D3"))
    }
}

extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var data = Data()
        
        stream.open()
        defer { stream.close() }
        
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
