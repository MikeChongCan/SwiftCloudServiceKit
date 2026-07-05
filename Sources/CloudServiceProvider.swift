import Foundation

/// The general response with CloudServiceProvider.
public struct CloudResponse<HTTPResult, Failure: Error>: Sendable where HTTPResult: Sendable {
    
    /// The origin http response. Maybe `nil` if throws error by CloudServiceKit.
    public let response: HTTPResult?
    
    /// The result of response.
    public let result: Result<HTTPResult, Failure>
    
    public init(response: HTTPResult?, result: Result<HTTPResult, Failure>) {
        self.response = response
        self.result = result
    }
}

/// Common completion handler for cloud file operations, such as copy/move/rename
/// Note: The completion block will called in main-thread.
public typealias CloudCompletionHandler = @MainActor @Sendable (CloudResponse<HTTPResult, Error>) -> Void

/// Cloud refresh acess token handler.
public typealias CloudRefreshAccessTokenHandler = @Sendable () async throws -> URLCredential

// CloudServiceResponseProcessing
@MainActor
public protocol CloudServiceResponseProcessing: Sendable {
    
    /// Parse `CloudItem` from JSON.
    /// - Parameter json: JSON object of file item.
    static func cloudItemFromJSON(_ json: [String: Any]) -> CloudItem?
    
    /// Return `true` if service provider wants to process the response. Default value is `false`.
    /// - Parameters:
    ///   - response: The response object to be processed.
    ///   - completion: The completion block.
    func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool
    
    func isUnauthorizedResponse(_ response: HTTPResult) -> Bool
}

/// Some cloud service (eg: BaiduPan, Dropbox) supports batch operations
@MainActor
public protocol CloudServiceBatching: Sendable {
    
    /// Remove items.
    /// - Parameters:
    ///   - items: The items to be removed.
    func removeItems(_ items: [CloudItem]) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Move items to target directory.
    /// - Parameters:
    ///   - items: The items to be moved.
    ///   - directory: The target directory.
    func moveItems(_ items: [CloudItem], to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error>
}

@MainActor
public protocol CloudServiceProviderDelegate: AnyObject, Sendable {
    func renewAccessToken(withRefreshToken refreshToken: String) async throws -> URLCredential
}

/// The protocol of cloud service provider.
@MainActor
public protocol CloudServiceProvider: AnyObject, CloudServiceResponseProcessing {

    var session: URLSession { get }

    var delegate: CloudServiceProviderDelegate? { get set }
    
    /// The name the cloud service.
    var name: String { get }
    
    /// The credential to login with cloud service.
    var credential: URLCredential? { get set }
    
    /// The refresh token to refresh the access token. If provided, CloudSeriveKit will automatically handle the access token expires.
    /// Note: The access token of some cloud service (eg: OneDrive) are short time. So we need a refresh token to refresh the access token when expired.
    var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler? { get set }
    
    /// The root path of cloud service. You can use this property to load contents at root directory.
    var rootItem: CloudItem { get }
    
    init(credential: URLCredential?)
    
    /// Get attributes of cloud item.
    func attributesOfItem(_ item: CloudItem) async throws -> CloudItem
    
    /// Load the contents at directory.
    func contentsOfDirectory(_ directory: CloudItem) async throws -> [CloudItem]
    
    /// Copy item to directory
    func copyItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Create folder at directory.
    func createFolder(_ folderName: String, at directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Get the space usage information for the current user's account.
    func getCloudSpaceInformation() async throws -> CloudSpaceInformation
    
    /// Get information about the current user's account.
    func getCurrentUserInfo() async throws -> CloudUser
    
    /// Move item to target directory.
    func moveItem(_ item: CloudItem, to directory: CloudItem) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Remove cloud file/folder item.
    func removeItem(_ item: CloudItem) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Rename cloud file/folder to a new name.
    func renameItem(_ item: CloudItem, newName: String) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Search files with provided keyword.
    func searchFiles(keyword: String) async throws -> [CloudItem]
    
    /// Upload file data to target directory.
    func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error>
    
    /// Upload file to target directory with local file url.
    func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: (@Sendable (Progress) -> Void)?) async throws -> CloudResponse<HTTPResult, Error>
}

// Backwards compatibility default implementations
extension CloudServiceProvider {
    
