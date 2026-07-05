//
//  DropboxServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/8/11.
//

import Foundation

/*
 https://www.dropbox.com/developers/documentation/http/documentation
 For iOS app setup and URL schemes, please refer to Docs/Dropbox.md.
 */
@MainActor
public final class DropboxServiceProvider: CloudServiceProvider {

    public var delegate: CloudServiceProviderDelegate?
    
    /// The name of service provider.
    public var name: String { return "Dropbox" }
    
    public var rootItem: CloudItem { return CloudItem(id: "0", name: name, path: "") }
    
    public var credential: URLCredential?
    
    public var apiURL = URL(string: "https://api.dropboxapi.com/2")!
    
    public var contentURL = URL(string: "https://content.dropboxapi.com/2")!
    
    /// The refresh access token handler. Used to refresh access token when the token expires.
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public let session: URLSession
    
    /// Create an instance of DropboxServiceProvider with URLCredential
    /// - Parameter credential: The URLCredential.
    required public init(credential: URLCredential?) {
        self.credential = credential
        self.session = .shared
    }
    
    public init(credential: URLCredential?, session: URLSession) {
        self.credential = credential
        self.session = session
    }
    
    /// Load the contents at directory.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("files/list_folder")
        var json: [String: Any] = [:]
        json["path"] = directory.path
        json["recursive"] = false
        
