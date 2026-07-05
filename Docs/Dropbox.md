# Dropbox Setup Guide

This document describes how to configure the Dropbox App Console and integrate the Dropbox provider with your iOS application.

## 1. Configure Dropbox Developer Console

1. Navigate to the [Dropbox App Console](https://www.dropbox.com/developers/apps).
2. Click **Create app**.
3. Choose the API and access type:
   - Choose **Scoped access** (default).
   - Choose **Full Dropbox** or **App folder** access type.
   - Enter your App name and click **Create app**.
4. Go to the **Permissions** tab and check:
   - `files.metadata.write`
   - `files.metadata.read`
   - `files.content.write`
   - `files.content.read`
   - Click **Submit** at the bottom to save.
5. In the **Settings** tab:
   - Copy the **App key** (Client ID) and **App secret** (Client Secret).
   - Under **Redirect URIs**, add your custom redirect callback (e.g. `db-YOUR_APP_KEY://oauth` or `myappid://oauth-callback`).

## 2. Configure iOS App Custom URL Scheme

To receive the OAuth 2.0 redirect callback in your iOS application:

1. Open your project in Xcode.
2. Select your Target, navigate to the **Info** tab.
3. Expand the **URL Types** section.
4. Add a new URL type:
   - **Identifier**: `Dropbox OAuth Callback`
   - **URL Schemes**: `db-YOUR_APP_KEY`.

## 3. Integrating with CloudServiceKit

Initialize the `DropboxConnector` and authenticate:

```swift
let connector = DropboxConnector(
    appId: "YOUR_APP_KEY",
    appSecret: "YOUR_APP_SECRET",
    callbackUrl: "db-YOUR_APP_KEY://oauth"
)

// In your View Controller
try await connector.connectWithASWebAuthenticationSession(viewController: self)
```