    public func attributesOfItem(_ item: CloudItem, completion: @escaping (Result<CloudItem, Error>) -> Void) {
        Task {
            do {
                let res = try await attributesOfItem(item)
                completion(.success(res))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public func contentsOfDirectory(_ directory: CloudItem, completion: @escaping (Result<[CloudItem], Error>) -> Void) {
        Task {
            do {
                let res = try await contentsOfDirectory(directory)
                completion(.success(res))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public func copyItem(_ item: CloudItem, to directory: CloudItem, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await copyItem(item, to: directory)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func createFolder(_ folderName: String, at directory: CloudItem, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await createFolder(folderName, at: directory)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func getCloudSpaceInformation(completion: @escaping (Result<CloudSpaceInformation, Error>) -> Void) {
        Task {
            do {
                let res = try await getCloudSpaceInformation()
                completion(.success(res))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public func getCurrentUserInfo(completion: @escaping (Result<CloudUser, Error>) -> Void) {
        Task {
            do {
                let res = try await getCurrentUserInfo()
                completion(.success(res))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public func moveItem(_ item: CloudItem, to directory: CloudItem, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await moveItem(item, to: directory)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func removeItem(_ item: CloudItem, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await removeItem(item)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func renameItem(_ item: CloudItem, newName: String, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await renameItem(item, newName: newName)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func searchFiles(keyword: String, completion: @escaping (Result<[CloudItem], Error>) -> Void) {
        Task {
            do {
                let res = try await searchFiles(keyword: keyword)
                completion(.success(res))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    public func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: @escaping @Sendable (Progress) -> Void, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await uploadData(data, filename: filename, to: directory, progressHandler: progressHandler)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
    
    public func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: @escaping @Sendable (Progress) -> Void, completion: @escaping CloudCompletionHandler) {
        Task {
            do {
                let res = try await uploadFile(fileURL, to: directory, progressHandler: progressHandler)
                completion(res)
            } catch {
                completion(CloudResponse(response: nil, result: .failure(error)))
            }
        }
    }
}

// Default implementation of CloudServiceProvider
extension CloudServiceProvider {
    
    public var refreshAccessTokenHandler: CloudRefreshAccessTokenHandler? {
        get { return nil }
        set { }
    }
    
    public var delegate: CloudServiceProviderDelegate? {
        get { return nil }
        set { }
    }
    
    public func shouldProcessResponse(_ response: HTTPResult, completion: @escaping CloudCompletionHandler) -> Bool {
        return false
    }
    
    public func isUnauthorizedResponse(_ response: HTTPResult) -> Bool {
        // most cloud service use http code 401 as unauthorized response
        return response.statusCode == 401
    }
}

// MARK: - Helper
extension CloudServiceProvider {
    
    public func fileSize(of fileURL: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attributes[.size] as? Int64
        } catch {
            print(error)
        }
        return nil
    }
    
}

// MARK: - Native HTTP Support Types

public protocol URLComponentsConvertible: Sendable {
    var urlComponents: URLComponents? { get }
}

extension String: URLComponentsConvertible {
    public var urlComponents: URLComponents? {
        return URLComponents(string: self)
    }
}

extension URL: URLComponentsConvertible {
    public var urlComponents: URLComponents? {
        return URLComponents(url: self, resolvingAgainstBaseURL: false)
    }
}

extension URLComponents: URLComponentsConvertible {
    public var urlComponents: URLComponents? {
        return self
    }
}

public enum HTTPMethod: String, Sendable {
    case delete = "DELETE"
    case get = "GET"
    case head = "HEAD"
    case options = "OPTIONS"
    case patch = "PATCH"
    case post = "POST"
    case put = "PUT"
}

public enum HTTPFile: Sendable {
    case url(URL, String?)
    case data(String, Data, String?)
    case text(String, String, String?)
}

public struct HTTPProgress: Sendable {
    public enum `Type`: Sendable {
        case upload
        case download
    }
    public let type: `Type`
    public let percent: Float
    public let bytesProcessed: Int64
    public let bytesExpectedToProcess: Int64
    
    public init(type: `Type`, percent: Float, bytesProcessed: Int64 = 0, bytesExpectedToProcess: Int64 = 0) {
        self.type = type
        self.percent = percent
        self.bytesProcessed = bytesProcessed
        self.bytesExpectedToProcess = bytesExpectedToProcess
    }
}

public struct HTTPResult: Sendable {
    public let content: Data?
    public let response: HTTPURLResponse?
    public let error: Error?
    
    public init(data: Data? = nil, response: HTTPURLResponse? = nil, error: Error? = nil, task: URLSessionTask? = nil) {
        self.content = data
        self.response = response
        self.error = error
    }
    
    public var data: Data? {
        return content
    }
    
    public var statusCode: Int? {
        return response?.statusCode
    }
    
    public var headers: [AnyHashable: Any] {
        guard let response = response else { return [:] }
        var lowercasedHeaders: [String: Any] = [:]
        for (key, value) in response.allHeaderFields {
            if let stringKey = key as? String {
                lowercasedHeaders[stringKey.lowercased()] = value
            } else {
                lowercasedHeaders["\(key)"] = value
            }
        }
        return lowercasedHeaders
    }
    
    public var json: Any? {
        guard let data = content else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }
    
    public var text: String? {
        guard let data = content else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class HTTPTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progressHandler: @Sendable (HTTPProgress) -> Void
    
    init(progressHandler: @escaping @Sendable (HTTPProgress) -> Void) {
        self.progressHandler = progressHandler
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let percent = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        progressHandler(HTTPProgress(type: .upload, percent: percent, bytesProcessed: totalBytesSent, bytesExpectedToProcess: totalBytesExpectedToSend - totalBytesSent))
    }
}

// MARK: - HTTP Requests (Async wrappers)
extension CloudServiceProvider {
    
    public var session: URLSession {
        return .shared
    }
    
    public func get(
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        headers: [String: String] = [:],
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await request(.get, url: url, params: params, headers: headers, progressHandler: progressHandler)
    }
    
    public func post(
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        json: Any? = nil,
        headers: [String: String] = [:],
        files: [String: HTTPFile] = [:],
        requestBody: Data? = nil,
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await request(.post, url: url, params: params, data: data, json: json, headers: headers, files: files, requestBody: requestBody, progressHandler: progressHandler)
    }
    
    public func delete(
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        headers: [String: String] = [:]
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await request(.delete, url: url, params: params, data: data, headers: headers)
    }
    
    public func put(
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        json: Any? = nil,
        headers: [String: String] = [:],
        files: [String: HTTPFile] = [:],
        requestBody: Data? = nil,
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await request(.put, url: url, params: params, data: data, json: json, headers: headers, files: files, requestBody: requestBody, progressHandler: progressHandler)
    }
    
    public func patch(
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        json: Any? = nil,
        headers: [String: String] = [:]
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await request(.patch, url: url, params: params, data: data, json: json, headers: headers)
    }
    
    public func request(
        _ method: HTTPMethod,
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        json: Any? = nil,
        headers: [String: String] = [:],
        files: [String: HTTPFile] = [:],
        requestBody: Data? = nil,
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil
    ) async throws -> CloudResponse<HTTPResult, Error> {
        try await withCheckedThrowingContinuation { continuation in
            request(method, url: url, params: params, data: data, json: json, headers: headers, files: files, requestBody: requestBody, progressHandler: progressHandler) { response in
                switch response.result {
                case .success(_):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func query(_ params: [String: Any]) -> String {
        var parts: [String] = []
        for (key, val) in params {
            let keyString = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let valString = "\(val)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(val)"
            parts.append("\(keyString)=\(valString)")
        }
        return parts.joined(separator: "&")
    }
    
    private func synthesizeMultipartBody(_ data: [String: Any], files: [String: HTTPFile], boundary: String) -> Data {
        var body = Data()
        let boundaryData = "--\(boundary)\r\n".data(using: .utf8)!
        let endBoundaryData = "--\(boundary)--\r\n".data(using: .utf8)!
        
        for (key, val) in data {
            body.append(boundaryData)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(val)\r\n".data(using: .utf8)!)
        }
        
        for (key, file) in files {
            body.append(boundaryData)
            var partContent: Data?
            var partFilename: String?
            var partMimeType: String?
            
            switch file {
            case let .url(url, mimeType):
                partFilename = url.lastPathComponent
                partContent = try? Data(contentsOf: url)
                partMimeType = mimeType
            case let .text(filename, text, mimeType):
                partFilename = filename
                partContent = text.data(using: .utf8)
                partMimeType = mimeType
            case let .data(filename, data, mimeType):
                partFilename = filename
                partContent = data
                partMimeType = mimeType
            }
            
            if let content = partContent, let filename = partFilename {
                body.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                if let mime = partMimeType {
                    body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
                } else {
                    body.append("\r\n".data(using: .utf8)!)
                }
                body.append(content)
                body.append("\r\n".data(using: .utf8)!)
            }
        }
        
        if !data.isEmpty || !files.isEmpty {
            body.append(endBoundaryData)
        }
        return body
    }
    
    // Core callback-based request method that interacts with URLSession
    private func request(
        _ method: HTTPMethod,
        url urlConvertible: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: [String: Any] = [:],
        json: Any? = nil,
        headers: [String: String] = [:],
        files: [String: HTTPFile] = [:],
        requestBody: Data? = nil,
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil,
        completion: @escaping CloudCompletionHandler
    ) {
        guard let url = urlConvertible.urlComponents?.url else {
            let res = HTTPResult(error: CloudServiceError.serviceError(-1, "Invalid URL"))
            completion(CloudResponse(response: res, result: .failure(CloudServiceError.serviceError(-1, "Invalid URL"))))
            return
        }
        
        var finalURL = url
        if !params.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let qString = query(params)
            if !qString.isEmpty {
                comps?.percentEncodedQuery = qString
            }
            if let u = comps?.url {
                finalURL = u
            }
        }
        
        var request = URLRequest(url: finalURL)
        request.httpMethod = method.rawValue
        
        var httpheaders = headers
        if let token = credential?.password {
            httpheaders["Authorization"] = "Bearer \(token)"
        }
        
        var bodyData: Data?
        var contentType: String?
        
        if let requestData = requestBody {
            bodyData = requestData
        } else if !files.isEmpty {
            let boundary = "CloudServiceKitBoundary-\(UUID().uuidString)"
            bodyData = synthesizeMultipartBody(data, files: files, boundary: boundary)
            contentType = "multipart/form-data; boundary=\(boundary)"
        } else if let requestJSON = json {
            bodyData = try? JSONSerialization.data(withJSONObject: requestJSON, options: [])
            contentType = "application/json"
        } else if !data.isEmpty {
            if headers["Content-Type"]?.lowercased() == "application/json" || headers["content-type"]?.lowercased() == "application/json" {
                bodyData = try? JSONSerialization.data(withJSONObject: data, options: [])
                contentType = "application/json"
            } else {
                bodyData = query(data).data(using: .utf8)
                contentType = "application/x-www-form-urlencoded"
            }
        }
        
        if let content = contentType {
            request.setValue(content, forHTTPHeaderField: "Content-Type")
        }
        for (key, val) in httpheaders {
            request.setValue(val, forHTTPHeaderField: key)
        }
        request.httpBody = bodyData
        
        let taskDelegate = progressHandler.map { HTTPTaskDelegate(progressHandler: $0) }
        let requestSession = self.session
        
        Task {
            do {
                let data: Data
                let response: URLResponse
                if let bodyData = bodyData, (method == .post || method == .put || method == .patch) {
                    (data, response) = try await requestSession.upload(for: request, from: bodyData, delegate: taskDelegate)
                } else {
                    (data, response) = try await requestSession.data(for: request, delegate: taskDelegate)
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CloudServiceError.serviceError(-1, "Invalid HTTP response")
                }
                
                let result = HTTPResult(data: data, response: httpResponse)
                self.handleResponse(result,
                                    method: method,
                                    url: urlConvertible,
                                    params: params,
                                    data: data, // Note: passing empty dictionary for data because handleResponse doesn't parse it
                                    json: json,
                                    headers: headers,
                                    requestBody: requestBody,
                                    progressHandler: progressHandler,
                                    completion: completion)
            } catch {
                let result = HTTPResult(error: error)
                completion(CloudResponse(response: result, result: .failure(error)))
            }
        }
    }
    
    private func handleResponse(
        _ response: HTTPResult,
        method: HTTPMethod,
        url: URLComponentsConvertible,
        params: [String: Any] = [:],
        data: Any = [:],
        json: Any? = nil,
        headers: [String: String] = [:],
        requestBody: Data? = nil,
        progressHandler: (@Sendable (HTTPProgress) -> Void)? = nil,
        completion: @escaping CloudCompletionHandler
    ) {
        if isUnauthorizedResponse(response) {
            if let refreshAccessTokenHandler = refreshAccessTokenHandler {
                Task {
                    do {
                        let newCredential = try await refreshAccessTokenHandler()
                        self.credential = newCredential
                        self.request(method, url: url,
                                     params: params, headers: headers,
                                     progressHandler: progressHandler, completion: completion)
                    } catch {
                        completion(CloudResponse(response: response, result: .failure(error)))
                    }
                }
                return
            } else if let delegate = delegate {
                Task {
                    do {
                        if let refreshToken = credential?.user {
                            let newCredential = try await delegate.renewAccessToken(withRefreshToken: refreshToken)
                            self.credential = newCredential
                            self.request(method, url: url,
                                         params: params, headers: headers,
                                         progressHandler: progressHandler, completion: completion)
                        } else {
                            completion(CloudResponse(response: response, result: .failure(CloudServiceError.unsupported)))
                        }
                    } catch {
                        completion(CloudResponse(response: response, result: .failure(error)))
                    }
                }
                return
            }
        }
        
        if !shouldProcessResponse(response, completion: completion) {
            completion(CloudResponse(response: response, result: .success(response)))
        }
    }
}

struct ISO3601DateFormatter: Sendable {
    static let shared = ISO3601DateFormatter()

    private let secondsDateFormatter = DateFormatter()
    private let milisecondsDateFormatter = DateFormatter()

    init() {
        secondsDateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ssZ"
        milisecondsDateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'SSSZ"
    }
    
    func date(from dateString: String) -> Date? {
        return (secondsDateFormatter.date(from: dateString)
                    ?? milisecondsDateFormatter.date(from: dateString))
    }
    
    func date(fromBytes bytes: ArraySlice<UInt8>) -> Date? {
        guard let dateString = String(bytes: Array(bytes), encoding: .ascii) else { return nil }
        return (secondsDateFormatter.date(from: dateString)
            ?? milisecondsDateFormatter.date(from: dateString))
    }
}


