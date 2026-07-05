---
name: integrate-cloud-service-kit
description: Guide developers to integrate CloudServiceKit, configure providers (WebDAV, OneDrive, Google Drive), and perform file/folder operations using Swift 6 async/await.
---
# Integrating CloudServiceKit

This guide explains how to integrate and use `CloudServiceKit` to perform file operations across different cloud providers using native Swift 6 async/await.

## Swift Package Integration

Add `CloudServiceKit` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/MikeChongCan/SwiftCloudServiceKit.git", from: "0.2.0")
]
```

Or add it directly in Xcode's Package Dependencies settings using the URL:
`https://github.com/MikeChongCan/SwiftCloudServiceKit.git`

---

## Service Provider Quick Setup

### 1. WebDAV (Basic Authentication)
Initialize a `WebDAVServiceProvider` with the server endpoint URL and basic credentials.

```swift
import CloudServiceKit

let endpoint = URL(string: "https://example.com/dav/")!
let credential = URLCredential(user: "username", password: "password", persistence: .none)
let provider = WebDAVServiceProvider(endpoint: endpoint, credential: credential)
```

### 2. Google Drive (OAuth)
Initialize a `GoogleDriveServiceProvider` with the authenticated OAuth credentials.

```swift
import CloudServiceKit

let credential = URLCredential(user: "user_email", password: "oauth_access_token", persistence: .none)
let provider = GoogleDriveServiceProvider(credential: credential)
```

### 3. OneDrive (OAuth)
Initialize a `OneDriveServiceProvider` with the authenticated OAuth credentials.

```swift
import CloudServiceKit

let credential = URLCredential(user: "user_email", password: "oauth_access_token", persistence: .none)
let provider = OneDriveServiceProvider(credential: credential)

// Shared / team drives: pass an explicit route
// let provider = OneDriveServiceProvider(credential: credential, route: .drive("DRIVE_ID"))
```

---

## Large file uploads

For clips or other multi-GB files, **do not** use `uploadData` — it loads the entire file into memory.

Use `uploadFile` for one-shot chunked uploads from disk:

```swift
try await provider.uploadFile(localFileURL, to: parentDirectory) { progress in
    print("Uploaded: \(Int(progress.fractionCompleted * 100))%")
}
```

Google Drive and OneDrive also support pause/resume via `CloudResumableUploading`:

```swift
var session = try await googleProvider.beginUpload(
    fileURL: localFileURL,
    filename: "clip.mov",
    to: parentDirectory,
    contentType: "video/quicktime"
)
session = try await googleProvider.uploadAllChunks(session: &session) { progress in }
let remoteItem = try await googleProvider.finishUpload(session: session)
// Persist `session` as JSON between app launches to resume later
```

Chunk reads run off the main actor; provider APIs remain `@MainActor`.

### Background `URLSession` (0.2.0+)

The host app owns the background `URLSession` and delegate. CloudServiceKit builds requests and parses responses:

```swift
// After relaunch — resync offset from server
let status = try await CloudBackgroundUpload.queryUploadStatus(session: persistedSession)
// Build next PUT (no body — use uploadTask(with:fromFile:))
let plan = try CloudBackgroundUpload.chunkUploadPlan(for: persistedSession, preferredLength: nil)
try await FileRegionWriter.writeRegion(of: sourceURL, range: plan.fileRange, to: tempFileURL)
// Enqueue background upload with plan.request + tempFileURL
// In URLSession delegate:
let outcome = CloudBackgroundUpload.parseChunkResponse(httpResponse, data: data, for: persistedSession)
```

See `Docs/BackgroundUploadSupport.md` for Google (whole-remainder PUT) vs OneDrive (≤60 MiB, 320 KiB-aligned) rules.

### Injectable `URLSession` (tests / custom config)

Every provider accepts an optional session after the required credential initializer:

```swift
let provider = GoogleDriveServiceProvider(
    credential: credential,
    session: URLSession(configuration: .ephemeral)
)
```

---

## File Operations Cheat Sheet

All operations are designed to run asynchronously on the `@MainActor` and return native models.

### 1. Listing Directory Contents
Fetch `CloudItem`s inside a directory:

```swift
let root = provider.rootItem
do {
    let items = try await provider.contentsOfDirectory(root)
    for item in items {
        print("Name: \(item.name), Is Directory: \(item.isDirectory), Path: \(item.path)")
    }
} catch {
    print("Failed to list directory: \(error)")
}
```

### 2. Downloading File Data
Download binary contents of a `CloudItem` file:

```swift
do {
    let fileData = try await provider.getFileData(fileItem)
    print("Downloaded \(fileData.count) bytes.")
} catch {
    print("Failed to download file: \(error)")
}
```

### 3. Uploading Data with Progress (small files only)

Upload binary `Data` to a directory for **small files** (a few MB). For larger files, use `uploadFile` or `CloudResumableUploading` (see above).

```swift
do {
    let response = try await provider.uploadData(
        fileData,
        filename: "document.pdf",
        to: parentDirectory
    ) { progress in
        print("Uploaded: \(Int(progress.fractionCompleted * 100))%")
    }
    
    if case .success = response.result {
        print("Upload successful!")
    }
} catch {
    print("Failed to upload: \(error)")
}
```

### 4. Creating a Folder
Create a new folder inside a parent directory:

```swift
do {
    let response = try await provider.createFolder("New Folder", at: parentDirectory)
    if case .success = response.result {
        print("Folder created successfully!")
    }
} catch {
    print("Failed to create folder: \(error)")
}
```

### 5. Deleting an Item
Remove a file or folder:

```swift
do {
    let response = try await provider.removeItem(item)
    if case .success = response.result {
        print("Item deleted successfully!")
    }
} catch {
    print("Failed to delete item: \(error)")
}
```
