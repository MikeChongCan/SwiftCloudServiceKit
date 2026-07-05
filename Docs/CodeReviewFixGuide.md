# CloudServiceKit — Code Review Fix Guide

This document captures findings from a full implementation review of the Swift library (all committed code in `Sources/`, `Tests/`, `Package.swift`, and related docs). Use it as a prioritized backlog for fixes before the next release.

**Review date:** 2026-07-05  
**Scope:** ~6.2k lines Swift, 10 cloud providers, shared HTTP/OAuth layer  
**Current tests:** 9 passing (WebDAV, Google Drive, OneDrive — happy path only)

---

## How to use this guide

1. Work **Critical** items first — several are one-line fixes with wide blast radius.
2. Add the **regression tests** listed under each critical fix *before* or *with* the fix.
3. Check off items in the [Todo list](#todo-list) at the bottom as you complete them.
4. Re-run `swift test` after each batch of changes.

---

## Critical issues

### C1 — 401 retry drops POST/PUT/PATCH body

**Severity:** Critical  
**File:** `Sources/CloudServiceProvider.swift` (lines ~681–712)  
**Symptom:** After token refresh on a 401, retried requests have an empty body. Breaks Dropbox POST APIs, OneDrive mutations, uploads, and any authenticated POST.

**Root cause:** `handleResponse` re-invokes the private `request` method after refresh but only passes `method`, `url`, `params`, `headers`, and `progressHandler`. It omits `data`, `json`, `files`, and `requestBody`.

**Fix:**

Introduce a request-spec struct captured once per outbound call, then reuse it on retry:

```swift
private struct HTTPRequestSpec: Sendable {
    let method: HTTPMethod
    let url: URLComponentsConvertible
    let params: [String: Any]
    let data: [String: Any]
    let json: Any?
    let headers: [String: String]
    let files: [String: HTTPFile]
    let requestBody: Data?
    let progressHandler: (@Sendable (HTTPProgress) -> Void)?
    var retryCount: Int = 0
}
```

On 401 refresh, call `request(spec, completion:)` with the **same spec** (increment `retryCount`). Do not reconstruct the call with fewer parameters.

**Alternative (minimal diff):** Pass all omitted arguments explicitly in both retry sites (~687 and ~701):

```swift
self.request(method, url: url,
             params: params, data: data as? [String: Any] ?? [:],
             json: json, headers: headers, files: files,
             requestBody: requestBody,
             progressHandler: progressHandler, completion: completion)
```

Note: `handleResponse` currently receives `data: Any` shadowing the request body `Data` from the outer scope — refactor the parameter name to `formData` or similar to avoid confusion.

**Regression test to add:** `Tests/CloudServiceKitTests/CloudServiceProviderTests.swift`

```swift
func test_401Retry_preservesPOSTBody() async throws {
    // 1. Mock first response: 401
    // 2. refreshAccessTokenHandler returns new credential
    // 3. Mock second response: 200
    // 4. Assert second request httpBody matches original JSON
}
```

---

### C2 — Google Drive resumable upload never finds `Location` header

**Severity:** Critical  
**Files:**
- `Sources/CloudServiceProvider.swift` (lines ~377–388) — headers lowercased
- `Sources/GoogleDriveServiceProvider.swift` (line ~350) — reads `"Location"`

**Symptom:** Every `uploadFile` fails with `responseDecodeError` because `uploadUrl` is always `nil`.

**Root cause:** `HTTPResult.headers` stores keys lowercased, but Google Drive reads `headers["Location"]`.

**Fix (pick one):**

**Option A — Fix call site (smallest change):**

```swift
// GoogleDriveServiceProvider.swift
if let uploadUrl = response.response?.headers["location"] as? String {
```

**Option B — Add helper on `HTTPResult` (preferred, prevents recurrence):**

```swift
public func header(_ name: String) -> String? {
    headers[name.lowercased()] as? String
}
```

Then use `response.response?.header("Location")` everywhere.

**Regression test:**

```swift
func test_HTTPResult_headerLookupIsCaseInsensitive()
func test_GoogleDrive_uploadFile_extractsResumableLocation()
```

---

### C3 — Shared `Authorization: Bearer` breaks some providers

**Severity:** Critical  
**File:** `Sources/CloudServiceProvider.swift` (lines ~600–602)

**Symptom:**
- **Baidu Pan** expects `access_token` as a query parameter on most REST calls, not Bearer auth. Only `streamingAudioRequest` adds `access_token` correctly.
- **Drive115** uses OSS `Authorization` headers with HMAC signatures — a generic Bearer may conflict.
- Other providers (Dropbox, OneDrive, Google) correctly use Bearer.

**Fix:**

Add an overridable auth hook on the protocol (default = Bearer):

```swift
// In CloudServiceProvider extension
public func applyAuthorization(to request: inout URLRequest, credential: URLCredential?) {
    guard let token = credential?.password else { return }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
}
```

Override in `BaiduPanServiceProvider`:

```swift
public func applyAuthorization(to request: inout URLRequest, credential: URLCredential?) {
    // Baidu uses access_token query param — append in request() params instead,
    // or override get/post to inject params["access_token"] = credential?.password
}
```

For Baidu, the simplest fix is to append `access_token` to every request's `params` in a Baidu-specific override of `get`/`post`, or merge it in `request` when `name == "BaiduPan"`. Document the per-provider auth strategy in `Docs/OtherProviders.md`.

**Regression test:** Mock Baidu `contentsOfDirectory` and assert query string contains `access_token=`.

---

### C4 — WebDAV drops `endpoint.path`

**Severity:** Critical  
**File:** `Sources/WebDAVServiceProvider.swift` (lines ~58–65)

**Symptom:** Nextcloud/ownCloud URLs like `https://cloud.example.com/remote.php/dav/files/user/` fail — all operations hit `/file` instead of `/remote.php/dav/files/user/file`.

**Root cause:** `url(for:)` builds `scheme://host:port + path` and ignores `endpoint.path`.

**Fix:**

```swift
private func url(for path: String) -> URL {
    var base = endpoint
    if !base.path.hasSuffix("/") {
        base = base.appendingPathComponent("")
    }
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return URL(string: relative, relativeTo: base) ?? base.appendingPathComponent(relative)
}
```

Or normalize once in `init`:

```swift
private let baseURL: URL  // endpoint with trailing slash, path preserved
```

**Regression test:**

```swift
func test_WebDAV_endpointWithBasePath_isPreserved() async throws {
    let endpoint = URL(string: "https://cloud.example.com/remote.php/dav/files/alice/")!
    let provider = WebDAVServiceProvider(endpoint: endpoint, credential: ..., session: mockSession)
    // PROPFIND for "/" should request .../remote.php/dav/files/alice/
}
```

---

### C5 — PKCE uses standard base64 instead of base64url

**Severity:** Critical  
**File:** `Sources/CloudServiceConnector.swift` (lines ~517–528, `Drive115Connector`)

**Symptom:** 115 device-code auth may fail on strict PKCE validators. Violates RFC 7636.

**Fix:**

```swift
private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func generateCodeVerifier(count: Int) throws -> String {
    var octets = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, octets.count, &octets)
    guard status == errSecSuccess else {
        throw CloudServiceError.serviceError(Int(status), "SecRandomCopyBytes failed")
    }
    return base64URLEncode(Data(octets))
}

private func codeChallenge(fromVerifier verifier: String) -> String {
    let verifierData = verifier.data(using: .ascii)!
    let hash = SHA256.hash(data: verifierData)
    return base64URLEncode(Data(hash))
}
```

**Regression test:** Assert verifier/challenge contain no `+`, `/`, or `=`.

---

### C6 — Query encoding and search injection

**Severity:** Critical  
**Files:**
- `Sources/CloudServiceProvider.swift` — `query(_:)` uses `.urlQueryAllowed`
- `Sources/OneDriveServiceProvider.swift` — OData search path
- `Sources/GoogleDriveServiceProvider.swift` — Drive query string

**Symptom:** Keywords or paths containing `&`, `=`, `+`, or `'` break queries or inject unintended filters.

**Fix for `query(_:)`:**

```swift
private static let queryAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

private func query(_ params: [String: Any]) -> String {
    params.map { key, val in
        let k = key.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? key
        let v = "\(val)".addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? "\(val)"
        return "\(k)=\(v)"
    }.joined(separator: "&")
}
```

**Fix for search APIs:**

- **OneDrive:** Percent-encode keyword; escape single quotes for OData (`'` → `''`), or use `$filter` with proper encoding instead of path interpolation.
- **Google Drive:** Escape `'` in keyword before interpolating into `name contains '...'`.

**Regression tests:**

```swift
func test_query_encodesAmpersandAndPlus()
func test_searchFiles_keywordWithApostrophe()
```

---

### C7 — Platform floor mismatch across package metadata

**Severity:** Critical (documentation / integration)  
**Files:** `Package.swift`, `README.md`, `AGENTS.md`, `CloudServiceKit.podspec`

| Source | iOS | tvOS | macOS |
|--------|-----|------|-------|
| `Package.swift` | 17 | 17 | 14 |
| `README.md` | 13 | — | — |
| `AGENTS.md` | 13 | 14 | — |
| `CloudServiceKit.podspec` | 13 | 14 | — |

**Fix:** Decide the real minimum (likely iOS 17 / tvOS 17 / macOS 14 if Swift 6 strict concurrency is required). Update **all four files** to match. Add a short rationale in README:

> Requires iOS 17+ due to Swift 6 concurrency and `@MainActor` provider isolation.

If older platforms must be supported, lower `Package.swift` and verify compilation on those SDKs.

---

### C8 — Infinite 401 refresh loop

**Severity:** Critical  
**File:** `Sources/CloudServiceProvider.swift` — `handleResponse`

**Symptom:** Revoked or invalid refresh tokens cause unbounded retry → token endpoint abuse.

**Fix:** Add `retryCount` to request spec (see C1). On 401, only retry if `retryCount < 1`:

```swift
guard spec.retryCount < 1 else {
    completion(CloudResponse(response: response, result: .failure(CloudServiceError.serviceError(401, "Unauthorized after token refresh"))))
    return
}
var retrySpec = spec
retrySpec.retryCount += 1
// refresh token, then request(retrySpec, ...)
```

**Regression test:** Mock 401 → refresh → 401 again; assert exactly 2 HTTP attempts, no third.

---

## Medium issues

### M1 — `handleResponse` Task + MainActor pattern is fragile

**File:** `Sources/CloudServiceProvider.swift`

**Fix:** Prefer full `async` request path end-to-end, or mark internal helpers `@MainActor` explicitly. Avoid callback-inside-`Task` when the protocol is `@MainActor`.

---

### M2 — OneDrive `fileHash` always nil

**File:** `Sources/OneDriveServiceProvider.swift` (~288–290)

**Current (wrong):**

```swift
item.fileHash = file["hashes"] as? String
```

**Fix:**

```swift
if let hashes = file["hashes"] as? [String: Any] {
    item.fileHash = (hashes["sha1Hash"] as? String)
        ?? (hashes["quickXorHash"] as? String)
}
```

---

### M3 — Baidu Pan `getCurrentUserInfo` wrong endpoint

**File:** `Sources/BaiduPanServiceProvider.swift` (~128)

**Current:** `apiURL.appendingPathComponent("nas")`  
**Fix:** `apiURL.appendingPathComponent("xpan/nas")` (match `getCloudSpaceInformation` at line ~114)

---

### M4 — Drive115 `renewToken` always fails

**File:** `Sources/CloudServiceConnector.swift` (~342–345)

**Issue:** Comment says "pCloud" but this is Drive115. Class already has `refreshAccessToken(refreshToken:)` — wire `renewToken` to call it, or document that consumers must set `refreshAccessTokenHandler` manually.

**Fix:**

```swift
public override func renewToken(with refreshToken: String, completion: ...) {
    Task {
        do {
            let payload = try await refreshAccessToken(refreshToken: refreshToken)
            // Map to OAuthSwift.TokenSuccess or CloudOAuthTokenResult as needed
        } catch {
            completion(.failure(error))
        }
    }
}
```

---

### M5 — WebDAV `shouldProcessResponse` wrong signature (dead code)

**File:** `Sources/WebDAVServiceProvider.swift` (~371)

**Current:**

```swift
public func shouldProcessResponse(_ response: HTTPResult) -> Bool
```

**Fix:** Match protocol — add `completion` parameter, or delete the method and rely on default `false`.

---

### M6 — Recursive async chunk uploads

**Files:** Dropbox, OneDrive, Google Drive, Baidu Pan, Aliyun providers

**Fix:** Replace tail-recursive `try await self.uploadChunk(...)` with `while offset < totalSize { ... }` loops to avoid deep continuation stacks on large files.

---

### M7 — `ISO3601DateFormatter` locale/timezone

**File:** `Sources/CloudServiceProvider.swift` (~721–742)

**Fix:**
- Rename to `ISO8601DateFormatter` (fix typo)
- Set `locale = Locale(identifier: "en_US_POSIX")` and `timeZone = TimeZone(secondsFromGMT: 0)` on both formatters
- Or replace with `Foundation.ISO8601DateFormatter` + fractional seconds fallback

---

### M8 — Protocol extension no-op setters for `refreshAccessTokenHandler` / `delegate`

**File:** `Sources/CloudServiceProvider.swift` (~262–270)

**Fix:** Move both properties into the protocol requirement body (not the default extension with `set { }`). Forces every provider to declare stored properties explicitly.

---

### M9 — `fileSize(of:)` NSNumber cast

**File:** `Sources/CloudServiceProvider.swift` (~285–296)

**Fix:**

```swift
return (attributes[.size] as? NSNumber)?.int64Value
```

Remove `print(error)` — use silent failure or `os_log` if needed.

---

### M10 — Baidu Pan `downloadLink` token in URL

**File:** `Sources/BaiduPanServiceProvider.swift` (~159)

**Issue:** Appends `access_token` to query string — appears in logs/referrers.

**Fix:** Document as Baidu API requirement; consider clearing URL from caches after use. Prefer server-side proxy if security is paramount.

---

### M11 — `AnyCodable` null and precision

**File:** `Sources/AnyCodable.swift`

**Fix:**
- Add `.null` case; map `decodeNil()` to `.null`, not `.string("")`
- Try `Double` before `Int` in decode order to preserve `1.0`

---

### M12 — Tests use global `URLSession.shared`

**Files:** `GoogleDriveServiceProviderTests`, `OneDriveServiceProviderTests`

**Fix:** Add optional `session: URLSession` parameter to every provider `init` (match `WebDAVServiceProvider`). Build test sessions with `MockURLProtocol` injected — no global `URLProtocol.registerClass`.

---

### M13 — `String.urlEncoded` force-unwrap

**File:** `Sources/Extensions.swift` (~48–51)

**Fix:** `return self.addingPercentEncoding(withAllowedCharacters: customAllowedSet) ?? self`

---

## Low / nits

| ID | File | Issue | Fix |
|----|------|-------|-----|
| L1 | `CloudItem.swift:8-10` | Duplicate `import Foundation` | Remove one |
| L2 | `Just.swift` | Vestigial stub ("File removed...") | Delete file |
| L3 | `CloudServiceProvider.swift:293` | `print(error)` in library | Remove |
| L4 | `AliyunDriveServiceProvider.swift` | Same `print(error)` | Remove |
| L5 | `GoogleDriveServiceProvider.swift:98` | Force-unwrap after nil check | Use `if let` |
| L6 | `WebDAVXMLParser` | New `DateFormatter` per element | Cache static formatter |
| L7 | `Extensions.swift` | `Dictionary.json` returns `"[]"` on error | Return `"{}"` for dict |
| L8 | `BaiduPanConnector` | `UIScreen.main` deprecated | Use `UITraitCollection.current` |
| L9 | `CloudServiceProvider.swift:363` | Unused `task:` parameter on `HTTPResult.init` | Remove parameter |
| L10 | `Drive123ServiceProvider` | Doc comment says "OneDrive" for scope | Fix comment |

---

## Test coverage backlog

Add tests in `Tests/CloudServiceKitTests/`:

| Priority | Test name | Catches |
|----------|-----------|---------|
| P0 | `test_401Retry_preservesPOSTBody` | C1 |
| P0 | `test_GoogleDrive_uploadFile_extractsResumableLocation` | C2 |
| P0 | `test_WebDAV_endpointWithBasePath_isPreserved` | C4 |
| P0 | `test_401Retry_stopsAfterOneAttempt` | C8 |
| P1 | `test_HTTPResult_headerLookupIsCaseInsensitive` | C2 |
| P1 | `test_query_encodesReservedCharacters` | C6 |
| P1 | `test_PKCE_verifierIsBase64URL` | C5 |
| P1 | `test_BaiduPan_requestsIncludeAccessToken` | C3 |
| P2 | `test_OneDrive_cloudItemFromJSON_extractsSha1Hash` | M2 |
| P2 | `test_BaiduPan_getCurrentUserInfo_usesXpanNas` | M3 |
| P2 | `test_CloudItem_fixPath_*` (parameterized) | Path edge cases |
| P3 | Per-provider `shouldProcessResponse` error fixtures | Provider matrix |

**Providers with zero tests today:** Box, Dropbox, Baidu Pan, Aliyun, Drive115, Drive123, pCloud.

---

## Recommended fix order

```
Phase 1 (release blockers)
├── C1  Request body on 401 retry
├── C2  Location header case
├── C4  WebDAV base path
├── C8  Retry limit
└── P0 regression tests

Phase 2 (auth & encoding)
├── C3  Per-provider auth hook
├── C6  Query encoding + search escape
├── C5  PKCE base64url
├── M2  OneDrive hash
├── M3  Baidu nas path
└── C7  Platform docs sync

Phase 3 (quality & maintainability)
├── M6  Chunk upload while loops
├── M12 URLSession injection all providers
├── M7  ISO8601 date formatter
├── M8  Protocol property requirements
├── L2  Delete Just.swift stub
└── Remaining medium/low items
```

---

## Todo list

Copy this section into your issue tracker or check items off here as you work.

### Critical

- [ ] **C1** — Preserve full request body (`data`/`json`/`files`/`requestBody`) on 401 token refresh retry
- [ ] **C2** — Fix `Location` header lookup (use `"location"` or `HTTPResult.header(_:)`)
- [ ] **C3** — Add provider-overridable auth; fix Baidu Pan `access_token` query param
- [ ] **C4** — Fix WebDAV `url(for:)` to preserve `endpoint.path`
- [ ] **C5** — Fix PKCE base64url encoding + check `SecRandomCopyBytes` status
- [ ] **C6** — Fix query percent-encoding; escape search keywords (OneDrive, Google Drive)
- [ ] **C7** — Align iOS/tvOS/macOS minimums across Package.swift, README, AGENTS.md, podspec
- [ ] **C8** — Add single retry cap on 401 refresh (prevent infinite loop)

### Regression tests (P0)

- [ ] **T1** — `test_401Retry_preservesPOSTBody`
- [ ] **T2** — `test_GoogleDrive_uploadFile_extractsResumableLocation`
- [ ] **T3** — `test_WebDAV_endpointWithBasePath_isPreserved`
- [ ] **T4** — `test_401Retry_stopsAfterOneAttempt`

### Medium

- [ ] **M1** — Refactor `handleResponse` to async or explicit `@MainActor` helpers
- [ ] **M2** — Fix OneDrive `cloudItemFromJSON` hash extraction (`sha1Hash` / `quickXorHash`)
- [ ] **M3** — Fix Baidu Pan `getCurrentUserInfo` path (`xpan/nas`)
- [ ] **M4** — Wire Drive115 `renewToken` to `refreshAccessToken` (fix wrong comment)
- [ ] **M5** — Fix or remove WebDAV dead `shouldProcessResponse` method
- [ ] **M6** — Convert recursive async chunk uploads to `while` loops
- [ ] **M7** — Fix `ISO8601DateFormatter` locale/timezone (rename typo)
- [ ] **M8** — Move `refreshAccessTokenHandler` / `delegate` out of no-op extension
- [ ] **M9** — Fix `fileSize(of:)` NSNumber cast; remove `print(error)`
- [ ] **M10** — Document Baidu Pan token-in-URL security note
- [ ] **M11** — Fix `AnyCodable` null and numeric precision
- [ ] **M12** — Inject `URLSession` into all provider inits for testability
- [ ] **M13** — Remove force-unwrap in `String.urlEncoded`

### Low / cleanup

- [ ] **L1** — Remove duplicate `import Foundation` in `CloudItem.swift`
- [ ] **L2** — Delete vestigial `Sources/Just.swift`
- [ ] **L3** — Remove `print(error)` from `CloudServiceProvider.fileSize`
- [ ] **L4** — Remove `print(error)` from Aliyun provider
- [ ] **L5** — Replace force-unwrap in Google Drive pagination loop
- [ ] **L6** — Cache `DateFormatter` in `WebDAVXMLParser`
- [ ] **L7** — Fix `Dictionary.json` fallback to `"{}"`
- [ ] **L8** — Replace deprecated `UIScreen.main` in `BaiduPanConnector`
- [ ] **L9** — Remove unused `task:` from `HTTPResult.init`
- [ ] **L10** — Fix Drive123 scope doc comment

### Tests (P1–P3)

- [ ] **T5** — `test_HTTPResult_headerLookupIsCaseInsensitive`
- [ ] **T6** — `test_query_encodesReservedCharacters`
- [ ] **T7** — `test_PKCE_verifierIsBase64URL`
- [ ] **T8** — `test_BaiduPan_requestsIncludeAccessToken`
- [ ] **T9** — `test_OneDrive_cloudItemFromJSON_extractsSha1Hash`
- [ ] **T10** — `test_BaiduPan_getCurrentUserInfo_usesXpanNas`
- [ ] **T11** — `test_CloudItem_fixPath` edge cases
- [ ] **T12** — Add tests for Box, Dropbox, Baidu, Aliyun, 115, 123, pCloud
- [ ] **T13** — Per-provider `shouldProcessResponse` error response fixtures

### Documentation

- [ ] **D1** — Document per-provider auth strategy (Bearer vs query vs OSS) in `Docs/OtherProviders.md`
- [ ] **D2** — Document `CloudItem.id` vs `.path` semantics per provider (public-facing)
- [ ] **D3** — Document 401-retry contract (what is preserved, retry limit, hooks)

---

## Verification checklist

After completing Phase 1:

```bash
cd /path/to/CloudServiceKit
swift test
swift build
```

Manually smoke-test (if credentials available):

- [ ] Google Drive file upload (> 5 MB, resumable path)
- [ ] WebDAV list against Nextcloud with subpath endpoint
- [ ] OneDrive list after simulated token expiry (401 → refresh → retry)
- [ ] Baidu Pan list directory

---

## References

- Architecture notes: `AGENTS.md`
- Provider setup: `Docs/GoogleDrive.md`, `Docs/OneDrive.md`, `Docs/Dropbox.md`, `Docs/OtherProviders.md`
- Shared HTTP layer: `Sources/CloudServiceProvider.swift`
- OAuth / PKCE: `Sources/CloudServiceConnector.swift`
