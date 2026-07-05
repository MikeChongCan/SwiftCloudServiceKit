//
//  BaiduPanServiceProvider.swift
//  
//
//  Created by alexiscn on 2021/9/13.
//

import Foundation
import CryptoKit

/*
 Developer documents can be found here: https://pan.baidu.com/union/doc/
 */
@MainActor
public final class BaiduPanServiceProvider: CloudServiceProvider {
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var name: String { "BaiduPan" }
    
    public var credential: URLCredential?
    
    public func applyAuthorization(to request: inout URLRequest, params: inout [String: Any], credential: URLCredential?) {
        guard let token = credential?.password else { return }
        params["access_token"] = token
    }
    
    public var rootItem: CloudItem { CloudItem(id: "0", name: name, path: "/") }
    
    public var appName: String = ""
    
    private let chunkSize: Int64 = 4 * 1024 * 1024 // 4M
    
    private let apiURL = URL(string: "https://pan.baidu.com/rest/2.0")!
    
    public let session: URLSession
    
    required public init(credential: URLCredential?) {
        self.credential = credential
        self.session = .shared
    }
    
    public init(credential: URLCredential?, session: URLSession) {
        self.credential = credential
        self.session = session
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = apiURL.appendingPathComponent("xpan/multimedia")
        var params: [String: Any] = [:]
        params["method"] = "filemetas"
        params["fsids"] = "[\(item.id)]"
        params["dlink"] = 1
        
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let list = json["list"] as? [[String: Any]],
           let first = list.first,
           let parsedItem = Self.cloudItemFromJSON(first) {
            return parsedItem
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params: [String: Any] = [:]
        params["method"] = "list"
        params["dir"] = directory.path
        params["folder"] = 0
        
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let list = json["list"] as? [[String: Any]] {
            var items = list.compactMap { Self.cloudItemFromJSON($0) }
            for i in 0..<items.count {
                items[i].fixPath(with: directory)
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Copy item to directory
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params = ["method": "filemanager", "opera": "copy"]
        
        var toPath = directory.path
        if !toPath.hasSuffix("/") {
            toPath += "/"
        }
        toPath += item.name
        
        let filelist = [["path": item.path, "dest": toPath, "newname": item.name]]
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
    
    /// Create folder at directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        let params = ["method": "create"]
        
        var path = directory.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        path += folderName
        
        let data: [String: Any] = [
            "path": path,
            "size": 0,
            "isdir": 1,
            "block_list": "[]"
        ]
        return try await post(url: url, params: params, data: data)
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("xpan/nas")
        let params = ["method": "uinfo"]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let total = json["total"] as? Int64,
           let used = json["used"] as? Int64 {
            return CloudSpaceInformation(totalSpace: total, availableSpace: total - used, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get information about the current user's account.
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("xpan/nas")
        let params = ["method": "uinfo"]
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any],
           let name = json["baidu_name"] as? String {
            return CloudUser(username: name, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let item = try await attributesOfItem(CloudItem(id: fileId, name: "", path: ""))
        let link = try await downloadLink(of: item)
        guard let url = URL(string: link) else {
            throw CloudServiceError.unsupported
        }
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
    
    public func downloadLink(of item: CloudItem) async throws -> String {
        if let dlink = item.json["dlink"]?.value as? String {
            return dlink + "&access_token=\(credential?.password ?? "")"
        }
        throw CloudServiceError.unsupported
    }
    
    public func streamingVideo(item: CloudItem) async throws -> String {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params: [String: Any] = [:]
        params["method"] = "streaming"
        params["path"] = item.path
        params["type"] = "M3U8_AUTO_480"
        let response = try await get(url: url, params: params)
        if let data = response.response?.content, let link = String(data: data, encoding: .utf8) {
            return link
        }
        throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
    }
    
    public func streamingAudioRequest(_ item: CloudItem) -> URLRequest? {
        let url = apiURL.appendingPathComponent("xpan/file").appendingQueryParameters([
            "method": "filemetas",
            "fsids": "[\(item.id)]",
            "dlink": "1",
            "access_token": credential?.password ?? ""
        ])
        return URLRequest(url: url)
    }
    
    /// Move item to target directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params = ["method": "filemanager", "opera": "move"]
        
        var toPath = directory.path
        if !toPath.hasSuffix("/") {
            toPath += "/"
        }
        toPath += item.name
        
        let filelist = [["path": item.path, "dest": toPath, "newname": item.name]]
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
    
    /// Remove cloud file/folder item.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        let params = ["method": "filemanager", "opera": "delete"]
        let filelist = [["path": item.path]]
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params = ["method": "filemanager", "opera": "rename"]
        
        let filelist = [["path": item.path, "newname": newName]]
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
    
    /// Search files with provided keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params: [String: Any] = [:]
        params["method"] = "search"
        params["key"] = keyword
        params["recursion"] = 1
        
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let list = json["list"] as? [[String: Any]] {
            return list.compactMap { Self.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Upload file data to target directory.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await uploadFile(tempURL, to: directory, progressHandler: progressHandler)
    }
    
    /// Upload file to target directory with local file url.
    /// Note: remote file url is not supported.
    public func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        
        guard FileManager.default.fileExists(atPath: fileURL.path), let totalSize = fileSize(of: fileURL) else {
            throw CloudServiceError.uploadFileNotExist
        }
        
        // xpan upload flow: precreate -> chunk -> create -> move
        let url = apiURL.appendingPathComponent("xpan/file")
        let params = ["method": "precreate"]
        
        let md5List = try calculateMD5List(fileURL: fileURL)
        var path = directory.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        let finalPath = "/apps/\(appName)/" + fileURL.lastPathComponent
        
        let data: [String: Any] = [
            "path": finalPath,
            "size": totalSize,
            "isdir": 0,
            "block_list": md5List.json,
            "autoinit": 1,
            "rtype": 1
        ]
        
        let response = try await post(url: url, params: params, json: data)
        if let json = response.response?.json as? [String: Any],
           let uploadId = json["uploadid"] as? String {
            let session = UploadSession(fileURL: fileURL, uploadId: uploadId, md5List: md5List, size: totalSize, finalPath: finalPath)
            _ = try await uploadAllParts(session: session, progressHandler: progressHandler)
            let createResponse = try await createUploadFile(session: session)
            return try await moveItem(CloudItem(id: "", name: fileURL.lastPathComponent, path: finalPath, isDirectory: false), to: directory)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
}

// MARK: - Upload Flow Helpers
extension BaiduPanServiceProvider {
    
    private func calculateMD5List(fileURL: URL) throws -> [String] {
        var list: [String] = []
        let handle = try FileHandle(forReadingFrom: fileURL)
        let totalSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var offset: Int64 = 0
        
        while offset < totalSize {
            let length = min(chunkSize, Int64(totalSize) - offset)
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(length))
            let md5 = Insecure.MD5.hash(data: data).toHexString()
            list.append(md5)
            offset += length
        }
        try handle.close()
        return list
    }
    
    private func uploadAllParts(session: UploadSession, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        var partseq = 0
        var lastResponse: CloudResponse<HTTPResult, Error>?
        let progressReport = Progress(totalUnitCount: session.size)
        
        while Int64(partseq) * chunkSize < session.size {
            let offset = Int64(partseq) * chunkSize
            let length = min(chunkSize, session.size - offset)
            let chunkOffset = offset
            let data = try await FileChunkReader.readChunk(from: session.fileURL, offset: chunkOffset, length: Int(length))
            
            let url = URL(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
            let params: [String: Any] = [
                "method": "upload",
                "type": "tmpfile",
                "path": session.finalPath,
                "uploadid": session.uploadId,
                "partseq": partseq
            ]
            
            let file = HTTPFile.data(session.fileURL.lastPathComponent, data, "application/octet-stream")
            
            let response = try await post(url: url, params: params, files: ["file": file], progressHandler: { progress in
                progressReport.completedUnitCount = chunkOffset + Int64(Float(length) * progress.percent)
                progressHandler?(progressReport)
            })
            
            lastResponse = response
            partseq += 1
        }
        
        return lastResponse ?? CloudResponse(response: HTTPResult(), result: .success(HTTPResult()))
    }
    
    private func createUploadFile(session: UploadSession) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        let params = ["method": "create"]
        let data: [String: Any] = [
            "path": session.finalPath,
            "size": session.size,
            "isdir": 0,
            "block_list": session.md5List.json,
            "uploadid": session.uploadId,
            "rtype": 1
        ]
        return try await post(url: url, params: params, json: data)
    }
}

// MARK: - CloudServiceResponseProcessing
extension BaiduPanServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let idNum = json["fs_id"] as? NSNumber, let path = json["path"] as? String else {
            return nil
        }
        let isDirectory = (json["isdir"] as? Int == 1) || (json["isdir"] as? Bool == true)
        let name = json["server_filename"] as? String ?? path.components(separatedBy: "/").last ?? ""
        var item = CloudItem(id: "\(idNum)", name: name, path: path, isDirectory: isDirectory, json: json)
        item.size = (json["size"] as? Int64) ?? -1
        item.fileHash = json["md5"] as? String
        
        if let modified = json["server_mtime"] as? Double {
            item.modificationDate = Date(timeIntervalSince1970: modified)
        }
        if let created = json["server_ctime"] as? Double {
            item.creationDate = Date(timeIntervalSince1970: created)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let errno = json["errno"] as? Int, errno != 0 {
            let msg = json["errmsg"] as? String ?? "Unknown error"
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(errno, msg))))
            return true
        }
        return false
    }
}

// MARK: - CloudServiceBatching
extension BaiduPanServiceProvider: CloudServiceBatching {
    
    public func moveItems(_ items: [CloudItem], to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params = ["method": "filemanager", "opera": "move"]
        
        let filelist = items.map { item -> [String: String] in
            var toPath = directory.path
            if !toPath.hasSuffix("/") {
                toPath += "/"
            }
            toPath += item.name
            return ["path": item.path, "dest": toPath, "newname": item.name]
        }
        
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
    
    public func removeItems(_ items: [CloudItem]) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("xpan/file")
        var params = ["method": "filemanager", "opera": "delete"]
        let filelist = items.map { ["path": $0.path] }
        let data = ["filelist": filelist.json]
        return try await post(url: url, params: params, data: data)
    }
}

fileprivate final class UploadSession: Sendable {
    let fileURL: URL
    let uploadId: String
    let md5List: [String]
    let size: Int64
    let finalPath: String
    
    init(fileURL: URL, uploadId: String, md5List: [String], size: Int64, finalPath: String) {
        self.fileURL = fileURL
        self.uploadId = uploadId
        self.md5List = md5List
        self.size = size
        self.finalPath = finalPath
    }
}
