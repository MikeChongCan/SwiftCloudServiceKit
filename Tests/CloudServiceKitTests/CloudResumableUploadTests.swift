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
}
