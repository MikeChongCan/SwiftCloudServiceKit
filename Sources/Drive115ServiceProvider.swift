//
//  Drive115ServiceProvider.swift
//
//
//  Created by alexiscn on 2025/2/16.
//

import Foundation
import CryptoKit

/// Drive115ServiceProvider
/// https://www.yuque.com/115yun/open/gv0l5007pczskivz
@MainActor
public final class Drive115ServiceProvider: CloudServiceProvider {
    
    public var delegate: CloudServiceProviderDelegate?
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public var name: String { return "115" }
    
    public var credential: URLCredential?
    
    public var rootItem: CloudItem { return CloudItem(id: "0", name: name, path: "/") }
    
    public var apiURL = URL(string: "https://proapi.115.com")!
    
    private let ossClient = AliyunOSSClient()
    
    public required init(credential: URLCredential?) {
        self.credential = credential
    }
    
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        return item
    }
    
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var index = 0
        var count = 0
        
        repeat {
            var params: [String: Any] = [:]
            params["limit"] = 100
            params["asc"] = "1"
            params["cid"] = directory.id
            params["show_dir"] = 1
            if index > 0 {
                params["offset"] = index
            }
            let url = apiURL.appendingPathComponent("/open/ufile/files")
            let response = try await get(url: url, params: params)
            if let object = response.response?.json as? [String: Any],
               let list = object["data"] as? [[String: Any]] {
                let files = list.compactMap { Self.cloudItemFromJSON($0) }
                items.append(contentsOf: files)
                count = object["count"] as? Int ?? 0
                index += list.count
            } else {
                throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
            }
        } while index < count
        
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
        let url = apiURL.appendingPathComponent("/open/folder/add")
        var data: [String: Any] = [:]
        data["pid"] = directory.id
        data["file_name"] = folderName
        return try await post(url: url, data: data)
    }
    
    /// Get the space usage information for the current user's account.
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        let url = apiURL.appendingPathComponent("/open/user/info")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any], let data = json["data"] as? [String: Any],
           let info = data["rt_space_info"] as? [String: Any],
           let totalSizeObject = info["all_total"] as? [String: String], let totalSizeStr = totalSizeObject["size"], let totalSize = Int64(totalSizeStr),
           let usedSizeObject = info["all_use"] as? [String: String], let usedSizeStr = usedSizeObject["size"], let usedSize = Int64(usedSizeStr) {
            return CloudSpaceInformation(totalSpace: totalSize, availableSpace: totalSize - usedSize, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    /// Get information about the current user's account.
    public func getCurrentUserInfo() async throws -> CloudUser {
        let url = apiURL.appendingPathComponent("/open/user/info")
        let response = try await post(url: url)
        if let json = response.response?.json as? [String: Any], let username = json["nick_name"] as? String {
            return CloudUser(username: username, json: json)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func downloadRequest(item: CloudItem) async throws -> URLRequest {
        let url = try await getDownloadUrl(of: item)
        var request = URLRequest(url: url)
        request.setValue("CloudServiceKit", forHTTPHeaderField: "User-Agent")
        return request
    }
    
    public func mediaRequest(item: CloudItem) async throws -> URLRequest {
        let url = try await getDownloadUrl(of: item, parameters: [:])
        var request = URLRequest(url: url)
        request.setValue("CloudServiceKit", forHTTPHeaderField: "User-Agent")
        return request
    }
    
    /// Move file to directory.
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/open/ufile/move")
        var data = [String: Any]()
        data["file_ids"] = item.id
        data["to_cid"] = directory.id
        return try await post(url: url, data: data)
    }
    
    /// Remove file/folder.
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/open/ufile/delete")
        var data = [String: Any]()
        data["file_ids"] = item.id
        return try await post(url: url, data: data)
    }
    
    public func trashItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/api/v1/file/trash")
        var data = [String: Any]()
        data["fileIDs"] = [item.id]
        return try await post(url: url, data: data)
    }
    
    /// Rename file/folder item.
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/open/ufile/update")
        var data: [String: Any] = [:]
        data["file_id"] = item.id
        data["name"] = newName
        return try await post(url: url, data: data)
    }
    
    /// Search files by keyword.
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        let url = apiURL.appendingPathComponent("/open/ufile/search")
        var params: [String: Any] = [:]
        params["limit"] = 100
        params["offset"] = 0
        params["search_value"] = keyword
        params["pick_code"] = "0"
        
        let response = try await get(url: url, params: params)
        if let json = response.response?.json as? [String: Any], let list = json["data"] as? [Any] {
            var items = [CloudItem]()
            for obj in list {
                if let json = obj as? [String: Any],
                    let fileId = json["file_id"] as? String,
                   let filename = json["file_name"] as? String {
                    let isDirectory = (json["file_category"] as? String) == "0"
                    var item = CloudItem(id: fileId, name: filename, path: filename, isDirectory: isDirectory, json: json)
                    item.size = Int64(json["file_size"] as? String ?? "-1") ?? -1
                    if let uploadTime = json["user_ptime"] as? String, let timestamp = TimeInterval(uploadTime) {
                        item.creationDate = Date(timeIntervalSince1970: timestamp)
                    }
                    if let updateTime = json["user_utime"] as? String, let timestamp = TimeInterval(updateTime) {
                        item.modificationDate = Date(timeIntervalSince1970: timestamp)
                    }
                    items.append(item)
                }
            }
            return items
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    public func thumbnailRequest(item: CloudItem) async throws -> URLRequest {
        if let thumb = item.json["thumb"]?.value as? String, let url = URL(string: thumb) {
            return URLRequest(url: url)
        } else {
            throw CloudServiceError.unsupported
        }
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
        var sha1 = Insecure.SHA1()
        var loop = true
        let bufferSize = 5 * 1024 * 1024
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
        let sha1Hash = sha1.finalize().toHexString().uppercased()
        let filename = fileURL.lastPathComponent
        
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        
        return try await initUpload(fileURL: fileURL, filename: filename, fileSize: fileSize, fileid: sha1Hash, directory: directory, signCalculator: { check in
            let components = check.components(separatedBy: "-")
            if components.count == 2, let lower = Int(components[0]), let upper = Int(components[1]), lower >= 0, upper < fileSize {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    var hash = Insecure.SHA1()
                    try handle.seek(toOffset: UInt64(lower))
                    let data = handle.readData(ofLength: upper - lower + 1)
                    hash.update(data: data)
                    let value = hash.finalize().toHexString().uppercased()
                    return value
                } catch {
                    return ""
                }
            }
            return ""
        }, progressHandler: progressHandler)
    }
    
    public func getDownloadUrl(of item: CloudItem, parameters: [String: Any] = [:]) async throws -> URL {
        let url = apiURL.appendingPathComponent("/open/ufile/downurl")
        var data: [String: Any] = [:]
        
        if let pickCode = item.json["pc"]?.value as? String {
            data["pick_code"] = pickCode
        } else if let pickCode = item.json["pick_code"]?.value as? String {
            data["pick_code"] = pickCode
        }
        
        if !parameters.isEmpty {
            for (key, value) in parameters {
                data[key] = value
            }
        }
        let response = try await post(url: url, data: data, headers: ["User-Agent": "CloudServiceKit"])
        if let json = response.response?.json as? [String: Any],
            let dataObject = json["data"] as? [String: Any],
            let object = dataObject[item.id] as? [String: Any],
           let urlObject = object["url"] as? [String: Any],
           let urlString = urlObject["url"] as? String, let url = URL(string: urlString) {
            return url
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
}

struct UploadToken: Sendable {
    let accessKeyId: String
    let accessKeySecret: String
    let expiration: String
    let securityToken: String
    let endpoint: String
}

// MARK: - Upload file
extension Drive115ServiceProvider {
    
    private func getUploadToken() async throws -> UploadToken {
        let url = apiURL.appendingPathComponent("/open/upload/get_token")
        let response = try await get(url: url)
        if let json = response.response?.json as? [String: Any],
            let data = json["data"] as? [String: Any],
            let accessKeyId = data["AccessKeyId"] as? String,
            let accessKeySecret = data["AccessKeySecret"] as? String,
            let expiration = data["Expiration"] as? String,
            let securityToken = data["SecurityToken"] as? String,
            let endpoint = data["endpoint"] as? String {
            return UploadToken(accessKeyId: accessKeyId, accessKeySecret: accessKeySecret, expiration: expiration, securityToken: securityToken, endpoint: endpoint)
        } else {
            throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
        }
    }
    
    private func initUpload(fileURL: URL, filename: String, fileSize: Int64, fileid: String, directory: CloudItem, signKey: String? = nil, signVal: String? = nil, signCalculator: (@Sendable (String) -> String)?, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let url = apiURL.appendingPathComponent("/open/upload/init")
        var formData = [String: Any]()
        formData["file_name"] = filename
        formData["file_size"] = fileSize
        formData["target"] = "U_1_\(directory.id)"
        formData["fileid"] = fileid
        
        if let signKey, !signKey.isEmpty {
            formData["sign_key"] = signKey
        }
        if let signVal, !signVal.isEmpty {
            formData["sign_val"] = signVal
        }
        
        let response = try await post(url: url, data: formData)
        if let json = response.response?.json as? [String: Any], let state = json["state"] as? Int, state == 1, let data = json["data"] as? [String: Any] {
            if let fileId = data["file_id"] as? String, !fileId.isEmpty {
                return response
            } else if let code = data["code"] as? Int, [700, 701, 702].contains(code), let signCheck = data["sign_check"] as? String, !signCheck.isEmpty, let key = data["sign_key"] as? String, !key.isEmpty {
                let signValue = signCalculator?(signCheck)
                return try await initUpload(fileURL: fileURL, filename: filename, fileSize: fileSize, fileid: fileid, directory: directory, signKey: key, signVal: signValue, signCalculator: nil, progressHandler: progressHandler)
            } else if let bucket = data["bucket"] as? String, !bucket.isEmpty, let object = data["object"] as? String, !object.isEmpty, let callback = data["callback"] as? [String: String] {
                let token = try await getUploadToken()
                let uploadResult = try await ossClient.multipartUpload(fileURL: fileURL, endpoint: token.endpoint, bucket: bucket, objectKey: object, token: token, callback: callback, progressHandler: progressHandler)
                let result = HTTPResult(data: uploadResult, response: nil, error: nil, task: nil)
                return CloudResponse(response: result, result: .success(result))
            }
        }
        throw CloudServiceError.responseDecodeError(response.response ?? HTTPResult())
    }
}

// MARK: - CloudServiceResponseProcessing
extension Drive115ServiceProvider: CloudServiceResponseProcessing {
    public static func cloudItemFromJSON(_ json: [String : Any]) -> CloudItem? {
        guard let fileId = json["fid"] as? String, let filename = json["fn"] as? String else {
            return nil
        }
        let isFolder = (json["fc"] as? String) == "0"
        var item = CloudItem(id: fileId, name: filename, path: filename, isDirectory: isFolder, json: json)
        item.size = (json["fs"] as? Int64) ?? -1
        if let uploadTime = json["uppt"] as? Int64 {
            item.creationDate = Date(timeIntervalSince1970: TimeInterval(uploadTime))
        }
        if let updateTime = json["upt"] as? Int64 {
            item.modificationDate = Date(timeIntervalSince1970: TimeInterval(updateTime))
        }
        return item
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        guard let json = response.json as? [String: Any] else { return false }
        if let state = json["state"] as? Bool, state == false {
            let msg = json["message"] as? String ?? "Unknown error"
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(400, msg))))
            return true
        }
        if let code = json["code"] as? Int, code == 40140125 {
            completion(.init(response: response, result: .failure(CloudServiceError.serviceError(code, "Unauthorized"))))
            return true
        }
        return false
    }
}

