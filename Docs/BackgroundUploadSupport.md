# Background Upload Support (host-app background `URLSession`)

**Status:** Implemented in 0.2.0 — host-app background `URLSession` seam (R-BG1–R-BG6).
**Date:** 2026-07-05
**Related:**
- [QCam ADR 0007](/Volumes/SandE/Developer/apps-main/trinity-camera/docs/adr/0007-cloud-sync-background-upload.md) — the consuming decision (continue + drain via background `URLSession`, deferred to M5)
- [QCamCloudSyncKit PRD](/Volumes/SandE/Developer/apps-main/trinity-camera/docs/qcam-cloud-sync-kit-prd.md) — §7.5
- [StreamingUploadPlan.md](./StreamingUploadPlan.md) — the in-process resumable design this builds on (shipped in 0.1.1)
- [GoogleDrive.md](./GoogleDrive.md), [OneDrive.md](./OneDrive.md) — provider semantics

---

## 1. Problem statement

0.1.1's `CloudResumableUploading` (`beginUpload` / `uploadChunk` / `finishUpload`) is **in-process**: chunks are read into memory and PUT via async `URLSession` calls that die when the host app is suspended. A host app that wants uploads to continue after backgrounding must use a **background `URLSessionConfiguration`**, which imposes constraints the current API cannot satisfy:

1. Background sessions accept **file-based upload tasks only** (`uploadTask(with:fromFile:)`) — no in-memory bodies, no streams.
2. Results arrive via **delegate callbacks**, possibly after the app was terminated and relaunched (`handleEventsForBackgroundURLSession`) — the async/await call stack that started the upload no longer exists.
3. After relaunch, the local `uploadedBytes` may be stale — the app must ask the **server** how much it actually received.

The division of labor: **the host app owns the background `URLSession`, its delegate, session identifiers, and relaunch handling.** CloudServiceKit owns everything protocol-specific: building the HTTP requests, interpreting the responses, and resyncing offsets. This doc specifies the library API needed for that split.

## 2. What already helps (0.1.1 audit)

- `CloudUploadSession` is `Codable` and carries `sessionToken` (the Google `Location` / OneDrive `uploadUrl`), `totalBytes`, `uploadedBytes`, `expiresAt` — the right persistence unit.
- **Both providers' upload URLs are pre-authorized**: `uploadChunk` PUTs to `session.sessionToken` with only a `Content-Range` header — no `Authorization` header (see `GoogleDriveServiceProvider.swift:423-427`, `OneDriveServiceProvider.swift:296-300`). This is the crucial property for background transfers: **no OAuth token refresh is needed mid-transfer**, so a request built now stays valid while the app is suspended.
- `OneDriveUploadPolicy` already encodes the 320 KiB alignment rule.

What's missing is that request construction and response interpretation are trapped inside the in-process `uploadChunk`.

## 3. Required API (the "needed things")

### R-BG1 — Chunk request builder (pure, no transport)

```swift
public struct UploadChunkPlan: Sendable {
    public let request: URLRequest        // PUT to session.sessionToken, Content-Range set, NO body
    public let fileRange: Range<Int64>    // byte range of the source file to send as the body
}

public protocol CloudBackgroundUploading: CloudResumableUploading {
    /// Build the next chunk request for a persisted session. `preferredLength` is clamped
    /// to provider rules (OneDrive: 320 KiB multiples, ≤ 60 MiB; Google: any length,
    /// and may cover the ENTIRE remainder in one request).
    nonisolated func chunkUploadPlan(
        for session: CloudUploadSession,
        preferredLength: Int64?
    ) throws -> UploadChunkPlan
}
```

The host slices `fileRange` into a temp file (background tasks need `fromFile:`) — the library should ship a small helper for this (extend `FileChunkReader` with `writeRegion(of:range:to:)`) so every consumer doesn't reimplement safe region copying.

### R-BG2 — Delegate-side response parser (pure, callable after relaunch)

