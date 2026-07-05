//
//  CloudBackgroundUpload.swift
//  CloudServiceKit
//
//  Pure request/response helpers for host-owned background URLSession uploads.
//

import Foundation

// MARK: - Chunk plan

/// Describes one background `URLSession.uploadTask(with:fromFile:)` transfer.
public struct UploadChunkPlan: Sendable {
    /// PUT to `session.sessionToken` with `Content-Range` set. No HTTP body — the host supplies bytes via `fromFile:`.
    public let request: URLRequest
    /// Byte range of the source file to copy into a temp file for the upload task.
    public let fileRange: Range<Int64>

    public init(request: URLRequest, fileRange: Range<Int64>) {
        self.request = request
        self.fileRange = fileRange
    }
}

// MARK: - Chunk outcome

/// Result of a completed background upload task or a server-side status probe.
public enum UploadChunkOutcome: Sendable {
    case progressed(uploadedBytes: Int64)
    case completed(remoteFileID: String)
    case sessionExpired
    case retryable(afterSeconds: TimeInterval?)
    case terminal(CloudServiceError)
}

// MARK: - Protocol

/// Providers that expose pure chunk planning and response parsing for background `URLSession`.
@MainActor
public protocol CloudBackgroundUploading: CloudResumableUploading {
    /// Build the next chunk request for a persisted session.
    nonisolated func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64?
    ) throws -> UploadChunkPlan

    /// Interpret a delegate callback response after a background upload task completes.
    nonisolated func parseChunkResponse(
        _ response: HTTPURLResponse,
        data: Data?,
        for session: CloudUploadSession
    ) -> UploadChunkOutcome

    /// Ask the server how many bytes were received (call after relaunch before the next chunk).
    func queryUploadStatus(session: CloudUploadSession) async throws -> UploadChunkOutcome
}

// MARK: - Shared helpers

public enum CloudBackgroundUpload: Sendable {
    public enum ProviderName {
        public static let googleDrive = "GoogleDrive"
        public static let oneDrive = "OneDrive"
    }

    public static func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64? = nil
    ) throws -> UploadChunkPlan {
        switch session.provider {
        case ProviderName.googleDrive:
            return try GoogleDriveBackgroundUpload.chunkUploadPlan(for: session, preferredLength: preferredLength)
        case ProviderName.oneDrive:
            return try OneDriveBackgroundUpload.chunkUploadPlan(for: session, preferredLength: preferredLength)
        default:
            throw CloudServiceError.unsupported
        }
    }

    public static func parseChunkResponse(
        _ response: HTTPURLResponse,
        data: Data?,
        for session: CloudUploadSession
    ) -> UploadChunkOutcome {
        switch session.provider {
        case ProviderName.googleDrive:
            return GoogleDriveBackgroundUpload.parseChunkResponse(response, data: data, for: session)
        case ProviderName.oneDrive:
            return OneDriveBackgroundUpload.parseChunkResponse(response, data: data, for: session)
        default:
            return .terminal(.unsupported)
        }
    }

    public static func queryUploadStatus(
        session: CloudUploadSession,
        urlSession: URLSession = .shared
    ) async throws -> UploadChunkOutcome {
        switch session.provider {
        case ProviderName.googleDrive:
            return try await GoogleDriveBackgroundUpload.queryUploadStatus(session: session, urlSession: urlSession)
        case ProviderName.oneDrive:
            return try await OneDriveBackgroundUpload.queryUploadStatus(session: session, urlSession: urlSession)
        default:
            throw CloudServiceError.unsupported
        }
    }
}

// MARK: - File region helper

public enum FileRegionWriter: Sendable {
    /// Copies `range` from `source` into `destination` (overwriting). For background upload temp files.
    public static func writeRegion(of source: URL, range: Range<Int64>, to destination: URL) async throws {
        try await Task { @concurrent in
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = handle.readData(ofLength: range.count)
            guard data.count == range.count else {
                throw CloudServiceError.uploadFileNotExist
            }
            try data.write(to: destination, options: .atomic)
        }.value
    }
}

// MARK: - Google Drive

enum GoogleDriveBackgroundUpload: Sendable {
    static func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64?
    ) throws -> UploadChunkPlan {
        guard let uploadURL = URL(string: session.sessionToken) else {
            throw CloudServiceError.responseDecodeError(HTTPResult())
        }
        let offset = session.uploadedBytes
        let remainder = session.totalBytes - offset
        guard remainder > 0 else {
            throw CloudServiceError.unsupported
        }

        let length: Int64
        if let preferred = preferredLength, preferred > 0 {
            length = min(preferred, remainder)
        } else {
            length = remainder
        }

        let end = offset + length - 1
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(length)", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(offset)-\(end)/\(session.totalBytes)", forHTTPHeaderField: "Content-Range")

        return UploadChunkPlan(request: request, fileRange: offset..<(offset + length))
    }

    static func parseChunkResponse(
        _ response: HTTPURLResponse,
        data: Data?,
        for session: CloudUploadSession
    ) -> UploadChunkOutcome {
        let status = response.statusCode

        if status == 404 || status == 410 {
            return .sessionExpired
        }
        if status == 429 {
            return .retryable(afterSeconds: retryAfterSeconds(from: response))
        }
        if (500...599).contains(status) {
            return .retryable(afterSeconds: retryAfterSeconds(from: response))
        }

        if status == 308 {
            if let uploaded = uploadedBytesFromRangeHeader(response.value(forHTTPHeaderField: "Range")) {
                return .progressed(uploadedBytes: uploaded)
            }
            return .terminal(.responseDecodeError(HTTPResult(data: data, response: response)))
        }

        if status == 200 || status == 201 {
            if let id = remoteFileID(from: data) {
                return .completed(remoteFileID: id)
            }
            return .terminal(.responseDecodeError(HTTPResult(data: data, response: response)))
        }

        if status == 401 || status == 403 {
            return .terminal(.serviceError(status, "Upload not authorized"))
        }

        return .terminal(.serviceError(status, HTTPURLResponse.localizedString(forStatusCode: status)))
    }

    static func queryUploadStatus(
        session: CloudUploadSession,
        urlSession: URLSession
    ) async throws -> UploadChunkOutcome {
        guard let uploadURL = URL(string: session.sessionToken) else {
            throw CloudServiceError.responseDecodeError(HTTPResult())
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(session.totalBytes)", forHTTPHeaderField: "Content-Range")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid HTTP response")
        }
        return parseChunkResponse(http, data: data, for: session)
    }
}