        let response = try await post(url: url, json: json)
        if let jsonObject = response.response?.json as? [String: Any], let list = jsonObject["entries"] as? [[String: Any]] {
            var items = list.compactMap { DropboxServiceProvider.cloudItemFromJSON($0) }
            for i in 0..<items.count {
                items[i].fixPath(with: directory)
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get metadata for a file or folder.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = apiURL.appendingPathComponent("files/get_metadata")
        var json: [String: Any] = [:]
        json["path"] = item.path
        json["include_media_info"] = true
        json["include_deleted"] = false
        json["include_has_explicit_shared_members"] = false
        
        let response = try await post(url: url, json: json)
        if let object = response.response?.json as? [String: Any], let parsedItem = DropboxServiceProvider.cloudItemFromJSON(object) {
            return parsedItem
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Copy a file or folder to a different location in the user's Dropbox.
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/copy_v2")
        var json: [String: Any] = [:]
        json["from_path"] = item.path
        json["to_path"] = directory.path
        return try await post(url: url, json: json)
    }
    
    /// Create a folder at a given directory.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/create_folder_v2")
        var json: [String: Any] = [:]
        json["path"] = [directory.path, folderName].joined(separator: "/")
        json["autorename"] = true
        return try await post(url: url, json: json)
    }
    
    public func downloadData(item: CloudItem, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let url = contentURL.appendingPathComponent("files/download")
        let headers = ["Dropbox-API-Arg": dropboxAPIArg(from: ["path": item.path])]
        
        let response = try await post(url: url, headers: headers, progressHandler: { progress in
            let p = Progress(totalUnitCount: progress.bytesExpectedToProcess + progress.bytesProcessed)
            p.completedUnitCount = progress.bytesProcessed
            progressHandler?(p)
        })
        
        if let data = response.response?.content, !data.isEmpty {
            return data
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get the space usage information for the current user's account.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#users-get_space_usage
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("users/get_space_usage")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any],
           let used = json["used"] as? Int64,
           let allocation = json["allocation"] as? [String: Any],
           let total = allocation["allocated"] as? Int64 {
           return CloudSpaceInformation(totalSpace: total, availableSpace: total - used, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get information about the current user's account.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#users-get_current_account
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("users/get_current_account")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any],
           let nameObject = json["name"] as? [String: Any],
           let name = nameObject["display_name"] as? String {
            return CloudUser(username: name, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get a temporary link to stream content of a file. This link will expire in four hours and afterwards you will get 410 Gone.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-get_temporary_link
    public func getTemporaryLink(item: CloudItem) async throws -> URL {
        let url = apiURL.appendingPathComponent("files/get_temporary_link")
        let json = ["path": item.path]
        let response = try await post(url: url, json: json)
        if let object = response.response?.json as? [String: Any], let link = object["link"] as? String, let url = URL(string: link) {
            return url
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }

    /// Delete the file or folder.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-delete
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/delete_v2")
        let json = ["path": item.path]
        return try await post(url: url, json: json)
    }
    
    /// Rename the file or folder to a new name.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-move
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/move_v2")
        var components = item.path.components(separatedBy: "/").dropLast()
        components.append(newName)
        let toPath = components.joined(separator: "/")
        
        var json: [String: Any] = [:]
        json["from_path"] = item.path
        json["to_path"] = toPath
        json["autorename"] = true
        return try await post(url: url, json: json)
    }
    
    /// Move the file or folder to a new directory.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-move
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/move_v2")
        
        var components = item.path.components(separatedBy: "/")
        let filename = components.removeLast()
        let toPath = [directory.path, filename].joined(separator: "/")
        
        var json: [String: Any] = [:]
        json["from_path"] = item.path
        json["to_path"] = toPath
        json["autorename"] = true
        return try await post(url: url, json: json)
    }
    
    /// Searches for files and folders
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-search
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("files/search_v2")
        var json: [String: Any] = [:]
        json["query"] = keyword
        json["options"] = ["path": rootItem.path]
        
        let response = try await post(url: url, json: json)
        if let jsonObject = response.response?.json as? [String: Any], let list = jsonObject["matches"] as? [Any] {
            var items: [CloudItem] = []
            for entry in list {
                if let metadata = entry as? [String: Any],
                   let metadataObj = metadata["metadata"] as? [String: Any],
                   let object = metadataObj["metadata"] as? [String: Any],
                   let item = DropboxServiceProvider.cloudItemFromJSON(object) {
                    items.append(item)
                }
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Create a new file with the contents provided in the request.
    /// Document can be found here: https://www.dropbox.com/developers/documentation/http/documentation#files-upload
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        
        // data can not bigger than 150M
        if data.count > 150 * 1024 * 1024 {
            throw CloudServiceError.unsupported
        }
        
        let url = contentURL.appendingPathComponent("files/upload")
        
        var dict: [String: Any] = [:]
        dict["path"] = [directory.path, filename].joined(separator: "/")
        dict["mode"] = "add"
        dict["autorename"] = true
        dict["mute"] = false
        let headers = [
            "Dropbox-API-Arg": dropboxAPIArg(from: dict),
            "Content-Type": "application/octet-stream"
        ]
    
        let length = Int64(data.count)
        let reportProgress = Progress(totalUnitCount: length)
        return try await post(url: url, headers: headers, requestBody: data, progressHandler: { progress in
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
        
        let url = contentURL.appendingPathComponent("files/upload_session/start")
        var headers: [String: String] = [:]
        headers["Dropbox-API-Arg"] = "{\"close\": false}"
        headers["Content-Type"] = "application/octet-stream"
        
        let response = try await post(url: url, headers: headers)
        if let json = response.response?.json as? [String: Any],
           let sessionId = json["session_id"] as? String {
            return try await appendUploadSession(fileURL: fileURL, to: directory, totalSize: totalSize, sessionId: sessionId, progressHandler: progressHandler)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
}

// MARK: - Helper
extension DropboxServiceProvider {
    
    public func dropboxAPIArg(from dictionary: [String: Any]) -> String {
        return dictionary.json.asciiEscaped().replacingOccurrences(of: "\\/", with: "/")
    }
    
}

// MARK: - Chunk upload
extension DropboxServiceProvider {
    
    private func appendUploadSession(fileURL: URL, to directory: CloudItem, totalSize: Int64, sessionId: String, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        // upload_session/append:2 call must be multiple of 4194304 bytes (except for last)
        let chunkSize: Int64 = 4194304 * 2
        var offset: Int64 = 0
        let progressReport = Progress(totalUnitCount: totalSize)
        
        while offset < totalSize {
            let length = min(chunkSize, totalSize - offset)
            let chunkOffset = offset
            let data = try await FileChunkReader.readChunk(from: fileURL, offset: chunkOffset, length: Int(length))
            
            let url = contentURL.appendingPathComponent("files/upload_session/append_v2")
            
            var args: [String: Any] = [:]
            args["close"] = chunkOffset + length >= totalSize
            args["cursor"] = [
                "session_id": sessionId,
                "offset": chunkOffset
            ]
            
            let headers = [
                "Dropbox-API-Arg": dropboxAPIArg(from: args),
                "Content-Type": "application/octet-stream"
            ]
            
            _ = try await post(url: url, headers: headers, requestBody: data, progressHandler: { progress in
                progressReport.completedUnitCount = chunkOffset + Int64(Float(length) * progress.percent)
                progressHandler?(progressReport)
            })
            
            offset = chunkOffset + length
        }
        
        let path = [directory.path, fileURL.lastPathComponent].joined(separator: "/")
        return try await finishSession(sessionId, path: path, offset: totalSize)
    }
    
    private func finishSession(_ sessionId: String, path: String, offset: Int64) async throws -> CloudResponse<HTTPResult, Error> {
        let url = contentURL.appendingPathComponent("files/upload_session/finish")
        
        var args: [String: Any] = [:]
        args["commit"] = [
            "path": path,
            "mode": "add",
            "autorename": true,
            "mute": false,
            "strict_conflict": false
        ]
        args["cursor"] = [
            "session_id": sessionId,
            "offset": offset
        ]
        let headers = [
            "Dropbox-API-Arg": dropboxAPIArg(from: args),
            "Content-Type": "application/octet-stream"
        ]
        return try await post(url: url, headers: headers)
    }
}

// MARK: - CloudServiceResponseProcessing
extension DropboxServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String: Any]) -> CloudItem? {
        
        guard let name = json["name"] as? String, let path = json["path_display"] as? String else {
            return nil
        }
        let id = (json["id"] as? String) ?? "" // id:abcd1234
        let isDirectory = (json[".tag"] as? String) == "folder"
        var item = CloudItem(id: id, name: name, path: path, isDirectory: isDirectory, json: json)
        item.size = (json["size"] as? Int64) ?? -1
        item.fileHash = json["content_hash"] as? String
        
        if let modified = json["client_modified"] as? String {
            let dateFormatter = ISO8601DateFormatter()
            item.modificationDate = dateFormatter.date(from: modified)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        // https://developers.dropbox.com/error-handling-guide
        guard let json = response.json as? [String: Any] else { return false }
        if let error = json["error"] as? [String: Any], !error.isEmpty {
            let msg = (json["user_message"] as? String) ?? (json["error_summary"] as? String)
            let code = response.statusCode ?? 400
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(code, msg))))
            return true
        }
        return false
    }
}

// MARK: - CloudServiceBatching
extension DropboxServiceProvider: CloudServiceBatching {
    
    public func removeItems(_ items: [CloudItem]) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/delete_batch")
        let entries = items.map { ["path": $0.path] }
        let data = ["entries": entries]
        return try await post(url: url, data: data)
    }
    
    public func moveItems(_ items: [CloudItem], to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("files/move_batch_v2")
        let entries = items.map { item -> [String: String] in
            var components = item.path.components(separatedBy: "/")
            let filename = components.removeLast()
            let toPath = [directory.path, filename].joined(separator: "/")
            return ["from_path": item.path, "to_path": toPath]
        }
        let data: [String: Any] = [
            "entries": entries,
            "autorename": true
        ]
        return try await post(url: url, json: data)
    }
}