```swift
public enum UploadChunkOutcome: Sendable {
    case progressed(uploadedBytes: Int64)          // Google 308 (Range header) / OneDrive 202 (nextExpectedRanges)
    case completed(remoteFileID: String)           // 200/201 + item JSON
    case sessionExpired                            // 404/410 on the upload URL → beginUpload again
    case retryable(afterSeconds: TimeInterval?)    // 5xx / 429 (honor Retry-After)
    case terminal(CloudServiceError)               // quota, permission, malformed
}

nonisolated func parseChunkResponse(
    _ response: HTTPURLResponse,
    data: Data?,
    for session: CloudUploadSession
) -> UploadChunkOutcome
```

This must be a **pure function of (response, data, session)** — the delegate callback after a relaunch has nothing else.

### R-BG3 — Server-side offset resync

```swift
func queryUploadStatus(session: CloudUploadSession) async throws -> UploadChunkOutcome
```

- **Google Drive**: empty PUT to the session URL with `Content-Range: bytes */<total>` → `308` + `Range: bytes=0-N` header (or 200/201 if already complete).
- **OneDrive**: `GET` the `uploadUrl` → JSON `nextExpectedRanges`.

Called once at relaunch before building the next chunk plan, because a task that completed while the app was dead may never have delivered its delegate callback, and a failed one may have partially landed.

### R-BG4 — Provider range semantics (document + encode)

| | Google Drive | OneDrive |
|---|---|---|
| Max chunk per request | unlimited (single PUT of the whole remainder is valid — **one background task per file**) | 60 MiB per fragment |
| Alignment | none (multiples of 256 KiB recommended for intermediate chunks) | 320 KiB multiples (existing `OneDriveUploadPolicy`) |
| Session lifetime (`expiresAt`) | ~1 week | ~ days (`expirationDateTime` in the create response — already parsed) |
| Upload URL auth | pre-authorized, no header | pre-authorized, no header |

`chunkUploadPlan` must enforce these so hosts can't build invalid requests.

### R-BG5 — Session stability

`CloudUploadSession` is the only state that survives suspension/termination. Its `Codable` shape is now a **persistence contract**: add a schema-version field (or document additive-only evolution) so a library upgrade doesn't strand in-flight sessions persisted by an older version.

### R-BG6 — Isolation

R-BG1/R-BG2 must be `nonisolated` + `Sendable` (pure request/response math). Background-session delegate callbacks arrive on arbitrary queues; requiring a `@MainActor` hop to parse a response is wrong there. (The existing `@MainActor` provider isolation can stay for the in-process paths.)

## 4. Non-goals

- The library does **not** own a `URLSession`, its delegate, background session identifiers, or `handleEventsForBackgroundURLSession` — that's host-app wiring (one identifier per app; see QCam ADR 0004/0007).
- No `BGTaskScheduler` integration (host decision; QCam explicitly declined overnight catch-up).
- No change to the in-process `CloudResumableUploading` flow — it remains the simple path for foreground use.

## 5. Test plan

- **Request builder**: URL == `sessionToken`; `Content-Range` exact for first/middle/final/whole-remainder ranges; OneDrive alignment + 60 MiB clamp; Google whole-remainder plan; no `Authorization` header; no body.
- **Parser**: Google `308 + Range` → `.progressed` with correct byte count; Google/OneDrive `200/201` → `.completed` with file id; OneDrive `202 nextExpectedRanges` → `.progressed`; `404/410` → `.sessionExpired`; `429 + Retry-After` → `.retryable(afterSeconds:)`; malformed JSON → `.terminal`.
- **Resync**: canned Google `*/total` probe and OneDrive `nextExpectedRanges` fixtures, including the already-complete case.
- All pure-function tests run with `MockURLProtocol` fixtures (existing test infra); the suspend/terminate/relaunch matrix lives in the host app's QA runbook, not here.

## 6. Sequencing

**Shipped in 0.2.0** as `CloudBackgroundUploading`, `CloudBackgroundUpload`, `UploadChunkPlan`, `UploadChunkOutcome`, and `FileRegionWriter`. QCamCloudSyncKit M5 swaps its upload transport to a host-owned background `URLSession` using these APIs without re-architecting queue state.
