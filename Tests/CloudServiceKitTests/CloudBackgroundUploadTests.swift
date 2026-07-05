//
//  CloudBackgroundUploadTests.swift
//  CloudServiceKitTests
//

import XCTest
@testable import CloudServiceKit

final class CloudBackgroundUploadTests: XCTestCase {

    private func sampleSession(
        provider: String = CloudBackgroundUpload.ProviderName.googleDrive,
        uploadedBytes: Int64 = 0,
        totalBytes: Int64 = 10_000_000,
        sessionToken: String = "https://upload.example.com/session"
    ) -> CloudUploadSession {
        CloudUploadSession(
            provider: provider,
            fileURL: URL(fileURLWithPath: "/tmp/large.mov"),
            filename: "large.mov",
            directoryID: "folder-1",
            totalBytes: totalBytes,
            uploadedBytes: uploadedBytes,
            sessionToken: sessionToken
        )
    }

    // MARK: - Request builder

    func test_Google_chunkPlan_wholeRemainder() throws {
        let session = sampleSession(uploadedBytes: 0)
        let plan = try CloudBackgroundUpload.chunkUploadPlan(for: session, preferredLength: nil)

        XCTAssertEqual(plan.request.httpMethod, "PUT")
        XCTAssertEqual(plan.request.url?.absoluteString, session.sessionToken)
        XCTAssertNil(plan.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(plan.request.httpBody)
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-9999999/10000000")
        XCTAssertEqual(plan.fileRange, 0..<10_000_000)
    }

    func test_Google_chunkPlan_middleRange() throws {
        let session = sampleSession(uploadedBytes: 1_000_000)
        let plan = try CloudBackgroundUpload.chunkUploadPlan(for: session, preferredLength: 500_000)

        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Content-Range"), "bytes 1000000-1499999/10000000")
        XCTAssertEqual(plan.fileRange, 1_000_000..<1_500_000)
    }

    func test_OneDrive_chunkPlan_alignsTo320KiB() throws {
        let session = sampleSession(
            provider: CloudBackgroundUpload.ProviderName.oneDrive,
            uploadedBytes: 0,
            totalBytes: 20_000_000
        )
        let plan = try CloudBackgroundUpload.chunkUploadPlan(for: session, preferredLength: 4_000_000)

        let length = Int64(plan.fileRange.count)
        XCTAssertEqual(length % OneDriveUploadPolicy.kiB320, 0)
        XCTAssertLessThanOrEqual(length, OneDriveBackgroundUpload.maxFragmentSize)
        XCTAssertNil(plan.request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_OneDrive_chunkPlan_finalFragment() throws {
        let session = sampleSession(
            provider: CloudBackgroundUpload.ProviderName.oneDrive,
            uploadedBytes: 19_500_000,
            totalBytes: 20_000_000
        )
        let plan = try CloudBackgroundUpload.chunkUploadPlan(for: session, preferredLength: nil)

        XCTAssertEqual(plan.fileRange, 19_500_000..<20_000_000)
    }

    // MARK: - Parser

    func test_Google_parse308_progressed() {
        let session = sampleSession()
        let response = HTTPURLResponse(
            url: URL(string: session.sessionToken)!,
            statusCode: 308,
            httpVersion: nil,
            headerFields: ["Range": "bytes=0-1048575"]
        )!

        let outcome = CloudBackgroundUpload.parseChunkResponse(response, data: nil, for: session)
        guard case .progressed(let bytes) = outcome else {
            return XCTFail("Expected progressed, got \(outcome)")
        }
        XCTAssertEqual(bytes, 1_048_576)
    }

    func test_Google_parse201_completed() {
        let session = sampleSession()
        let data = #"{"id":"file-xyz","name":"large.mov"}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: session.sessionToken)!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        )!

        let outcome = CloudBackgroundUpload.parseChunkResponse(response, data: data, for: session)
        guard case .completed(let id) = outcome else {
            return XCTFail("Expected completed")
        }
        XCTAssertEqual(id, "file-xyz")
    }

    func test_OneDrive_parse202_progressed() {
        let session = sampleSession(provider: CloudBackgroundUpload.ProviderName.oneDrive)
        let data = #"{"nextExpectedRanges":["5242880-"]}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: session.sessionToken)!,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!

        let outcome = CloudBackgroundUpload.parseChunkResponse(response, data: data, for: session)
        guard case .progressed(let bytes) = outcome else {
            return XCTFail("Expected progressed")
        }
        XCTAssertEqual(bytes, 5_242_880)
    }

    func test_parse404_sessionExpired() {
        let session = sampleSession()
        let response = HTTPURLResponse(
            url: URL(string: session.sessionToken)!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!

        let outcome = CloudBackgroundUpload.parseChunkResponse(response, data: nil, for: session)
        guard case .sessionExpired = outcome else {
            return XCTFail("Expected sessionExpired")
        }
    }

    func test_parse429_retryable() {
        let session = sampleSession()
        let response = HTTPURLResponse(
            url: URL(string: session.sessionToken)!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "30"]
        )!

        let outcome = CloudBackgroundUpload.parseChunkResponse(response, data: nil, for: session)
        guard case .retryable(let seconds) = outcome else {
            return XCTFail("Expected retryable")
        }
        XCTAssertEqual(seconds, 30)
    }

    // MARK: - Resync

    func test_Google_queryUploadStatus_308() async throws {
        let session = sampleSession()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes */10000000")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 308,
                httpVersion: nil,
                headerFields: ["Range": "bytes=0-2097151"]
            )!
            return (response, nil)
        }

        let outcome = try await CloudBackgroundUpload.queryUploadStatus(session: session, urlSession: urlSession)
        guard case .progressed(let bytes) = outcome else {
            return XCTFail("Expected progressed")
        }
        XCTAssertEqual(bytes, 2_097_152)
    }

    func test_OneDrive_queryUploadStatus_nextExpectedRanges() async throws {
        let session = sampleSession(provider: CloudBackgroundUpload.ProviderName.oneDrive)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"nextExpectedRanges":["3932160-"]}"#.data(using: .utf8)!
            return (response, body)
        }

        let outcome = try await CloudBackgroundUpload.queryUploadStatus(session: session, urlSession: urlSession)
        guard case .progressed(let bytes) = outcome else {
            return XCTFail("Expected progressed")
        }
        XCTAssertEqual(bytes, 3_932_160)
    }

    func test_CloudUploadSession_decodesWithoutSchemaVersion() throws {
        let json = """
        {"provider":"GoogleDrive","fileURL":"file:///tmp/a.mov","filename":"a.mov","directoryID":"d","totalBytes":100,"uploadedBytes":0,"sessionToken":"https://u.example"}
        """
        let decoded = try JSONDecoder().decode(CloudUploadSession.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func test_FileRegionWriter_copiesBytes() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).bin")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dest-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        let payload = Data(repeating: 0xAB, count: 1024)
        try payload.write(to: source)
        try await FileRegionWriter.writeRegion(of: source, range: 100..<612, to: dest)

        let copied = try Data(contentsOf: dest)
        XCTAssertEqual(copied.count, 512)
        XCTAssertTrue(copied.allSatisfy { $0 == 0xAB })
    }
}
