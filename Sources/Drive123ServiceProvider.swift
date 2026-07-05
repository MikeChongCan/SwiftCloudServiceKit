//
//  Drive123ServiceProvider.swift
//
//
//  Created by alexiscn on 2025/2/16.
//

import Foundation
import CryptoKit

/// Drive123ServiceProvider
/// https://123yunpan.yuque.com/org-wiki-123yunpan-muaork/cr6ced
@MainActor
public final class Drive123ServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public var name: String { return "123Pan" }
    
    public var credential: URLCredential?
    
    public var rootItem: CloudItem { return CloudItem(id: "0", name: name, path: "/") }
    
    /// Upload chunsize which is 10M.
    public let chunkSize: Int64 = 10 * 1024 * 1024
    
    public var apiURL = URL(string: "https://open-api.123pan.com")!
    
    public let session: URLSession
    
    private var headers: [String: String] {
        return ["Platform": "open_platform"]
    }
    
    fileprivate static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh-CN")
        return formatter
    }()
    
    public required init(credential: URLCredential?) {
        self.credential = credential
        self.session = .shared
    }
    
    public init(credential: URLCredential?, session: URLSession) {
        self.credential = credential
        self.session = session
    }
    
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = apiURL.appendingPathComponent("/api/v1/file/detail")
        var params = [String: Any]()
        params["fileID"] = item.id
        let response = try await get(url: url, params: params, headers: headers)
        if let object = response.response?.json as? [String: Any], let file = Self.cloudItemFromJSON(object) {
            return file
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var lastId: Int?
        var loadMore = true
        
        while loadMore {
            var json: [String: Any] = [:]
            json["limit"] = 100
            json["parentFileId"] = directory.id
            if let lastFileId = lastId {
                json["lastFileId"] = lastFileId
            }
            let url = apiURL.appendingPathComponent("/api/v2/file/list")
            let response = try await get(url: url, params: json, headers: headers)
            if let object = response.response?.json as? [String: Any], let data = object["data"] as? [String: Any],
               let list = data["fileList"] as? [[String: Any]] {
                let files = list.compactMap { Self.cloudItemFromJSON($0) }
                items.append(contentsOf: files)
                
                if let nextId = data["lastFileId"] as? Int, nextId > 0 {
                    lastId = nextId
                } else {
                    loadMore = false
                }
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
            }
        }
        
        for i in 0..<items.count {
            items[i].fixPath(with: directory)
        }
        return items
    }
    
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        throw CloudServiceError.unsupported
    }
    
    /// Create a folder at a given directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/upload/v1/file/mkdir")
        var json: [String: Any] = [:]
        json["parentID"] = directory.id
        json["name"] = folderName
        return try await post(url: url, json: json, headers: headers)
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("/api/v1/user/info")
        let response = try await get(url: url, headers: headers)
        if let json = response.response?.json as? [String: Any],
           let totalSize = json["spacePermanent"] as? Int64,
           let usedSize = json["spaceUsed"] as? Int64 {
            return CloudSpaceInformation(totalSpace: totalSize, availableSpace: totalSize - usedSize, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get information about the current user's account.
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("/api/v1/user/info")
        let response = try await get(url: url, headers: headers)
        if let json = response.response?.json as? [String: Any], let username = json["nickname"] as? String {
            return CloudUser(username: username, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func downloadRequest(item: CloudItem) async throws -> URLRequest {
        let url = try await getDownloadUrl(of: item)
        return URLRequest(url: url)
    }
    
    public func mediaRequest(item: CloudItem) async throws -> URLRequest {
        let url = try await getDownloadUrl(of: item, parameters: [:])
        return URLRequest(url: url)
    }
    
    /// Move file to directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/api/v1/file/move")
        var json = [String: Any]()
        json["fileIDs"] = [item.id]
        json["toParentFileID"] = directory.id
        return try await post(url: url, json: json, headers: headers)
    }
    
    /// Remove file/folder.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/api/v1/file/trash")
        var json = [String: Any]()
        json["fileIDs"] = [item.id]
        return try await post(url: url, json: json, headers: headers)
    }
    
    public func trashItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/api/v1/file/delete")
        var json = [String: Any]()
        json["fileIDs"] = [item.id]
        return try await post(url: url, json: json, headers: headers)
    }
    
    /// Rename file/folder item.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/api/v1/file/name")
        var json: [String: Any] = [:]
        json["fileId"] = item.id
        json["fileName"] = newName
        return try await put(url: url, json: json, headers: headers)
    }
    
    /// Search files by keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("/api/v2/file/list")
        var json: [String: Any] = [:]
        json["limit"] = 100
        json["parentFileId"] = 0
        json["searchData"] = keyword
        json["searchMode"] = 1
        
        let response = try await get(url: url, params: json, headers: headers)
        if let json = response.response?.json as? [String: Any], let list = json["items"] as? [[String: Any]] {
            return list.compactMap { Self.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func thumbnailRequest(item: CloudItem) async throws -> URLRequest {
        throw CloudServiceError.unsupported
    }
    
    /// Upload file data to target directory.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(fileURLWithPath: filename).pathExtension)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await uploadFile(tempURL, to: directory, progressHandler: progressHandler)
    }
    
    /// Upload file to target directory with local file url.
    /// Note: remote file url is not supported.
    public func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        var md5 = Insecure.MD5()
        var loop = true
        let bufferSize = 5 * 1024 * 1024
        while loop {
            try autoreleasepool {
                let data = fileHandle.readData(ofLength: bufferSize)
                if data.count > 0 {
                    md5.update(data: data)
                } else {
                    loop = false
                }
            }
        }
        let md5Hash = md5.finalize().toHexString()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        return try await createFile(fileURL: fileURL, filename: fileURL.lastPathComponent, fileSize: fileSize, fileMD5: md5Hash, directory: directory, progressHandler: progressHandler)
    }
    
    public func getDownloadUrl(of item: CloudItem, parameters: [String: Any] = [:]) async throws -> URL {
        let url = apiURL.appendingPathComponent("/api/v1/file/download_info")
        var data: [String: Any] = [:]
        data["fileId"] = item.id
        
        if !parameters.isEmpty {
            for (key, value) in parameters {
                data[key] = value
            }
        }
        let response = try await get(url: url, params: data, headers: headers)
        if let json = response.response?.json as? [String: Any], let data = json["data"] as? [String: Any],
           let urlString = data["downloadUrl"] as? String, let url = URL(string: urlString) {
            return url
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
}

// MARK: - Upload
extension Drive123ServiceProvider {
        
    private func createFile(fileURL: URL, filename: String, fileSize: Int64, fileMD5: String, directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/upload/v2/file/create")
        var json = [String: Any]()
        json["parentFileID"] = directory.id
        json["filename"] = filename
        json["etag"] = fileMD5
        json["size"] = fileSize
        json["duplicate"] = 1
        
        let response = try await post(url: url, json: json, headers: headers)
        if let object = response.response?.json as? [String: Any], let data = object["data"] as? [String: Any] {
            if let fileID = data["fileID"] as? Int, fileID > 0, let reuse = data["reuse"] as? Bool, reuse == true {
                return response
            } else if let preuploadID = data["preuploadID"] as? String, let sliceSize = data["sliceSize"] as? Int64,
                        let servers = data["servers"] as? [String], let server = servers.first, let serverURL = URL(string: server) {
                return try await startUpload(fileURL: fileURL, preuploadID: preuploadID, fileSize: fileSize, sliceSize: sliceSize, uploadServerURL: serverURL, progressHandler: progressHandler)
            }
        }
        throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
    }
    
    private func startUpload(fileURL: URL, preuploadID: String, fileSize: Int64, sliceSize: Int64, uploadServerURL: URL, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        let partCount = Int((fileSize + sliceSize - 1) / sliceSize)
        
        for partNumber in 1...partCount {
            let offset = (Int(partNumber) - 1) * Int(sliceSize)
            let size = min(sliceSize, fileSize - Int64(offset))
            try fileHandle.seek(toOffset: UInt64(offset))
            let data = fileHandle.readData(ofLength: Int(size))
            
            _ = try await uploadData(data, to: uploadServerURL, preuploadID: preuploadID, sliceNo: partNumber)
            
            let progressReport = Progress(totalUnitCount: fileSize)
            progressReport.completedUnitCount = Int64(offset) + size
            progressHandler?(progressReport)
        }
        
        try? fileHandle.close()
        
        let completeResult = try await completeUpload(preuploadID: preuploadID)
        if completeResult {
            let result = HTTPResult(data: nil, response: nil, error: nil, task: nil)
            return CloudResponse(response: result, result: .success(result))
        } else {
            throw CloudServiceError.serviceError(400, "123Pan complete upload failed")
        }
    }
        
    private func uploadData(_ data: Data, to url: URL, preuploadID: String, sliceNo: Int) async throws -> Bool {
        let uploadUrl = url.appendingPathComponent("/upload/v2/file/slice")
        var md5 = Insecure.MD5()
        md5.update(data: data)
        let sliceMD5 = md5.finalize().toHexString()
        
        var formData = [String: Any]()
        formData["preuploadID"] = preuploadID
        formData["sliceNo"] = sliceNo
        formData["sliceMD5"] = sliceMD5
        let file = HTTPFile.data("slice", data, nil)
        
        let response = try await post(url: uploadUrl, data: formData, headers: headers, files: ["slice": file])
        if response.response?.statusCode == 200 {
            return true
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    private func completeUpload(preuploadID: String) async throws -> Bool {
        let url = apiURL.appendingPathComponent("/upload/v1/file/upload_complete")
        var json: [String: Any] = [:]
        json["preuploadID"] = preuploadID
        let response = try await post(url: url, json: json, headers: headers)
        if let json = response.response?.json as? [String: Any], let data = json["data"] as? [String: Any] {
            return data["completed"] as? Bool ?? false
        }
        return false
    }
}

// MARK: - CloudServiceResponseProcessing
extension Drive123ServiceProvider: CloudServiceResponseProcessing {
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let fileId = json["fileId"] as? Int, let filename = json["filename"] as? String else {
            return nil
        }
        if json["trashed"] as? Int == 1 {
            return nil
        }
        let isFolder = (json["type"] as? Int) == 1
        var item = CloudItem(id: String(fileId), name: filename, path: filename, isDirectory: isFolder, json: json)
        item.size = (json["size"] as? Int64) ?? -1
        if let createdAt = json["createAt"] as? String, let creationDate = Self.dateFormatter.date(from: createdAt) {
            item.creationDate = creationDate
        }
        if let updatedAt = json["updateAt"] as? String, let updateDate = Self.dateFormatter.date(from: updatedAt) {
            item.modificationDate = updateDate
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let code = json["code"] as? Int, code != 0 {
            let msg = json["message"] as? String ?? "Unknown error"
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(-1, msg))))
            return true
        }
        return false
    }
    
    public func isUnauthorizedResponse(_ response: HTTPResult) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let code = json["code"] as? Int {
            return code == 401
        }
        return false
    }
}
