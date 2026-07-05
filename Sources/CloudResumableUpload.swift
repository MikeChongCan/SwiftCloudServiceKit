//
//  CloudResumableUpload.swift
//  CloudServiceKit
//
//  Persistable resumable upload session state and protocol for large file uploads.
//

import Foundation

/// Snapshot of an in-progress resumable upload. Persist to JSON to resume after app restart.
public struct CloudUploadSession: Codable, Sendable, Equatable {
    /// Schema version for on-disk persistence. Additive evolution only; defaults to 1 when absent.
    public let schemaVersion: Int
    public let provider: String
    public let fileURL: URL
    public let filename: String
    public let directoryID: String
    public let totalBytes: Int64
    public var uploadedBytes: Int64
    /// Provider-specific session URL or token (Google Drive Location header, OneDrive uploadUrl).
    public var sessionToken: String
    public var remoteFileID: String?
    public var expiresAt: Date?
    
    public var isComplete: Bool {
        uploadedBytes >= totalBytes
    }
    
    public init(
        provider: String,
        fileURL: URL,
        filename: String,
        directoryID: String,
        totalBytes: Int64,
        uploadedBytes: Int64 = 0,
        sessionToken: String,
        remoteFileID: String? = nil,
        expiresAt: Date? = nil,
        schemaVersion: Int = CloudUploadSession.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.fileURL = fileURL
        self.filename = filename
        self.directoryID = directoryID
        self.totalBytes = totalBytes
        self.uploadedBytes = uploadedBytes
        self.sessionToken = sessionToken
        self.remoteFileID = remoteFileID
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, fileURL, filename, directoryID, totalBytes
        case uploadedBytes, sessionToken, remoteFileID, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        provider = try container.decode(String.self, forKey: .provider)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        filename = try container.decode(String.self, forKey: .filename)
        directoryID = try container.decode(String.self, forKey: .directoryID)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        uploadedBytes = try container.decodeIfPresent(Int64.self, forKey: .uploadedBytes) ?? 0
        sessionToken = try container.decode(String.self, forKey: .sessionToken)
        remoteFileID = try container.decodeIfPresent(String.self, forKey: .remoteFileID)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

extension CloudUploadSession {
    /// Current schema version for persisted upload sessions. Bump only with additive Codable fields.
    public static let currentSchemaVersion = 1
}

/// Providers that support chunked, resumable uploads from a local file URL.
@MainActor
public protocol CloudResumableUploading: CloudServiceProvider {
    /// Recommended chunk size in bytes for this provider (respects API constraints).
    var uploadChunkSize: Int64 { get }
    
    /// Start a resumable upload session. Persist the returned value before uploading chunks.
    func beginUpload(
        fileURL: URL,
        filename: String,
        to directory: CloudItem,
        contentType: String?
    ) async throws -> CloudUploadSession
    
    /// Upload the next chunk from `session.uploadedBytes`. Updates `session.uploadedBytes` on success.
    func uploadChunk(
        session: inout CloudUploadSession,
        progressHandler: (@Sendable (Progress) -> Void)?
    ) async throws -> CloudUploadSession
    
    /// Upload all remaining chunks until complete.
    func uploadAllChunks(
        session: inout CloudUploadSession,
        progressHandler: (@Sendable (Progress) -> Void)?
    ) async throws -> CloudUploadSession
    
    /// Return the remote item after all bytes are uploaded.
    func finishUpload(session: CloudUploadSession) async throws -> CloudItem
    
    /// Best-effort cancel of an in-progress upload session.
    func cancelUpload(session: CloudUploadSession) async throws
}

extension CloudResumableUploading {
    public func uploadAllChunks(
        session: inout CloudUploadSession,
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> CloudUploadSession {
        var current = session
        while !current.isComplete {
            current = try await uploadChunk(session: &current, progressHandler: progressHandler)
        }
        session = current
        return current
    }
    
    public func cancelUpload(session: CloudUploadSession) async throws {
        // Default: no remote cleanup required.
    }
}

/// Reads file chunks off the main actor to avoid blocking UI during large uploads.
enum FileChunkReader: Sendable {
    static func readChunk(from fileURL: URL, offset: Int64, length: Int) async throws -> Data {
        try await Task { @concurrent in
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return handle.readData(ofLength: length)
        }.value
    }
}

/// OneDrive requires chunk sizes that are multiples of 320 KiB.
enum OneDriveUploadPolicy {
    static let kiB320: Int64 = 327_680
    static let chunkSize: Int64 = kiB320 * 12
}
