//
//  WebDAVServiceProvider.swift
//  CloudServiceKit
//
//  Created by Antigravity on 2026/7/5.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A WebDAV Cloud Service Provider implementing the CloudServiceProvider contract.
/// Fully compatible with Swift 6 strict concurrency checks.
@MainActor
public class WebDAVServiceProvider: NSObject, CloudServiceProvider, @unchecked Sendable {
    
    public weak var delegate: CloudServiceProviderDelegate?
    public var name: String { return "WebDAV" }
    public var credential: URLCredential?
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler?
    
    public let endpoint: URL
    public let session: URLSession
    
    public var rootItem: CloudItem {
        return CloudItem(id: "/", name: "Root", path: "/", isDirectory: true)
    }
    
    private var authHeader: [String: String] {
        guard let credential = credential,
              let user = credential.user,
              let password = credential.password else {
            return [:]
        }
        let credentialString = "\(user):\(password)"
        guard let credentialData = credentialString.data(using: .utf8) else {
            return [:]
        }
        let base64 = credentialData.base64EncodedString()
        return ["Authorization": "Basic \(base64)"]
    }
    
    public init(endpoint: URL, credential: URLCredential?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.credential = credential
        self.session = session
        super.init()
    }
    
    public required init(credential: URLCredential?) {
        self.credential = credential
        self.endpoint = URL(string: "http://localhost")!
        self.session = .shared
        super.init()
    }
    
    private func url(for path: String) -> URL {
        let basePath = endpoint.path.hasSuffix("/") ? endpoint.path : endpoint.path + "/"
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        
        if normalizedPath.hasPrefix(basePath) {
            let scheme = endpoint.scheme ?? "http"
            let host = endpoint.host ?? "localhost"
            let portStr = endpoint.port != nil ? ":\(endpoint.port!)" : ""
            let hostUrl = "\(scheme)://\(host)\(portStr)"
            return URL(string: hostUrl + normalizedPath) ?? endpoint
        } else {
            var base = endpoint
            if !base.path.hasSuffix("/") {
                base = base.appendingPathComponent("")
            }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return URL(string: relative, relativeTo: base) ?? base.appendingPathComponent(relative)
        }
    }
    
