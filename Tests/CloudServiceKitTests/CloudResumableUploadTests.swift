//
//  CloudResumableUploadTests.swift
//  CloudServiceKitTests
//

import XCTest
@testable import CloudServiceKit

@MainActor
final class CloudResumableUploadTests: XCTestCase {
    
    func test_CloudUploadSession_JSONRoundTrip() throws {
        let session = CloudUploadSession(
            provider: "GoogleDrive",
            fileURL: URL(fileURLWithPath: "/tmp/large.mov"),
            filename: "large.mov",
            directoryID: "parent-123",
            totalBytes: 4_000_000_000,
            uploadedBytes: 8_388_608,
            sessionToken: "https://example.com/upload",
            remoteFileID: "file-abc",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CloudUploadSession.self, from: data)
        
        XCTAssertEqual(decoded, session)
        XCTAssertFalse(decoded.isComplete)
    }
    
    func test_OneDrive_chunkSize_is320KiBAligned() {
        XCTAssertEqual(OneDriveUploadPolicy.chunkSize % OneDriveUploadPolicy.kiB320, 0)
        XCTAssertEqual(OneDriveUploadPolicy.chunkSize, 327_680 * 12)
    }
    
    func test_OneDrive_cloudItemFromJSON_extractsSha1Hash() {
        let json: [String: Any] = [
            "id": "item-1",
            "name": "video.mov",
            "size": 1024,
            "file": [
                "hashes": [
                    "sha1Hash": "abc123"
                ]
            ]
        ]

        let item = OneDriveServiceProvider.cloudItemFromJSON(json)
        XCTAssertEqual(item?.fileHash, "abc123")
    }

    func test_OneDrive_shouldApplyAuthorization_skipsUploadHost() {
        let provider = OneDriveServiceProvider(credential: nil)
        let uploadURL = URL(string: "https://my.microsoftpersonalcontent.com/personal/user/_api/v2.0/drive/items/abc/uploadSession?tempauth=v1")!
        XCTAssertFalse(provider.shouldApplyAuthorization(to: uploadURL))
        let graphURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root")!
        XCTAssertTrue(provider.shouldApplyAuthorization(to: graphURL))
    }

    func test_OneDrive_parseChunkResponse_202_progresses() {
        let json = #"{"nextExpectedRanges":["3932160-"]}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://upload.example/session")!,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = CloudUploadSession(
            provider: "OneDrive",
            fileURL: URL(fileURLWithPath: "/tmp/video.mov"),
            filename: "video.mov",
            directoryID: "dir",
            totalBytes: 10_000_000,
            sessionToken: "https://upload.example/session"
        )
        let outcome = OneDriveBackgroundUpload.parseChunkResponse(response, data: json, for: session)
        if case .progressed(let uploaded) = outcome {
            XCTAssertEqual(uploaded, 3_932_160)
        } else {
            XCTFail("Expected progressed, got \(outcome)")
        }
    }

    func test_OneDrive_parseChunkResponse_409_isRetryable() {
        let response = HTTPURLResponse(
            url: URL(string: "https://upload.example/session")!,
            statusCode: 409,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = CloudUploadSession(
            provider: "OneDrive",
            fileURL: URL(fileURLWithPath: "/tmp/video.mov"),
            filename: "video.mov",
            directoryID: "dir",
            totalBytes: 10_000_000,
            sessionToken: "https://upload.example/session"
        )
        let outcome = OneDriveBackgroundUpload.parseChunkResponse(response, data: nil, for: session)
        if case .retryable(let delay) = outcome {
            XCTAssertEqual(delay, 2)
        } else {
            XCTFail("Expected retryable, got \(outcome)")
        }
    }
}