// MARK: - OneDrive

enum OneDriveBackgroundUpload: Sendable {
    /// Microsoft Graph maximum fragment size per upload session request.
    static let maxFragmentSize: Int64 = 60 * 1024 * 1024

    static func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64?
    ) throws -> UploadChunkPlan {
        guard let uploadURL = URL(string: session.sessionToken) else {
            throw CloudServiceError.responseDecodeError(HTTPResult())
        }
        let offset = session.uploadedBytes
        let remainder = session.totalBytes - offset
        guard remainder > 0 else {
            throw CloudServiceError.unsupported
        }

        let length = oneDriveFragmentLength(
            remainder: remainder,
            preferred: preferredLength ?? OneDriveUploadPolicy.chunkSize
        )

        let end = offset + length - 1
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(length)", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(offset)-\(end)/\(session.totalBytes)", forHTTPHeaderField: "Content-Range")

        return UploadChunkPlan(request: request, fileRange: offset..<(offset + length))
    }

    static func oneDriveFragmentLength(remainder: Int64, preferred: Int64) -> Int64 {
        var length = min(max(preferred, OneDriveUploadPolicy.kiB320), remainder, maxFragmentSize)
        if remainder > length {
            length = (length / OneDriveUploadPolicy.kiB320) * OneDriveUploadPolicy.kiB320
            if length == 0 {
                length = min(OneDriveUploadPolicy.kiB320, remainder)
            }
        }
        return length
    }

    static func parseChunkResponse(
        _ response: HTTPURLResponse,
        data: Data?,
        for session: CloudUploadSession
    ) -> UploadChunkOutcome {
        let status = response.statusCode

        if status == 404 || status == 410 {
            return .sessionExpired
        }
        if status == 429 {
            return .retryable(afterSeconds: retryAfterSeconds(from: response))
        }
        if (500...599).contains(status) {
            return .retryable(afterSeconds: retryAfterSeconds(from: response))
        }

        if status == 202 {
            if let uploaded = uploadedBytesFromNextExpectedRanges(data) {
                return .progressed(uploadedBytes: uploaded)
            }
            return .terminal(.responseDecodeError(HTTPResult(data: data, response: response)))
        }

        if status == 200 || status == 201 {
            if let id = remoteFileID(from: data) {
                return .completed(remoteFileID: id)
            }
            return .terminal(.responseDecodeError(HTTPResult(data: data, response: response)))
        }

        if status == 401 || status == 403 {
            return .terminal(.serviceError(status, "Upload not authorized"))
        }

        return .terminal(.serviceError(status, HTTPURLResponse.localizedString(forStatusCode: status)))
    }

    static func queryUploadStatus(
        session: CloudUploadSession,
        urlSession: URLSession
    ) async throws -> UploadChunkOutcome {
        guard let uploadURL = URL(string: session.sessionToken) else {
            throw CloudServiceError.responseDecodeError(HTTPResult())
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudServiceError.serviceError(-1, "Invalid HTTP response")
        }

        if http.statusCode == 404 || http.statusCode == 410 {
            return .sessionExpired
        }

        if let uploaded = uploadedBytesFromNextExpectedRanges(data) {
            if uploaded >= session.totalBytes, let id = remoteFileID(from: data) {
                return .completed(remoteFileID: id)
            }
            return .progressed(uploadedBytes: uploaded)
        }

        return parseChunkResponse(http, data: data, for: session)
    }
}

// MARK: - Parsing utilities

private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = TimeInterval(value) {
        return seconds
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: value) {
        return max(0, date.timeIntervalSinceNow)
    }
    return nil
}

private func uploadedBytesFromRangeHeader(_ rangeHeader: String?) -> Int64? {
    guard let rangeHeader else { return nil }
    // bytes=0-1048575
    let trimmed = rangeHeader.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("bytes=") else { return nil }
    let spec = String(trimmed.dropFirst("bytes=".count))
    let part = spec.split(separator: ",").first.map(String.init) ?? spec
    let bounds = part.split(separator: "-")
    guard bounds.count == 2, let end = Int64(bounds[1]) else { return nil }
    return end + 1
}

private func uploadedBytesFromNextExpectedRanges(_ data: Data?) -> Int64? {
    guard let data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ranges = json["nextExpectedRanges"] as? [String],
          let first = ranges.first else {
        return nil
    }
    // "5242880-" or "5242880-10485759"
    let start = first.split(separator: "-").first.flatMap { Int64($0) }
    return start
}

private func remoteFileID(from data: Data?) -> String? {
    guard let data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id"] as? String else {
        return nil
    }
    return id
}
