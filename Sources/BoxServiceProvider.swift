//
//  BoxServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/8/9.
//

import Foundation
import CryptoKit

/*
 A Wrapper of box Service.
 Developer documents can be found here: https://developer.box.com/reference/
 */
@MainActor
public final class BoxServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    /// The name of service provider.
    public var name: String { return "Box" }
    
    /// The root folder of Box service. You can use this property to list root items.
    public var rootItem: CloudItem { return CloudItem(id: "0", name: name, path: "/") }
    
    public var credential: URLCredential?
    
    /// The api url of box service. Which is https://api.box.com/2.0 .
    public var apiURL = URL(string: "https://api.box.com/2.0")!
    
    /// The upload url of box service. Which is https://upload.box.com/api/2.0 .
    private var uploadURL = URL(string: "https://upload.box.com/api/2.0")!
    
    /// The refresh access token handler. Used to refresh access token when the token expires.
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    required public init(credential: URLCredential?) {
        self.credential = credential
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let path = item.isDirectory ? "folders": "files"
        let url = apiURL.appendingPathComponent("\(path)/\(item.id)")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let parsedItem = BoxServiceProvider.cloudItemFromJSON(json) {
            return parsedItem
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
 
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("folders/\(directory.id)/items")
        var params: [String: Any] = [:]
        params["fields"] = "id,type,name,size,created_at,modified_at,sha1"
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let entries = json["entries"] as? [[String: Any]] {
            var items = entries.compactMap { BoxServiceProvider.cloudItemFromJSON($0) }
            for i in 0..<items.count {
                items[i].fixPath(with: directory)
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }

    /// Copy item to directory
    /// Document can be found here:
    /// https://developer.box.com/reference/post-files-id-copy/
    /// https://developer.box.com/reference/post-folders-id-copy/
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let path = item.isDirectory ? "folders": "files"
        let url = apiURL.appendingPathComponent("\(path)/\(item.id)/copy")
        var json: [String: Any] = [:]
        json["parent"] = ["id": directory.id]
        return try await post(url: url, json: json)
    }
    
    /// Create folder at directory.
    /// Document can be found here: https://developer.box.com/reference/post-folders/
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("folders")
        let json: [String: Any] = [
            "name": folderName,
            "parent": ["id": directory.id]
        ]
        return try await post(url: url, json: json)
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        // Box does not provide simple space usage API in standard client scopes easily.
        // We will return unsupported or fetch user allocation.
        throw CloudServiceError.unsupported
    }
    
    /// Get information about the current user's account.
    /// Document can be found here: https://developer.box.com/reference/get-users-me/
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("users/me")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
           let name = json["name"] as? String {
            return CloudUser(username: name, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func downloadRequest(of item: CloudItem) -> URLRequest? {
        let url = apiURL.appendingPathComponent("files/\(item.id)/content")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        return request
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let url = apiURL.appendingPathComponent("files/\(fileId)/content")
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
    
    public func getFileDownloadUrl(of item: CloudItem) async throws -> String {
        let url = apiURL.appendingPathComponent("files/\(item.id)")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let downloadUrl = json["download_url"] as? String {
            return downloadUrl
        }
        return apiURL.appendingPathComponent("files/\(item.id)/content").absoluteString
    }
    
    public func getThumbnail(of item: CloudItem, extension ext: String = "png") async throws -> Data {
        let url = apiURL.appendingPathComponent("files/\(item.id)/thumbnail.\(ext)")
        let response = try await get(url: url)
        if let data = response.response?.content {
            return data
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Move item to target directory.
    /// Document can be found here: https://developer.box.com/reference/put-files-id/
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let path = item.isDirectory ? "folders": "files"
        let url = apiURL.appendingPathComponent("\(path)/\(item.id)")
        let json = ["parent": ["id": directory.id]]
        return try await put(url: url, json: json)
    }
    
    /// Remove cloud file/folder item.
    /// Document can be found here:
    /// Folder: https://developer.box.com/reference/delete-folders-id/
    /// File: https://developer.box.com/reference/delete-files-id/
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let path = item.isDirectory ? "folders": "files"
        let url = apiURL.appendingPathComponent("\(path)/\(item.id)")
        return try await delete(url: url)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let path = item.isDirectory ? "folders": "files"
        let url = apiURL.appendingPathComponent("\(path)/\(item.id)")
        let json = ["name": newName]
        return try await put(url: url, json: json)
    }
    
    /// Search files with provided keyword.
    /// Document can be found here: https://developer.box.com/reference/get-search/
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("search")
        var params: [String: Any] = [:]
        params["query"] = keyword
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let entries = json["entries"] as? [[String: Any]] {
            return entries.compactMap { BoxServiceProvider.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Upload file data to target directory.
    /// Document can be found here: https://developer.box.com/reference/post-files-content/
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        
        let url = uploadURL.appendingPathComponent("files/content")
        let file = HTTPFile.data(filename, data, "application/octet-stream")
        let attributes: [String: Any] = [
            "name": filename,
            "parent": ["id": directory.id]
        ]
        
        var dict: [String: Any] = [:]
        dict["attributes"] = attributes.json
        
        let length = Int64(data.count)
        let reportProgress = Progress(totalUnitCount: length)
        return try await post(url: url, data: dict, files: ["file": file], progressHandler: { progress in
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
        
        // Chunked upload for files larger than 20MB
        if totalSize > 20 * 1024 * 1024 {
            let url = apiURL.appendingPathComponent("files/upload_sessions")
            let json: [String: Any] = [
                "folder_id": directory.id,
                "file_name": fileURL.lastPathComponent,
                "file_size": totalSize
            ]
            let response = try await post(url: url, json: json)
            if let content = response.response?.content,
               let session = try? JSONDecoder().decode(UploadSession.self, from: content) {
                return try await uploadPart(session: session, fileURL: fileURL, totalSize: totalSize, offset: 0, progressHandler: progressHandler)
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
            }
        } else {
            let data = try Data(contentsOf: fileURL)
            return try await uploadData(data, filename: fileURL.lastPathComponent, to: directory, progressHandler: progressHandler)
        }
    }
}

// MARK: - Chunk Upload
extension BoxServiceProvider {
    
    private func uploadPart(session: UploadSession, fileURL: URL, totalSize: Int64, offset: Int64, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let length = min(Int64(session.partSize), totalSize - offset)
        let handle = try FileHandle(forReadingFrom: fileURL)
        try handle.seek(toOffset: UInt64(offset))
        let data = handle.readData(ofLength: Int(length))
        let sha1 = Insecure.SHA1.hash(data: data).toBase64()
        try handle.close()
        
        let url = uploadURL
            .appendingPathComponent("files/upload_sessions")
            .appendingPathComponent(session.id)
        var headers: [String: String] = [:]
        headers["Content-Range"] = String(format: "bytes %ld-%ld/%ld", offset, offset + length - 1, totalSize)
        headers["Digest"] = "sha=\(sha1)"
        headers["Content-Type"] = "application/octet-stream"
        
        let progressReport = Progress(totalUnitCount: totalSize)
        let response = try await put(url: url, headers: headers, requestBody: data, progressHandler: { progress in
            progressReport.completedUnitCount = offset + Int64(Float(length) * progress.percent)
            progressHandler?(progressReport)
        })
        
        if let content = response.response?.content,
           let part = (try? JSONDecoder().decode(UploadPart.self, from: content))?.part {
            session.parts.append(part)
            let nextOffset = part.offset + part.size
            if nextOffset >= totalSize {
                return try await commitUploadSession(session, fileURL: fileURL)
            } else {
                return try await uploadPart(session: session, fileURL: fileURL, totalSize: totalSize, offset: nextOffset, progressHandler: progressHandler)
            }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    private func commitUploadSession(_ session: UploadSession, fileURL: URL) async throws -> CloudResponse<HTTPResult, Error> {
        let url = uploadURL.appendingPathComponent("files/upload_sessions")
            .appendingPathComponent(session.id)
            .appendingPathComponent("commit")
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        let bufferSize = 1024 * 1024
        var sha1 = Insecure.SHA1()

        var loop = true
        while loop {
            try autoreleasepool {
                let data = fileHandle.readData(ofLength: bufferSize)
                if data.count > 0 {
                    sha1.update(data: data)
                } else {
                    loop = false
                }
            }
        }
        let sha1Hash = sha1.finalize().toBase64()
        let headers = ["Digest": "sha=\(sha1Hash)"]
        let json = ["parts": session.parts.map { $0.toJSON() }]
        return try await post(url: url, json: json, headers: headers)
    }
    
}

// MARK: - CloudServiceResponseProcessing
extension BoxServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else {
            return nil
        }
        let isDirectory = (json["type"] as? String) == "folder"
        var item = CloudItem(id: id, name: name, path: name, isDirectory: isDirectory, json: json)
        item.size = (json["size"] as? NSNumber)?.int64Value ?? -1
        item.fileHash = json["sha1"] as? String
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let modified = json["modified_at"] as? String {
            item.modificationDate = dateFormatter.date(from: modified)
        }
        if let createdat = json["created_at"] as? String {
            item.creationDate = dateFormatter.date(from: createdat)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        // https://developer.box.com/reference/resources/client-error/
        guard let json = response.json as? [String: Any] else { return false }
        if let type = json["type"] as? String, type == "error" {
            let msg = json["message"] as? String
            let code = response.statusCode ?? 400
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(code, msg))))
            return true
        }
        return false
    }
}

fileprivate final class UploadSession: Codable, @unchecked Sendable {
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case numberOfProcessedParts = "num_parts_processed"
        case partSize = "part_size"
        case endPoints = "session_endpoints"
        case sessionExpiresAt = "session_expires_at"
        case totalParts = "total_parts"
    }
    
    struct EndPoint: Codable {
        enum CodingKeys: String, CodingKey {
            case abort
            case commit
            case listParts = "list_parts"
            case logEvent = "log_event"
            case status
            case uploadPart = "upload_part"
        }
        let abort: String?
        let commit: String?
        let listParts: String?
        let logEvent: String?
        let status: String?
        let uploadPart: String?
    }
    
    let id: String
    let type: String
    let numberOfProcessedParts: Int
    let partSize: Int
    let endPoints: EndPoint
    let sessionExpiresAt: String
    let totalParts: Int
    
    var parts: [UploadPart.Part] = []
}

fileprivate final class UploadPart: Codable, @unchecked Sendable {
    struct Part: Codable {
        enum CodingKeys: String, CodingKey {
            case offset
            case partId = "part_id"
            case sha1
            case size
        }
        let offset: Int64
        let partId: String
        let sha1: String
        let size: Int64
        
        func toJSON() -> [String: Any] {
            return [
                "part_id": partId,
                "offset": offset,
                "sha1": sha1,
                "size": size
            ]
        }
    }
    let part: Part
}
