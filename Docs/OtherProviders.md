# Setup Guide for Box, Aliyun Drive, Baidu Pan, 115, and 123

This document describes how to configure developer consoles and configure OAuth callback configurations for Box, Aliyun Drive, Baidu Pan, 115, and 123 Pan.

---

## 1. Box Setup

### Console Configuration
1. Navigate to the [Box Developer Console](https://developer.box.com/).
2. Create a **Custom App** using User Authentication (OAuth 2.0).
3. Under **Configuration**:
   - Copy the **Client ID** and **Client Secret**.
   - Add a Redirect URI (e.g. `box-YOUR_CLIENT_ID://oauth`).
4. Select the scopes:
   - `Read and write all files and folders stored in Box`.
   - `Manage webhooks` (optional).
5. Click **Save Changes**.

---

## 2. Aliyun Drive Setup

### Console Configuration
1. Navigate to the [Aliyun Drive Open Platform](https://open.aliyundrive.com/).
2. Create an Application and configure OAuth 2.0.
3. Add scopes: `user:base`, `file:all:read`, `file:all:write`.
4. Copy the **App Key** and **App Secret**.
5. Set your **Redirect URI** to receive OAuth callbacks in your iOS application.

---

## 3. Baidu Pan Setup

### Console Configuration
1. Navigate to the [Baidu Developer Console](https://open.baidu.com/).
2. Enable **Baidu Pan API** services.
3. Under App settings, set the Redirect URI and copy your **API Key** and **Secret Key**.
4. Set scopes to `basic,netdisk` for file listing and operations.

---

## 4. 115 and 123 Pan Setup

115 and 123 Pan use standard credentials (API key/secret or developer-issued OAuth accounts) under their developer programs.
Refer to their official API pages to set up authorization:
- 115 Open Platform: [115 API Guide](https://www.yuque.com/115yun/open/gv0l5007pczskivz)
- 123 Pan: [123 Pan API Documentation](https://123yunpan.yuque.com/org-wiki-123yunpan-muaork/cr6ced)
