# Google Drive Setup Guide

This document describes how to configure the Google Cloud Console and integrate the Google Drive provider with your iOS application.

## 1. Configure Google Cloud Console

1. Navigate to the [Google Cloud Console](https://console.cloud.google.com/).
2. Create a new project or select an existing one.
3. Search for **Google Drive API** and click **Enable**.
4. Configure the **OAuth Consent Screen**:
   - Set user type (External/Internal).
   - Enter your App name, user support email, and developer contact information.
   - Under **Scopes**, add `https://www.googleapis.com/auth/drive` or `https://www.googleapis.com/auth/drive.file` (limits access to files created by your app).
   - Add test users if the app is in "Testing" mode.
5. Create credentials:
   - Go to **Credentials** -> **Create Credentials** -> **OAuth client ID**.
   - Select **iOS** as the application type.
   - Enter your **Bundle ID** and **App Store ID** (optional).
   - Click **Create**. Copy the generated **Client ID** and **Client Secret**.

## 2. Configure iOS App Custom URL Scheme

To receive the OAuth 2.0 redirect callback in your iOS application, you must add the reverse client ID (or a custom scheme) as a URL scheme.

1. Open your project in Xcode.
2. Select your Target, navigate to the **Info** tab.
3. Expand the **URL Types** section.
4. Add a new URL type:
   - **Identifier**: `Google OAuth Callback`
   - **URL Schemes**: The reverse of your client ID (e.g., `com.googleusercontent.apps.1234567890-abcdefg`).
5. In your `Info.plist`, verify the configuration:
   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLSchemes</key>
           <array>
               <string>com.googleusercontent.apps.1234567890-abcdefg</string>
           </array>
       </dict>
   </array>
   ```

## 3. Integrating with CloudServiceKit

Initialize the `GoogleDriveConnector` and present the authentication session:

```swift
let connector = GoogleDriveConnector(
    appId: "YOUR_CLIENT_ID",
    appSecret: "YOUR_CLIENT_SECRET",
    callbackUrl: "com.googleusercontent.apps.YOUR_REVERSE_CLIENT_ID:/oauth2redirect"
)

// In your View Controller
try await connector.connectWithASWebAuthenticationSession(viewController: self)
```

## 4. Large file uploads

For clips or other multi-GB files, use **`uploadFile(_:to:progressHandler:)`** or the resumable API — never `uploadData`, which loads the entire file into memory.

```swift
let provider = GoogleDriveServiceProvider(credential: credential)

// One-shot chunked upload from disk
try await provider.uploadFile(localFileURL, to: folder, progressHandler: { progress in
    // update UI on main actor
})

// Pause/resume: persist CloudUploadSession to JSON between chunks
var session = try await provider.beginUpload(
    fileURL: localFileURL,
    filename: "clip.mov",
    to: folder,
    contentType: "video/quicktime"
)
session = try await provider.uploadAllChunks(session: &session) { progress in }
let remoteItem = try await provider.finishUpload(session: session)
```

Chunk reads run off the main actor via `FileChunkReader` so uploads do not block UI.
