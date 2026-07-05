//
//  AliyunDriveServiceProvider.swift
//  CloudServiceKit
//
//  Created by alexiscn on 2023/10/24.
//

import Foundation
import CryptoKit

/// https://www.yuque.com/aliyundrive/zpfszx
@MainActor
public final class AliyunDriveServiceProvider: CloudServiceProvider {
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var name: String { "AliyunDrive" }
    
    public var credential: URLCredential?
    
    public var rootItem: CloudItem { CloudItem(id: "root", name: name, path: "/") }
    
    public var driveId: String = ""
    
    /// Upload chunsize which is 10M.
    public let chunkSize: Int64 = 10 * 1024 * 1024
    
    public var apiURL = URL(string: "https://openapi.alipan.com")!
    
    public required init(credential: URLCredential?) {
        self.credential = credential
    }
    
    /// Get attributes of cloud item.
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/get")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        let response = try await post(url: url, json: json)
        if let object = response.response?.json as? [String: Any], let file = Self.cloudItemFromJSON(object) {
            return file
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Load the contents at directory.
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var pageMarker: String?
        
        repeat {
            var json: [String: Any] = [:]
            json["all"] = false
            json["drive_id"] = driveId
            json["fields"] = "*"
            json["limit"] = 100
            json["order_by"] = "updated_at"
            json["order_direction"] = "DESC"
            json["parent_file_id"] = directory.id
            if let marker = pageMarker {
                json["marker"] = marker
            }
            let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/list")
            let response = try await post(url: url, json: json)
            if let object = response.response?.json as? [String: Any],
               let list = object["items"] as? [[String: Any]] {
                let files = list.compactMap { Self.cloudItemFromJSON($0) }
                items.append(contentsOf: files)
                pageMarker = object["next_marker"] as? String
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
            }
        } while pageMarker != nil && !pageMarker!.isEmpty
        
        for i in 0..<items.count {
            items[i].fixPath(with: directory)
        }
        return items
    }
    