    private func makeRequest(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, val) in authHeader {
                request.setValue(val, forHTTPHeaderField: key)
            }
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
            if let body = body {
                request.httpBody = body
            }
            
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: CloudServiceError.serviceError(-1, "No data or response"))
                    return
                }
                continuation.resume(returning: (data, httpResponse))
            }
            task.resume()
        }
    }
    
    // MARK: - CloudServiceProvider Methods
    
    public func getCurrentUserInfo() async throws -> CloudUser {
        // No standard current-user API; PROPFIND Depth 0 on the endpoint so a
        // non-DAV or unauthorized root fails here instead of later at MKCOL.
        let requestUrl = url(for: rootItem.path)
        let (_, response) = try await makeRequest(
            method: "PROPFIND",
            url: requestUrl,
            headers: Self.propfindHeaders(depth: "0"),
            body: Self.propfindAllpropBody
        )
        guard response.statusCode == 200 || response.statusCode == 207 else {
            throw CloudServiceError.serviceError(response.statusCode, "PROPFIND current user probe failed")
        }
        let username = credential?.user ?? "WebDAV User"
        return CloudUser(username: username, json: [:])
    }
    
    public func getCloudSpaceInformation() async throws -> CloudSpaceInformation {
        // WebDAV has no standardized space info API, return mock/empty values
        return CloudSpaceInformation(totalSpace: 0, availableSpace: 0, json: [:])
    }
    
    public func searchFiles(keyword: String) async throws -> [CloudItem] {
        return []
    }
    
    public func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem] {
        let requestUrl = url(for: directory.path)
        let propfindPayload = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:allprop/>
        </D:propfind>
        """.data(using: .utf8)
        
        let headers = Self.propfindHeaders(depth: "1")
        
        let (data, response) = try await makeRequest(method: "PROPFIND", url: requestUrl, headers: headers, body: propfindPayload)
        guard response.statusCode == 200 || response.statusCode == 207 else {
            throw CloudServiceError.serviceError(response.statusCode, "PROPFIND directory contents failed")
        }
        
        let parser = WebDAVXMLParser()
        let parsedItems = parser.parse(data: data)
        
        var items: [CloudItem] = []
        
        for item in parsedItems {
            let urlPath = Self.hrefPath(item.href)
            let normalizedPath = Self.normalizedDAVPath(urlPath)
            
            // Skip the listed collection. Compare against the request URL path,
            // not CloudItem.path: rootItem.path is "/" while hrefs carry the
            // full server path (e.g. /remote.php/dav/files/user/).
            if Self.shouldSkipListedDirectory(
                itemPath: normalizedPath,
                directory: directory,
                requestURL: requestUrl
            ) {
                continue
            }
            
            let name = (normalizedPath as NSString).lastPathComponent
            let cloudItem = CloudItem(
                id: normalizedPath,
                name: name,
                path: normalizedPath,
                isDirectory: item.isDirectory
            )
            items.append(cloudItem)
        }
        return items
    }
    
    public func attributesOfItem(_ item: CloudItem) async throws -> CloudItem {
        let requestUrl = url(for: item.path)
        let propfindPayload = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:allprop/>
        </D:propfind>
        """.data(using: .utf8)
        
        let headers = Self.propfindHeaders(depth: "0")
        
        let (data, response) = try await makeRequest(method: "PROPFIND", url: requestUrl, headers: headers, body: propfindPayload)
        guard response.statusCode == 200 || response.statusCode == 207 else {
            throw CloudServiceError.serviceError(response.statusCode, "PROPFIND attributes failed")
        }
        
        let parser = WebDAVXMLParser()
        let parsedItems = parser.parse(data: data)
        guard let parsed = parsedItems.first else {
            throw CloudServiceError.serviceError(response.statusCode, "Empty PROPFIND attributes response")
        }
        
        return CloudItem(
            id: item.path,
            name: item.name,
            path: item.path,
            isDirectory: parsed.isDirectory
        )
    }
    
    public func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let parentPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let targetPath = parentPath + folderName
        let requestUrl = url(for: targetPath)
        
        let (_, response) = try await makeRequest(method: "MKCOL", url: requestUrl)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 201 {
            return CloudResponse(response: result, result: .success(result))
        }
        // Nextcloud/ownCloud return 405 when the collection already exists.
        // Synology and non-MKCOL roots also return 405 when the method is
        // not allowed. Only treat 405 as success after PROPFIND confirms a collection.
        if response.statusCode == 405 {
            if try await collectionExists(at: targetPath) {
                return CloudResponse(response: result, result: .success(result))
            }
            return CloudResponse(
                response: result,
                result: .failure(CloudServiceError.serviceError(
                    405,
                    "MKCOL not allowed at \(targetPath)"
                ))
            )
        }
        return CloudResponse(
            response: result,
            result: .failure(CloudServiceError.serviceError(
                response.statusCode,
                "MKCOL failed at \(targetPath)"
            ))
        )
    }
    
    public func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let parentPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let targetPath = parentPath + item.name
        let sourceUrl = url(for: item.path)
        let destinationUrl = url(for: targetPath)
        
        let headers = [
            "Destination": destinationUrl.absoluteString,
            "Overwrite": "T"
        ]
        
        let (_, response) = try await makeRequest(method: "COPY", url: sourceUrl, headers: headers)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 201 || response.statusCode == 204 {
            return CloudResponse(response: result, result: .success(result))
        } else {
            return CloudResponse(response: result, result: .failure(CloudServiceError.serviceError(response.statusCode, "COPY failed")))
        }
    }
    
    public func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let parentPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let targetPath = parentPath + item.name
        let sourceUrl = url(for: item.path)
        let destinationUrl = url(for: targetPath)
        
        let headers = [
            "Destination": destinationUrl.absoluteString,
            "Overwrite": "T"
        ]
        
        let (_, response) = try await makeRequest(method: "MOVE", url: sourceUrl, headers: headers)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 201 || response.statusCode == 204 {
            return CloudResponse(response: result, result: .success(result))
        } else {
            return CloudResponse(response: result, result: .failure(CloudServiceError.serviceError(response.statusCode, "MOVE failed")))
        }
    }
    
    public func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error> {
        let parentPath = (item.path as NSString).deletingLastPathComponent
        let targetPath = parentPath.hasSuffix("/") ? parentPath + newName : parentPath + "/" + newName
        let sourceUrl = url(for: item.path)
        let destinationUrl = url(for: targetPath)
        
        let headers = [
            "Destination": destinationUrl.absoluteString,
            "Overwrite": "T"
        ]
        
        let (_, response) = try await makeRequest(method: "MOVE", url: sourceUrl, headers: headers)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 201 || response.statusCode == 204 {
            return CloudResponse(response: result, result: .success(result))
        } else {
            return CloudResponse(response: result, result: .failure(CloudServiceError.serviceError(response.statusCode, "MOVE (rename) failed")))
        }
    }
    
    public func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error> {
        let requestUrl = url(for: item.path)
        let (_, response) = try await makeRequest(method: "DELETE", url: requestUrl)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 200 || response.statusCode == 204 {
            return CloudResponse(response: result, result: .success(result))
        } else {
            return CloudResponse(response: result, result: .failure(CloudServiceError.serviceError(response.statusCode, "DELETE failed")))
        }
    }
    
    public func getFileData(_ item: CloudItem, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let requestUrl = url(for: item.path)
        let (data, response) = try await makeRequest(method: "GET", url: requestUrl)
        guard response.statusCode == 200 else {
            throw CloudServiceError.serviceError(response.statusCode, "GET failed")
        }
        progressHandler?(Progress(totalUnitCount: Int64(data.count)))
        return data
    }
    
    public func downloadData(item: CloudItem, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        return try await getFileData(item, progressHandler: progressHandler)
    }
    
    public func downloadData(fileId: String, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> Data {
        let item = CloudItem(id: fileId, name: (fileId as NSString).lastPathComponent, path: fileId, isDirectory: false)
        return try await getFileData(item, progressHandler: progressHandler)
    }
    
    public func createFile(_ filename: String, at directory: CloudItem, data: Data, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> CloudResponse<HTTPResult, Error> {
        let parentPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let targetPath = parentPath + filename
        let requestUrl = url(for: targetPath)
        
        let headers = [
            "Content-Type": "application/octet-stream"
        ]
        
        progressHandler?(Progress(totalUnitCount: Int64(data.count)))
        let (_, response) = try await makeRequest(method: "PUT", url: requestUrl, headers: headers, body: data)
        let result = HTTPResult(data: nil, response: response, error: nil, task: nil)
        
        if response.statusCode == 200 || response.statusCode == 201 || response.statusCode == 204 {
            return CloudResponse(response: result, result: .success(result))
        } else {
            return CloudResponse(response: result, result: .failure(CloudServiceError.serviceError(response.statusCode, "PUT failed")))
        }
    }
    
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        return try await createFile(filename, at: directory, data: data, progressHandler: progressHandler)
    }
    
    public func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error> {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        return try await createFile(filename, at: directory, data: data, progressHandler: progressHandler)
    }
    
    public func download(_ item: CloudItem, to fileURL: URL, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> URL {
        let data = try await getFileData(item, progressHandler: progressHandler)
        try data.write(to: fileURL)
        return fileURL
    }
    
    public func upload(_ fileURL: URL, at directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws -> CloudItem {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let response = try await createFile(filename, at: directory, data: data, progressHandler: progressHandler)
        
        switch response.result {
        case .success:
            let parentPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            let targetPath = parentPath + filename
            return CloudItem(id: targetPath, name: filename, path: targetPath, isDirectory: false)
        case .failure(let error):
            throw error
        }
    }
    
    // MARK: - CloudServiceResponseProcessing
    
    public static func cloudItemFromJSON(_ json: [String: Any]) -> CloudItem? {
        return nil
    }
    
    public func isUnauthorizedResponse(_ response: HTTPResult) -> Bool {
        return response.statusCode == 401
    }

    private static let propfindAllpropBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:allprop/>
        </D:propfind>
        """.data(using: .utf8)

    private static func propfindHeaders(depth: String) -> [String: String] {
        [
            "Content-Type": "application/xml; charset=utf-8",
            "Depth": depth
        ]
    }

    private static func hrefPath(_ href: String) -> String {
        if let decodedHref = href.removingPercentEncoding {
            if let url = URL(string: decodedHref) {
                return url.path
            }
            return decodedHref
        }
        return href
    }

    private static func normalizedDAVPath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func shouldSkipListedDirectory(
        itemPath: String,
        directory: CloudItem,
        requestURL: URL
    ) -> Bool {
        if itemPath == normalizedDAVPath(requestURL.path) {
            return true
        }
        if directory.path != "/" {
            return itemPath == normalizedDAVPath(directory.path)
        }
        return false
    }

    private func collectionExists(at path: String) async throws -> Bool {
        let item = CloudItem(
            id: path,
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: true
        )
        do {
            let attributes = try await attributesOfItem(item)
            return attributes.isDirectory
        } catch {
            if case CloudServiceError.serviceError(404, _) = error {
                return false
            }
            throw error
        }
    }
}

// MARK: - WebDAVXMLParser

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    
    private static let lastModifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    
    struct ParsedItem: Sendable {
        var href: String = ""
        var isDirectory: Bool = false
        var contentLength: Int64 = 0
        var lastModified: Date?
        var etag: String = ""
    }
    
    private var items: [ParsedItem] = []
    private var currentItem: ParsedItem?
    private var currentElement: String = ""
    private var currentText: String = ""
    
    func parse(data: Data) -> [ParsedItem] {
        items = []
        currentItem = nil
        currentElement = ""
        currentText = ""
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? elementName.lowercased()
        currentElement = name
        currentText = ""
        
        if name == "response" {
            currentItem = ParsedItem()
        } else if name == "collection" {
            currentItem?.isDirectory = true
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if name == "response" {
            if let item = currentItem {
                items.append(item)
            }
            currentItem = nil
        } else if name == "href" {
            currentItem?.href = text
        } else if name == "getcontentlength" {
            currentItem?.contentLength = Int64(text) ?? 0
        } else if name == "getlastmodified" {
            currentItem?.lastModified = Self.lastModifiedFormatter.date(from: text)
        } else if name == "getetag" {
            currentItem?.etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
}
