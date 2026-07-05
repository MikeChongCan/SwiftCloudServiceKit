import Foundation

enum OneDriveUploadURLs {
    /// Graph path syntax for creating a new upload session.
    /// See: https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession
    static func createUploadSession(
        routePrefix: String,
        parentItemID: String,
        filename: String
    ) -> URL {
        let encodedName = filename.urlEncoded
        var components = URLComponents()
        components.scheme = "https"
        components.host = "graph.microsoft.com"
        components.percentEncodedPath =
            "/v1.0\(routePrefix)/drive/items/\(parentItemID):/\(encodedName):/createUploadSession"
        guard let url = components.url else {
            preconditionFailure("Invalid OneDrive createUploadSession URL")
        }
        return url
    }
}