    /// Copy item to directory
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/copy")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        json["to_parent_file_id"] = directory.id
        json["auto_rename"] = true
        return try await post(url: url, json: json)
    }
    
    /// Create folder at directory.
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/create")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["parent_file_id"] = directory.id
        json["name"] = folderName
        json["type"] = "folder"
        json["check_name_mode"] = "auto_rename"
        return try await post(url: url, json: json)
    }
    
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/user/getDriveInfo")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any],
           let user = json["user"] as? [String: Any],
           let total = user["total_size"] as? Int64,
           let used = user["used_size"] as? Int64 {
            return CloudSpaceInformation(totalSpace: total, availableSpace: total - used, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/user/get")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any],
           let name = json["nick_name"] as? String {
            return CloudUser(username: name, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func getDriveInfo() async throws -> AliyunDriveInfo {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/user/getDriveInfo")
        let response = try await post(url: url)
        if let data = response.response?.content {
            return try JSONDecoder().decode(AliyunDriveInfo.self, from: data)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let downloadUrl = try await getFileDownloadUrl(of: CloudItem(id: fileId, name: "", path: ""))
        guard let url = URL(string: downloadUrl) else {
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
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    public func getFileDownloadUrl(of item: CloudItem) async throws -> String {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/getDownloadUrl")
        var json: [String: Any] = [:]
        json["drive_id"] = driveId
        json["file_id"] = item.id
        let response = try await post(url: url, json: json)
        if let json = response.response?.json as? [String: Any], let downloadUrl = json["url"] as? String {
            return downloadUrl
        }
        throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
    }
    
    public func getThumbnail(of item: CloudItem) async throws -> Data {
        // AliyunDrive returns video preview play info and thumbnails in custom properties
        throw CloudServiceError.unsupported
    }
    
    public func getPlayInfo(of item: CloudItem) async throws -> AliyunVideoPreviewPlayInfo {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/getVideoPreviewPlayInfo")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        json["category"] = "live_transcoding"
        let response = try await post(url: url, json: json)
        if let data = response.response?.content {
            return try JSONDecoder().decode(AliyunVideoPreviewPlayInfo.self, from: data)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Move item to target directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/move")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        json["to_parent_file_id"] = directory.id
        json["auto_rename"] = true
        return try await post(url: url, json: json)
    }
    
    /// Remove cloud file/folder item.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/delete")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        return try await post(url: url, json: json)
    }
    
    /// Rename cloud file/folder to a new name.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/update")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["file_id"] = item.id
        json["name"] = newName
        json["check_name_mode"] = "auto_rename"
        return try await post(url: url, json: json)
    }
    
    /// Search files with provided keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/search")
        var json = [String: Any]()
        json["drive_id"] = driveId
        json["query"] = "name match '\(keyword)'"
        json["limit"] = 100
        let response = try await post(url: url, json: json)
        if let json = response.response?.json as? [String: Any], let items = json["items"] as? [[String: Any]] {
            return items.compactMap { Self.cloudItemFromJSON($0) }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
    
    /// Upload file data to target directory.
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        // Create a temporary file and upload it
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
        
        // 1. check prehash
        var proofCode = ""
        if let code = calculateProofcode(fileURL: fileURL, size: totalSize) {
            proofCode = code
        }
        
        let hash = calculateContentHash(fileURL: fileURL) ?? ""
        let prehash = calculatePreHash(fileURL: fileURL) ?? ""
        
        let url = apiURL.appendingPathComponent("/adrive/v1.0/openFile/create")
        var json: [String: Any] = [:]
        json["drive_id"] = driveId
        json["parent_file_id"] = directory.id
        json["name"] = fileURL.lastPathComponent
        json["type"] = "file"
        json["check_name_mode"] = "auto_rename"
        json["size"] = totalSize
        json["content_hash"] = hash
        json["content_hash_name"] = "sha1"
        json["proof_code"] = proofCode
        json["proof_version"] = "v1"
        
        var partInfoList: [[String: Any]] = []
        let partCount = Int((totalSize + chunkSize - 1) / chunkSize)
        for i in 1...partCount {
            partInfoList.append(["part_number": i])
        }
        json["part_info_list"] = partInfoList
        
        let response = try await post(url: url, json: json)
        if let jsonObject = response.response?.json as? [String: Any] {
            if let rapidUpload = jsonObject["rapid_upload"] as? Bool, rapidUpload == true {
                return response
            } else {
                return try await performUpload(result: response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil), fileURL: fileURL, size: totalSize, directory: directory, progressHandler: progressHandler)
            }
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult(data: nil, response: nil, error: nil, task: nil))
        }
    }
}

// MARK: - SHA1 & Proof Code
extension AliyunDriveServiceProvider {
    
    private func calculatePreHash(fileURL: URL) -> String? {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            let data = fileHandle.readData(ofLength: 1024)
            try fileHandle.close()
            return Insecure.SHA1.hash(data: data).toHexString()
        } catch {
            // silent failure
        }
        return nil
    }
    
    private func calculateContentHash(fileURL: URL) -> String? {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            let bufferSize = 1024 * 1024
            var sha1 = Insecure.SHA1()

            var loop = true
            while loop {
                autoreleasepool {
                    let data = fileHandle.readData(ofLength: bufferSize)
                    if data.count > 0 {
                        sha1.update(data: data)
                    } else {
                        loop = false
                    }
                }
            }
            try fileHandle.close()
            return sha1.finalize().toHexString().uppercased()
        } catch {
            // silent failure
        }
        return nil
    }
    
    private func calculateProofcode(fileURL: URL, size: Int64) -> String? {
        do {
            let accessTokenData = (credential?.password ?? "").data(using: .utf8) ?? Data()
            let accessTokenMD5 = Insecure.MD5.hash(data: accessTokenData).toHexString()
            
            let startIndex = accessTokenMD5.startIndex
            let endIndex = accessTokenMD5.index(startIndex, offsetBy: 16)
            let sub = accessTokenMD5[startIndex..<endIndex]
            let start = Int64((UInt64(sub, radix: 16) ?? 0) % UInt64(size))
            let end = min(Int64(start + 8), size)
            
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: UInt64(start))
            let subdata = fileHandle.readData(ofLength: Int(end - start))
            try fileHandle.close()
            return subdata.base64EncodedString()
        } catch {
            // silent failure
        }
        return nil
    }
}

// MARK: - Chunk upload
extension AliyunDriveServiceProvider {
    
    private func performUpload(result: HTTPResult, fileURL: URL, size: Int64, directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let content = result.content ?? Data()
        let session = try JSONDecoder().decode(AliyunUploadSession.self, from: content)
        if let part = session.partInfoList?.first {
            return try await chunkUpload(session: session, part: part, fileURL: fileURL, size: size, progressHandler: progressHandler)
        }
        throw CloudServiceError.responseDecodeError(result)
    }

