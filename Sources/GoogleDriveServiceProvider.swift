//
//  GoogleDriveServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/9/13.
//

import Foundation

/*
 Developer documents can be found here: https://developers.google.com/drive/api/v3/reference/
 For iOS app setup and URL schemes, please refer to Docs/GoogleDrive.md.
 */
@MainActor
public final class GoogleDriveServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var name: String { return "GoogleDrive" }
    
    public var rootItem: CloudItem { return CloudItem(id: "root", name: name, path: "/") }
    
    public var credential: URLCredential?
    
    public var apiURL = URL(string: "https://www.googleapis.com/drive/v3")!
    
    public var uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public let session: URLSession
    
    public var sharedDrive: SharedDrive?
    
    public var contentsOfDirectoryQueryTerm: String = "trashed = false"
    
    public var contentsOfDirectoryFields: String = "nextPageToken, files(id, name, mimeType, size, createdTime, modifiedTime, md5Checksum, parents)"
    
    public let uploadChunkSize: Int64 = 6 * 1024 * 1024 // 6MB
    
    private var chunkSize: Int64 { uploadChunkSize }
    
    required public init(credential: URLCredential?) {
        self.credential = credential
        self.session = .shared
    }
    
    public init(credential: URLCredential?, session: URLSession) {
        self.credential = credential
        self.session = session
    }
    
    public struct SharedDrive: Codable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
    
    public struct MIMETypes {
        public static let folder = "application/vnd.google-apps.folder"
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        var params: [String: Any] = [:]
        params["fields"] = "id, name, mimeType, size, createdTime, modifiedTime, md5Checksum, parents"
        if let sharedDrive = sharedDrive {
            params["supportsAllDrives"] = true
            params["driveId"] = sharedDrive.id
            params["includeItemsFromAllDrives"] = true
        }
        
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let parsedItem = GoogleDriveServiceProvider.cloudItemFromJSON(json) {
            return parsedItem
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var pageToken: String?
        
        repeat {
            let url = apiURL.appendingPathComponent("files")
            var params: [String: Any] = [:]
            var q = contentsOfDirectoryQueryTerm
            q += " and '\(directory.id)' in parents"
            params["q"] = q
            params["fields"] = contentsOfDirectoryFields
            if let sharedDrive = sharedDrive {
                params["supportsAllDrives"] = true
                params["driveId"] = sharedDrive.id
                params["includeItemsFromAllDrives"] = true
                params["corpora"] = "drive"
            }
            if let token = pageToken {
                params["pageToken"] = token
            }
            
            let response = try await get(url: url, params: params)
            if let json = response.response?.json as? [String: Any], let files = json["files"] as? [[String: Any]] {
                let list = files.compactMap { GoogleDriveServiceProvider.cloudItemFromJSON($0) }
                items.append(contentsOf: list)
                pageToken = json["nextPageToken"] as? String
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
            }
        } while pageToken.map { !$0.isEmpty } ?? false
        
        for i in 0..<items.count {
            items[i].fixPath(with: directory)
        }
        return items
    }
    
    /// Copy item to directory
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        guard !item.isDirectory else {
            throw CloudServiceError.unsupported
        }
        let url = apiURL.appendingPathComponent("files/\(item.id)/copy")
        let data = ["parents": [directory.id]]
        return try await post(url: url, json: data)
    }
    
    /// Create folder at directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files")
        let data: [String: Any] = [
            "name": folderName,
            "mimeType": MIMETypes.folder,
            "parents": [directory.id]
        ]
        
        var params: [String: Any] = [:]
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        return try await post(url: url, params: params, json: data)
    }
    
    public func downloadableRequest(of item: CloudItem) -> URLRequest? {
        let url = apiURL.appendingPathComponent("files/\(item.id)").appendingQueryParameters(["alt": "media"])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        return request
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let url = apiURL.appendingPathComponent("files/\(fileId)").appendingQueryParameters(["alt": "media"])
        let response = try await get(url: url, progressHandler: { progress in
            let p = Progress(totalUnitCount: progress.bytesExpectedToProcess + progress.bytesProcessed)
            p.completedUnitCount = progress.bytesProcessed
            progressHandler?(p)
        })
        if let data = response.response?.content {
            return data
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func exportFile(_ item: CloudItem, mimeType: String) async throws -> Data {
        let url = apiURL.appendingPathComponent("files/\(item.id)/export")
        var params: [String: Any] = [:]
        params["mimeType"] = mimeType
        let response = try await get(url: url, params: params)
        if let data = response.response?.content {
            return data
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("about")
        let response = try await get(url: url, params: ["fields": "storageQuota"])
        if let json = response.response?.json as? [String: Any],
           let storageQuota = json["storageQuota"] as? [String: Any],
           let limitStr = storageQuota["limit"] as? String, let limit = Int64(limitStr),
           let usageStr = storageQuota["usage"] as? String, let usage = Int64(usageStr) {
            return CloudSpaceInformation(totalSpace: limit, availableSpace: limit - usage, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("about")
        let response = try await get(url: url, params: ["fields": "user"])
        guard let json = response.response?.json as? [String: Any] else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
        
        let userObject = json["user"] as? [String: Any] ?? [:]
        let name = userObject["displayName"] as? String ?? userObject["emailAddress"] as? String ?? ""
        return CloudUser(username: name, json: json)
    }
    
    public func listSharedDrives() async throws -> [SharedDrive] {
        var items: [SharedDrive] = []
        var pageToken: String?
        
        repeat {
            let url = apiURL.appendingPathComponent("sharedDrives")
            var params: [String: Any] = [:]
            params["fields"] = "nextPageToken, drives(id, name)"
            if let token = pageToken {
                params["pageToken"] = token
            }
            let response = try await get(url: url, params: params)
            if let json = response.response?.json as? [String: Any], let list = json["drives"] as? [[String: Any]] {
                for drive in list {
                    if let id = drive["id"] as? String, let name = drive["name"] as? String {
                        items.append(SharedDrive(id: id, name: name))
                    }
                }
                pageToken = json["nextPageToken"] as? String
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
            }
        } while pageToken.map { !$0.isEmpty } ?? false
        
        return items
    }
    
    public func getThumbnail(of item: CloudItem, size: Int = 200) async throws -> Data {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        let response = try await get(url: url, params: ["fields": "thumbnailLink"])
        if let json = response.response?.json as? [String: Any],
           let link = json["thumbnailLink"] as? String,
           let thumbUrl = URL(string: link) {
            let thumbResponse = try await get(url: thumbUrl)
            if let data = thumbResponse.response?.content {
                return data
            }
        }
        throw CloudServiceError.unsupported
    }
    
    public func getFileDownloadUrl(of item: CloudItem) async throws -> String {
        return apiURL.appendingPathComponent("files/\(item.id)").appendingQueryParameters(["alt": "media"]).absoluteString
    }
    
    /// Move item to target directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        
        var params: [String: Any] = [:]
        params["addParents"] = directory.id
        if let parents = item.json["parents"]?.value as? [String], let currentParent = parents.first {
            params["removeParents"] = currentParent
        }
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        
        return try await patch(url: url, params: params)
    }
    
    /// Remove cloud file/folder item.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        var params: [String: Any] = [:]
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        return try await delete(url: url, params: params)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        var params: [String: Any] = [:]
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        let json = ["name": newName]
        return try await patch(url: url, params: params, json: json)
    }
    
    /// Search files with provided keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("files")
        var params: [String: Any] = [:]
        let escapedKeyword = keyword.replacingOccurrences(of: "'", with: "\\'")
        params["q"] = "name contains '\(escapedKeyword)' and trashed = false"
        params["fields"] = contentsOfDirectoryFields
        if let sharedDrive = sharedDrive {
            params["supportsAllDrives"] = true
            params["driveId"] = sharedDrive.id
            params["includeItemsFromAllDrives"] = true
            params["corpora"] = "drive"
        }
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let files = json["files"] as? [[String: Any]] {
            return files.compactMap { GoogleDriveServiceProvider.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Upload file data to target directory.
    /// - Warning: Loads the entire payload into memory. For files larger than 4 MB, use `uploadFile` or `CloudResumableUploading` instead.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let url = uploadURL.appendingPathComponent("files")
        var params = ["uploadType": "multipart"]
        if sharedDrive != nil {
            params["supportsAllDrives"] = "true"
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var headers = ["Content-Type": "multipart/related; boundary=\(boundary)"]
        
        let json: [String: Any] = ["name": filename, "parents": [directory.id]]
        
        var body = Data()
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(json.json.data(using: .utf8)!)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        let length = Int64(body.count)
        let reportProgress = Progress(totalUnitCount: length)
        return try await post(url: url, params: params, headers: headers, requestBody: body, progressHandler: { progress in
            reportProgress.completedUnitCount = Int64(Float(length) * progress.percent)
            progressHandler?(reportProgress)
        })
    }
    
    /// Upload file to target directory with local file url.
    /// Note: remote file url is not supported.
    public func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        
        guard FileManager.default.fileExists(atPath: fileURL.path), let totalSize = fileSize(of: fileURL) else {
            throw CloudServiceError.uploadFileNotExist
        }
        
        let url = uploadURL.appendingPathComponent("files")
        var params: [String: Any] = ["uploadType": "resumable"]
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        let headers = [
            "X-Upload-Content-Type": "application/octet-stream",
            "X-Upload-Content-Length": "\(totalSize)",
            "Content-Type": "application/json; charset=UTF-8"
        ]
        let json: [String: Any] = ["name": fileURL.lastPathComponent, "parents": [directory.id]]
        let response = try await post(url: url, params: params, json: json, headers: headers)
        
        if let uploadUrl = response.response?.header("Location") {
            let uploadSession = UploadSession(fileURL: fileURL, size: totalSize, uploadUrl: uploadUrl)
            return try await uploadFileChunks(session: uploadSession, progressHandler: progressHandler)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
}

// MARK: - Resumable Upload
extension GoogleDriveServiceProvider: CloudResumableUploading {
    
    public func beginUpload(
        fileURL: URL,
        filename: String,
        to directory: CloudItem,
        contentType: String? = nil
    ) async throws -> CloudUploadSession {
        guard FileManager.default.fileExists(atPath: fileURL.path), let totalSize = fileSize(of: fileURL) else {
            throw CloudServiceError.uploadFileNotExist
        }
        
        let url = uploadURL.appendingPathComponent("files")
        var params: [String: Any] = ["uploadType": "resumable"]
        if sharedDrive != nil {
            params["supportsAllDrives"] = true
        }
        var headers: [String: String] = [
            "X-Upload-Content-Type": contentType ?? "application/octet-stream",
            "X-Upload-Content-Length": "\(totalSize)",
            "Content-Type": "application/json; charset=UTF-8"
        ]
        let json: [String: Any] = ["name": filename, "parents": [directory.id]]
        let response = try await post(url: url, params: params, json: json, headers: headers)
        
        guard let uploadUrl = response.response?.header("Location") else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
        
        return CloudUploadSession(
            provider: name,
            fileURL: fileURL,
            filename: filename,
            directoryID: directory.id,
            totalBytes: totalSize,
            sessionToken: uploadUrl
        )
    }
    
    public func uploadChunk(
        session: inout CloudUploadSession,
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> CloudUploadSession {
        guard !session.isComplete else { return session }
        
        let offset = session.uploadedBytes
        let length = min(chunkSize, session.totalBytes - offset)
        let data = try await FileChunkReader.readChunk(from: session.fileURL, offset: offset, length: Int(length))
        
        var headers: [String: String] = [:]
        headers["Content-Length"] = "\(length)"
        headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(session.totalBytes)"
        headers["Content-Type"] = "application/octet-stream"
        
        let progressReport = Progress(totalUnitCount: session.totalBytes)
        let response = try await put(url: session.sessionToken, headers: headers, requestBody: data, progressHandler: { progress in
            progressReport.completedUnitCount = offset + Int64(Float(length) * progress.percent)
            progressHandler?(progressReport)
        })
        
        session.uploadedBytes = offset + length
        
        if session.isComplete, let json = response.response?.json as? [String: Any], let id = json["id"] as? String {
            session.remoteFileID = id
        }
        
        return session
    }
    
    public func finishUpload(session: CloudUploadSession) async throws -> CloudItem {
        if let remoteFileID = session.remoteFileID {
            return try await attributesOfItem(CloudItem(id: remoteFileID, name: session.filename, path: session.filename))
        }
        throw CloudServiceError.responseDecodeError(HTTPResult())
    }
    
    private func uploadFileChunks(
        session: UploadSession,
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> CloudResponse<HTTPResult, Error> {
        var offset = Int64(0)
        var lastResponse: CloudResponse<HTTPResult, Error>?
        let progressReport = Progress(totalUnitCount: session.size)
        
        while offset < session.size {
            let length = min(chunkSize, session.size - offset)
            let chunkOffset = offset
            let data = try await FileChunkReader.readChunk(from: session.fileURL, offset: chunkOffset, length: Int(length))
            
            var headers: [String: String] = [:]
            headers["Content-Length"] = "\(length)"
            headers["Content-Range"] = "bytes \(chunkOffset)-\(chunkOffset + length - 1)/\(session.size)"
            headers["Content-Type"] = "application/octet-stream"
            
            let response = try await put(url: session.uploadUrl, headers: headers, requestBody: data, progressHandler: { progress in
                progressReport.completedUnitCount = chunkOffset + Int64(Float(length) * progress.percent)
                progressHandler?(progressReport)
            })
            lastResponse = response
            offset = chunkOffset + length
        }
        
        return lastResponse ?? CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
}

// MARK: - Background Upload
extension GoogleDriveServiceProvider: CloudBackgroundUploading {
    public nonisolated func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64? = nil
    ) throws -> UploadChunkPlan {
        try GoogleDriveBackgroundUpload.chunkUploadPlan(for: session, preferredLength: preferredLength)
    }

    public nonisolated func parseChunkResponse(
        _ response: HTTPURLResponse,
        data: Data?,
        for session: CloudUploadSession
    ) -> UploadChunkOutcome {
        GoogleDriveBackgroundUpload.parseChunkResponse(response, data: data, for: session)
    }

    public func queryUploadStatus(session: CloudUploadSession) async throws -> UploadChunkOutcome {
        try await GoogleDriveBackgroundUpload.queryUploadStatus(session: session, urlSession: self.session)
    }
}

// MARK: - CloudServiceResponseProcessing
extension GoogleDriveServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let name = json["name"] as? String, let id = json["id"] as? String else {
            return nil
        }
        let mimeType = json["mimeType"] as? String
        let isDirectory = mimeType == MIMETypes.folder
        var item = CloudItem(id: id, name: name, path: name, isDirectory: isDirectory, json: json)
        if let size = json["size"] as? Int64 {
            item.size = size
        } else if let size = json["size"] as? String {
            item.size = Int64(size) ?? -1
        }
        item.fileHash = json["md5Checksum"] as? String
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let createdTime = json["createdTime"] as? String {
            item.creationDate = dateFormatter.date(from: createdTime)
        }
        if let modifiedTime = json["modifiedTime"] as? String {
            item.modificationDate = dateFormatter.date(from: modifiedTime)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let error = json["error"] as? [String: Any], !error.isEmpty {
            let code = (json["code"] as? Int) ?? (error["code"] as? Int) ?? response.statusCode ?? 400
            let msg = (json["message"] as? String) ?? (error["message"] as? String)
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(code, msg))))
            return true
        }
        return false
    }
}

fileprivate final class UploadSession: Sendable {
    let fileURL: URL
    let size: Int64
    let uploadUrl: String
    
    init(fileURL: URL, size: Int64, uploadUrl: String) {
        self.fileURL = fileURL
        self.size = size
        self.uploadUrl = uploadUrl
    }
}

fileprivate extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
