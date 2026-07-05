//
//  PCloudServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/9/13.
//

import Foundation

/*
 Developer documents can be found here: https://docs.pcloud.com
 */
@MainActor
public final class PCloudServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var name: String { return "pCloud" }
    
    public var rootItem: CloudItem { return CloudItem(id: "0", name: name, path: "/") }
    
    public var credential: URLCredential?
    
    public var apiURL = URL(string: "https://api.pcloud.com")!
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    private var allItemsForSearch: [CloudItem] = []
    
    private var apiServer: String?
    
    required public init(credential: URLCredential?) {
        self.credential = credential
    }
    
    private func getApiServer() async throws -> String {
        if let server = apiServer {
            return server
        }
        let url = URL(string: "https://api.pcloud.com/getapiserver")!
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any], let server = json["api"] as? [String] {
            let host = server.first ?? "api.pcloud.com"
            let schemeHost = "https://" + host
            apiServer = schemeHost
            return schemeHost
        }
        return "https://api.pcloud.com"
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let server = try await getApiServer()
        let method = item.isDirectory ? "listfolder" : "stat"
        let url = URL(string: "\(server)/\(method)")!
        var params: [String: Any] = [:]
        if item.isDirectory {
            params["folderid"] = item.id
        } else {
            params["fileid"] = item.id
        }
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any] {
            let metadata = item.isDirectory ? (json["metadata"] as? [String: Any] ?? json) : json
            if let parsedItem = PCloudServiceProvider.cloudItemFromJSON(metadata) {
                return parsedItem
            }
        }
        throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
    }
    
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/listfolder")!
        let params = ["folderid": directory.id]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let metadata = json["metadata"] as? [String: Any],
           let contents = metadata["contents"] as? [[String: Any]] {
            var items = contents.compactMap { PCloudServiceProvider.cloudItemFromJSON($0) }
            for i in 0..<items.count {
                items[i].fixPath(with: directory)
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Copy item to directory
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let action = item.isDirectory ? "copyfolder" : "copyfile"
        let url = URL(string: "\(server)/\(action)")!
        var data: [String: Any] = [:]
        if item.isDirectory {
            data["folderid"] = item.id
        } else {
            data["fileid"] = item.id
        }
        data["tofolderid"] = directory.id
        return try await post(url: url, data: data)
    }
    
    /// Create folder at directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/createfolder")!
        var data: [String: Any] = [:]
        data["folderid"] = directory.id
        data["name"] = folderName
        return try await post(url: url, data: data)
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/userinfo")!
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
           let total = json["quota"] as? Int64,
           let used = json["usedquota"] as? Int64 {
            return CloudSpaceInformation(totalSpace: total, availableSpace: total - used, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Get information about the current user's account.
    public func getCurrentUserInfo() async throws -> CloudUser {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/userinfo")!
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
           let email = json["email"] as? String {
            return CloudUser(username: email, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func downloadLink(of item: CloudItem) async throws -> String {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/getfilelink")!
        let params = ["fileid": item.id]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let path = json["path"] as? String,
           let hosts = json["hosts"] as? [String], let host = hosts.first {
            return "https://" + host + path
        }
        throw CloudServiceError.unsupported
    }
    
    /// Move item to target directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let action = item.isDirectory ? "renamefolder" : "renamefile"
        let url = URL(string: "\(server)/\(action)")!
        var data: [String: Any] = [:]
        if item.isDirectory {
            data["folderid"] = item.id
        } else {
            data["fileid"] = item.id
        }
        data["tofolderid"] = directory.id
        return try await post(url: url, data: data)
    }
    
    /// Remove cloud file/folder item.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let action = item.isDirectory ? "deletefolder" : "deletefile"
        let url = URL(string: "\(server)/\(action)")!
        var data: [String: Any] = [:]
        if item.isDirectory {
            data["folderid"] = item.id
        } else {
            data["fileid"] = item.id
        }
        return try await post(url: url, data: data)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let action = item.isDirectory ? "renamefolder" : "renamefile"
        let url = URL(string: "\(server)/\(action)")!
        var data: [String: Any] = [:]
        if item.isDirectory {
            data["folderid"] = item.id
        } else {
            data["fileid"] = item.id
        }
        data["toname"] = newName
        return try await post(url: url, data: data)
    }
    
    /// Search files with provided keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        // pCloud does not have a search API in basic accounts. We fall back to a recursive scan.
        if allItemsForSearch.isEmpty {
            allItemsForSearch = try await scanDirectoryRecursively(directory: rootItem)
        }
        return allItemsForSearch.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }
    
    private func scanDirectoryRecursively(directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        let contents = try await contentsOfDirectory(directory)
        for content in contents {
            items.append(content)
            if content.isDirectory {
                let subdirItems = try await scanDirectoryRecursively(directory: content)
                items.append(contentsOf: subdirItems)
            }
        }
        return items
    }
    
    public func streamingAudioLink(of item: CloudItem) async throws -> String {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/getaudiolink")!
        let params = ["fileid": item.id]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let path = json["path"] as? String,
           let hosts = json["hosts"] as? [String], let host = hosts.first {
            return "https://" + host + path
        }
        throw CloudServiceError.unsupported
    }
    
    public func streamingVideoLink(of item: CloudItem) async throws -> String {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/getvideolink")!
        let params = ["fileid": item.id]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let path = json["path"] as? String,
           let hosts = json["hosts"] as? [String], let host = hosts.first {
            return "https://" + host + path
        }
        throw CloudServiceError.unsupported
    }
    
    /// Upload file data to target directory.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let server = try await getApiServer()
        let url = URL(string: "\(server)/uploadfile")!
        let file = HTTPFile.data(filename, data, "application/octet-stream")
        let postData: [String: Any] = [
            "folderid": directory.id,
            "nopartial": 1
        ]
        
        let length = Int64(data.count)
        let reportProgress = Progress(totalUnitCount: length)
        return try await post(url: url, data: postData, files: ["file": file], progressHandler: { progress in
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
        
        let server = try await getApiServer()
        let url = URL(string: "\(server)/uploadfile")!
        let data = try Data(contentsOf: fileURL)
        let file = HTTPFile.data(fileURL.lastPathComponent, data, "application/octet-stream")
        let postData: [String: Any] = [
            "folderid": directory.id,
            "nopartial": 1
        ]
        
        let reportProgress = Progress(totalUnitCount: totalSize)
        return try await post(url: url, data: postData, files: ["file": file], progressHandler: { progress in
            reportProgress.completedUnitCount = Int64(Float(totalSize) * progress.percent)
            progressHandler?(reportProgress)
        })
    }
}

// MARK: - CloudServiceResponseProcessing
extension PCloudServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let name = json["name"] as? String else {
            return nil
        }
        let isDirectory = json["isfolder"] as? Bool ?? (json["isfolder"] as? Int == 1)
        var id = ""
        if isDirectory {
            id = (json["folderid"] as? String) ?? "\(json["folderid"] as? Int ?? 0)"
        } else {
            id = (json["fileid"] as? String) ?? "\(json["fileid"] as? Int ?? 0)"
        }
        let path = json["path"] as? String ?? name
        var item = CloudItem(id: id, name: name, path: path, isDirectory: isDirectory, json: json)
        item.size = (json["size"] as? Int64) ?? -1
        item.fileHash = json["hash"] as? String
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let created = json["created"] as? String {
            item.creationDate = dateFormatter.date(from: created)
        }
        if let modified = json["modified"] as? String {
            item.modificationDate = dateFormatter.date(from: modified)
        }
        
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let result = json["result"] as? Int, result != 0 {
            let msg = json["error"] as? String ?? "Unknown error"
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(result, msg))))
            return true
        }
        return false
    }
}
