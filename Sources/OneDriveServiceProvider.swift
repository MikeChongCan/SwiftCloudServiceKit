//
//  OneDriveServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/9/13.
//

import Foundation

/*
 Developer documents can be found here: https://docs.microsoft.com/en-us/graph/api/resources/onedrive?view=graph-rest-1.0
 For iOS app setup and URL schemes, please refer to Docs/OneDrive.md.
 */
@MainActor
public final class OneDriveServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var name: String { return "OneDrive" }
    
    public var rootItem: CloudItem { return CloudItem(id: "root", name: name, path: "/") }
    
    public var credential: URLCredential?
    
    private let apiURL = URL(string: "https://graph.microsoft.com/v1.0")!
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public enum Route: Sendable {
        case me
        case drive(String)
        case group(String)
        case site(String)
        case user(String)
        
        var prefix: String {
            switch self {
            case .me: return "/me"
            case .drive(let id): return "/drives/\(id)"
            case .group(let id): return "/groups/\(id)"
            case .site(let id): return "/sites/\(id)"
            case .user(let id): return "/users/\(id)"
            }
        }
    }
    
    public let route: Route
    
    required public init(credential: URLCredential?) {
        self.credential = credential
        self.route = .me
    }
    
    public init(credential: URLCredential?, route: Route) {
        self.credential = credential
        self.route = route
    }
    
    private func itemURL(for item: CloudItem) -> URL {
        if item.id == "root" {
            return apiURL.appendingPathComponent("\(route.prefix)/drive/root")
        } else {
            return apiURL.appendingPathComponent("\(route.prefix)/drive/items/\(item.id)")
        }
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = itemURL(for: item)
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let parsedItem = OneDriveServiceProvider.cloudItemFromJSON(json) {
            return parsedItem
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var nextLink: String? = itemURL(for: directory).appendingPathComponent("children").absoluteString
        
        while let link = nextLink, !link.isEmpty, let url = URL(string: link) {
            let response = try await get(url: url)
            if let json = response.response?.json as? [String: Any], let value = json["value"] as? [[String: Any]] {
                let list = value.compactMap { OneDriveServiceProvider.cloudItemFromJSON($0) }
                items.append(contentsOf: list)
                nextLink = json["@odata.nextLink"] as? String
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
            }
        }
        
        for i in 0..<items.count {
            items[i].fixPath(with: directory)
        }
        return items
    }
    
    /// Copy item to directory
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = itemURL(for: item).appendingPathComponent("copy")
        let json: [String: Any] = [
            "parentReference": ["id": directory.id],
            "name": item.name
        ]
        return try await post(url: url, json: json)
    }
    
    /// Create folder at directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = itemURL(for: directory).appendingPathComponent("children")
        let json: [String: Any] = [
            "name": folderName,
            "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "rename"
        ]
        return try await post(url: url, json: json)
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let url = apiURL.appendingPathComponent("\(route.prefix)/drive/items/\(fileId)/content")
        let response = try await get(url: url, progressHandler: { progress in
            let p = Progress(totalUnitCount: progress.bytesExpectedToProcess + progress.bytesProcessed)
            p.completedUnitCount = progress.bytesProcessed
            progressHandler?(p)
        })
        if let data = response.response?.content {
            return data
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func downloadLink(of item: CloudItem) async throws -> String {
        let url = itemURL(for: item)
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let link = json["@microsoft.graph.downloadUrl"] as? String {
            return link
        }
        throw CloudServiceError.unsupported
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("\(route.prefix)/drive")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
           let owner = json["quota"] as? [String: Any],
           let total = owner["total"] as? Int64,
           let remaining = owner["remaining"] as? Int64 {
            return CloudSpaceInformation(totalSpace: total, availableSpace: remaining, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Get information about the current user's account.
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("\(route.prefix)")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
           let name = json["displayName"] as? String {
            return CloudUser(username: name, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Move item to target directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = itemURL(for: item)
        let json = ["parentReference": ["id": directory.id]]
        return try await patch(url: url, json: json)
    }
    
    /// Remove cloud file/folder item.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = itemURL(for: item)
        return try await delete(url: url)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = itemURL(for: item)
        let json = ["name": newName]
        return try await patch(url: url, json: json)
    }
    
    /// Search files with provided keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("\(route.prefix)/drive/root/search(q='\(keyword)')")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let value = json["value"] as? [[String: Any]] {
            return value.compactMap { OneDriveServiceProvider.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Upload file data to target directory.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let escapedName = filename.urlEncoded
        let url = itemURL(for: directory).appendingPathComponent("children/\(escapedName)/content")
        let headers = ["Content-Type": "application/octet-stream"]
        
        let length = Int64(data.count)
        let reportProgress = Progress(totalUnitCount: length)
        return try await put(url: url, headers: headers, requestBody: data, progressHandler: { progress in
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
        
        // Use upload session for files larger than 4MB
        if totalSize > 4 * 1024 * 1024 {
            let escapedName = fileURL.lastPathComponent.urlEncoded
            let url = itemURL(for: directory).appendingPathComponent("children/\(escapedName)/createUploadSession")
            let response = try await post(url: url)
            if let json = response.response?.json as? [String: Any], let uploadUrl = json["uploadUrl"] as? String {
                return try await performUpload(fileURL: fileURL, uploadUrl: uploadUrl, progressHandler: progressHandler)
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
            }
        } else {
            let data = try Data(contentsOf: fileURL)
            return try await uploadData(data, filename: fileURL.lastPathComponent, to: directory, progressHandler: progressHandler)
        }
    }
}

// MARK: - Upload Session
extension OneDriveServiceProvider {
    
    private func performUpload(fileURL: URL, uploadUrl: String, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let totalLength = Int64(size)
        let chunkSize: Int64 = 5 * 1024 * 1024 // 5MB chunks
        
        func uploadChunk(offset: Int64) async throws -> CloudResponse<HTTPResult, Error> {
            let length = min(chunkSize, totalLength - offset)
            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(length))
            try handle.close()
            
            var headers: [String: String] = [:]
            headers["Content-Length"] = "\(length)"
            headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(totalLength)"
            headers["Content-Type"] = "application/octet-stream"
            
            let progressReport = Progress(totalUnitCount: totalLength)
            let response = try await put(url: uploadUrl, headers: headers, requestBody: data, progressHandler: { progress in
                progressReport.completedUnitCount = offset + Int64(Float(length) * progress.percent)
                progressHandler?(progressReport)
            })
            
            let nextOffset = offset + length
            if nextOffset >= totalLength {
                return response
            } else {
                return try await uploadChunk(offset: nextOffset)
            }
        }
        
        return try await uploadChunk(offset: 0)
    }
}

// MARK: - CloudServiceResponseProcessing
extension OneDriveServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String: Any]) -> CloudItem? {
        guard let id = json["id"] as? String, let name = json["name"] as? String else {
            return nil
        }
        let isFolder = json["folder"] != nil
        var item = CloudItem(id: id, name: name, path: name, isDirectory: isFolder, json: json)
        item.size = (json["size"] as? NSNumber)?.int64Value ?? -1
        if let file = json["file"] as? [String: Any] {
            item.fileHash = file["hashes"] as? String
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let created = json["createdDateTime"] as? String {
            item.creationDate = dateFormatter.date(from: created)
        }
        if let modified = json["lastModifiedDateTime"] as? String {
            item.modificationDate = dateFormatter.date(from: modified)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let error = json["error"] as? [String: Any], !error.isEmpty {
            let msg = error["message"] as? String
            let code = response.statusCode ?? 400
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(code, msg))))
            return true
        }
        return false
    }
}
