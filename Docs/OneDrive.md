# OneDrive Setup Guide

This document describes how to configure the Microsoft Entra Admin Center and integrate the OneDrive provider with your iOS application.

## 1. Configure Microsoft Entra Admin Center

1. Navigate to the [Microsoft Entra Admin Center](https://entra.microsoft.com/).
2. Go to **Identity** -> **Applications** -> **App registrations** -> **New registration**.
3. Fill in registration details:
   - **Name**: Your application name.
   - **Supported account types**: Choose **Accounts in any organizational directory (Any Microsoft Entra ID tenant - Multitenant) and personal Microsoft accounts (e.g. Skype, Xbox)**.
   - **Redirect URI**: Select **Public client/mobile (pc, mobile, phone)** and enter a callback URL (e.g., `msalYOUR_CLIENT_ID://auth` or `myappid://oauth-callback`).
4. Click **Register**. Copy the **Application (client) ID**.
5. Under **API permissions**:
   - Click **Add a permission** -> **Microsoft Graph** -> **Delegated permissions**.
   - Search for and select `Files.ReadWrite` or `Files.ReadWrite.All` (for all drives access).
   - Also add `offline_access` if you need refresh tokens for long-lived access.
   - Click **Add permissions**.

## 2. Configure iOS App Custom URL Scheme

To receive the OAuth 2.0 redirect callback in your iOS application:

1. Open your project in Xcode.
2. Select your Target, navigate to the **Info** tab.
3. Expand the **URL Types** section.
4. Add a new URL type:
   - **Identifier**: `OneDrive OAuth Callback`
   - **URL Schemes**: e.g., `msalYOUR_CLIENT_ID` or `myappid`.

## 3. Integrating with CloudServiceKit

Initialize the `OneDriveConnector` and authenticate:

```swift
let connector = OneDriveConnector(
    appId: "YOUR_CLIENT_ID",
    appSecret: "", // Leave blank for Public Client iOS Apps
    callbackUrl: "msalYOUR_CLIENT_ID://auth"
)

// In your View Controller
try await connector.connectWithASWebAuthenticationSession(viewController: self)
```