// MARK: - Aliyun OSS client
fileprivate final class AliyunOSSClient: Sendable {
    
    func multipartUpload(fileURL: URL, endpoint: String, bucket: String, objectKey: String, token: UploadToken, callback: [String: String], progressHandler: (@Sendable (Progress) -> Void)?) async throws -> Data {
        let uploadId = try await initiateMultipartUpload(endpoint: endpoint, bucket: bucket, objectKey: objectKey, token: token)
        
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let chunkSize = 5 * 1024 * 1024 // 5MB
        let partsCount = Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
        var parts: [UploadPart] = []
        
        for i in 1...partsCount {
            let offset = Int64(i - 1) * Int64(chunkSize)
            let length = min(Int64(chunkSize), fileSize - offset)
            
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: UInt64(offset))
            let chunkData = fileHandle.readData(ofLength: Int(length))
            try fileHandle.close()
            
            let part = try await uploadPart(data: chunkData, partNumber: i, uploadId: uploadId, endpoint: endpoint, bucket: bucket, objectKey: objectKey, token: token)
            parts.append(part)
            
            let progress = Progress(totalUnitCount: fileSize)
            progress.completedUnitCount = offset + length
            progressHandler?(progress)
        }
        
        return try await completeMultipartUpload(parts: parts, uploadId: uploadId, endpoint: endpoint, bucket: bucket, objectKey: objectKey, token: token, callback: callback)
    }
    
    private func initiateMultipartUpload(endpoint: String, bucket: String, objectKey: String, token: UploadToken) async throws -> String {
        let host = "\(bucket).\(endpoint)"
        let url = URL(string: "https://\(host)/\(objectKey)?uploads")!
        let dateString = gmtDateString()
        
        let signature = ossSignature(method: "POST", bucket: bucket, objectKey: objectKey + "?uploads", date: dateString, token: token)
        
        var headers = [
            "Host": host,
            "Date": dateString,
            "Authorization": "OSS \(token.accessKeyId):\(signature)",
            "x-oss-security-token": token.securityToken
        ]
        
        let (data, response) = try await makeRequest(url: url, method: "POST", headers: headers)
        guard response.statusCode == 200 else {
            throw CloudServiceError.serviceError(response.statusCode, "OSS init upload failed")
        }
        
        let xml = String(data: data, encoding: .utf8) ?? ""
        if let range = xml.range(of: "<UploadId>")?.upperBound,
           let endRange = xml.range(of: "</UploadId>")?.lowerBound {
            return String(xml[range..<endRange])
        }
        throw CloudServiceError.serviceError(400, "UploadId not found in response")
    }
    
    private func uploadPart(data: Data, partNumber: Int, uploadId: String, endpoint: String, bucket: String, objectKey: String, token: UploadToken) async throws -> UploadPart {
        let host = "\(bucket).\(endpoint)"
        let url = URL(string: "https://\(host)/\(objectKey)?partNumber=\(partNumber)&uploadId=\(uploadId)")!
        let dateString = gmtDateString()
        
        let signature = ossSignature(method: "PUT", bucket: bucket, objectKey: objectKey + "?partNumber=\(partNumber)&uploadId=\(uploadId)", date: dateString, token: token)
        
        let headers = [
            "Host": host,
            "Date": dateString,
            "Authorization": "OSS \(token.accessKeyId):\(signature)",
            "x-oss-security-token": token.securityToken,
            "Content-Length": "\(data.count)"
        ]
        
        let (_, response) = try await makeRequest(url: url, method: "PUT", headers: headers, body: data)
        guard response.statusCode == 200 else {
            throw CloudServiceError.serviceError(response.statusCode, "OSS upload part failed")
        }
        
        let etag = response.allHeaderFields["Etag"] as? String ?? response.allHeaderFields["ETag"] as? String ?? ""
        return UploadPart(partNumber: partNumber, eTag: etag)
    }
    
    private func completeMultipartUpload(parts: [UploadPart], uploadId: String, endpoint: String, bucket: String, objectKey: String, token: UploadToken, callback: [String: String]) async throws -> Data {
        let host = "\(bucket).\(endpoint)"
        let url = URL(string: "https://\(host)/\(objectKey)?uploadId=\(uploadId)")!
        let dateString = gmtDateString()
        
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            xml += "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(part.eTag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let bodyData = xml.data(using: .utf8)!
        
        let callbackJson = callback.json
        let callbackBase64 = callbackJson.data(using: .utf8)?.base64EncodedString() ?? ""
        
        let signature = ossSignature(method: "POST", bucket: bucket, objectKey: objectKey + "?uploadId=\(uploadId)", date: dateString, token: token, callback: callbackBase64)
        
        let headers = [
            "Host": host,
            "Date": dateString,
            "Authorization": "OSS \(token.accessKeyId):\(signature)",
            "x-oss-security-token": token.securityToken,
            "x-oss-callback": callbackBase64,
            "Content-Length": "\(bodyData.count)"
        ]
        
        let (data, response) = try await makeRequest(url: url, method: "POST", headers: headers, body: bodyData)
        guard response.statusCode == 200 else {
            throw CloudServiceError.serviceError(response.statusCode, "OSS complete upload failed")
        }
        
        return data
    }
    
    private func makeRequest(url: URL, method: String, headers: [String: String], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let httpResponse = response as? HTTPURLResponse {
                    continuation.resume(returning: (data, httpResponse))
                } else {
                    continuation.resume(throwing: CloudServiceError.unsupported)
                }
            }
            task.resume()
        }
    }
    
    private func gmtDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss z"
        return formatter.string(from: Date())
    }
    
    private func ossSignature(method: String, bucket: String, objectKey: String, date: String, token: UploadToken, callback: String? = nil) -> String {
        var stringToSign = "\(method)\n\n\n\(date)\n"
        stringToSign += "x-oss-security-token:\(token.securityToken)\n"
        if let callback = callback, !callback.isEmpty {
            stringToSign += "x-oss-callback:\(callback)\n"
        }
        stringToSign += "/\(bucket)/\(objectKey)"
        
        let key = SymmetricKey(data: token.accessKeySecret.data(using: .utf8)!)
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: stringToSign.data(using: .utf8)!, using: key)
        return Data(signature).base64EncodedString()
    }
}

fileprivate struct UploadPart: Codable, Sendable {
    let partNumber: Int
    let eTag: String
}