    private func chunkUpload(session: AliyunUploadSession, part: AliyunPartInfo, fileURL: URL, size: Int64, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let offset: Int64 = Int64(part.partNumber - 1) * chunkSize
        let length = min(chunkSize, size - offset)
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        try fileHandle.seek(toOffset: UInt64(offset))
        let data = fileHandle.readData(ofLength: Int(length))
        try fileHandle.close()
                    
        let headers = ["Content-Type": ""]
        
        let progressReport = Progress(totalUnitCount: size)
        _ = try await put(url: part.uploadUrl, headers: headers, requestBody: data, progressHandler: { progress in
            progressReport.completedUnitCount = offset + Int64(Float(length) * progress.percent)
            progressHandler?(progressReport)
        })
        
        guard let partList = session.partInfoList else {
            throw CloudServiceError.unsupported
        }
        let index = partList.firstIndex(where: { $0.partNumber == part.partNumber }) ?? 0
        if index == partList.count - 1 {
            return try await complete(session)
        } else {
            return try await chunkUpload(session: session, part: partList[index + 1], fileURL: fileURL, size: size, progressHandler: progressHandler)
        }
    }
    
    private func complete(_ session: AliyunUploadSession) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.absoluteString.appending("/adrive/v1.0/openFile/complete")
        var json: [String: Any] = [:]
        json["drive_id"] = driveId
        json["file_id"] = session.fileId
        json["upload_id"] = session.uploadId
        return try await post(url: url, json: json)
    }
}

// MARK: - CloudServiceResponseProcessing
extension AliyunDriveServiceProvider: CloudServiceResponseProcessing {
    
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let name = json["name"] as? String, let id = json["file_id"] as? String else {
            return nil
        }
        let isDirectory = (json["type"] as? String) == "folder"
        let path = json["path"] as? String ?? name
        var item = CloudItem(id: id, name: name, path: path, isDirectory: isDirectory, json: json)
        item.size = (json["size"] as? Int64) ?? -1
        item.fileHash = json["content_hash"] as? String
        
        if let created = json["created_at"] as? String {
            item.creationDate = ISO8601DateFormatter.shared.date(from: created)
        }
        if let updated = json["updated_at"] as? String {
            item.modificationDate = ISO8601DateFormatter.shared.date(from: updated)
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let code = json["code"] as? String, code != "0" {
            // Check for duplicate folder/file errors (409 is sometimes expected name conflicts)
            if code == "PreconditionFailed" { return false }
            let msg = json["message"] as? String
            let statusCode = response.statusCode ?? 400
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(statusCode, msg))))
            return true
        }
        return false
    }
}

public struct AliyunDriveInfo: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case defaultDriveId = "default_drive_id"
    }
    public let defaultDriveId: String
}

public struct AliyunUploadSession: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case fileId = "file_id"
        case filename = "file_name"
        case parentFileId = "parent_file_id"
        case partInfoList = "part_info_list"
        case rapidUpload = "rapid_upload"
        case uploadId = "upload_id"
    }

    public let driveId: String
    public let fileId: String
    public let filename: String
    public let parentFileId: String
    public let partInfoList: [AliyunPartInfo]?
    public let rapidUpload: Bool
    public let uploadId: String
}

public struct AliyunPartInfo: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case internalUploadUrl = "internal_upload_url"
        case partNumber = "part_number"
        case uploadUrl = "upload_url"
    }
    public let contentType: String?
    public let internalUploadUrl: String?
    public let partNumber: Int
    public let uploadUrl: String
}

public struct AliyunVideoPreviewPlayInfo: Codable, Sendable {
    
    public struct PreviewInfo: Codable, Sendable {
        enum CodingKeys: String, CodingKey {
            case category
            case transcodingList = "live_transcoding_task_list"
            case subtitleList = "live_transcoding_subtitle_task_list"
        }
        
        public let category: String
        public let transcodingList: [VideoTranscoding]
        public var subtitleList: [SubtitleTranscoding]?
    }
    
    public struct VideoTranscoding: Codable, Sendable {
        enum CodingKeys: String, CodingKey {
            case templateId = "template_id"
            case status
            case url
        }
        public let templateId: String
        public let status: String
        public var url: String?
    }
    
    public struct SubtitleTranscoding: Codable, Sendable {
        public var language: String?
        public var status: String?
        public var url: String?
    }
    
    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case fileId = "file_id"
        case videoPreviewPlayInfo = "video_preview_play_info"
    }
    
    public let driveId: String
    public let fileId: String
    public let videoPreviewPlayInfo: PreviewInfo
}
