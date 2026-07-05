# Streaming & Resumable Upload Plan (R1 / M0)

**Status:** Plan only — gates QCamCloudSyncKit and any multi-GB upload consumer  
**Date:** 2026-07-05  
**Related:**
- [QCamCloudSyncKit PRD](/Volumes/SandE/Developer/apps-main/trinity-camera/docs/qcam-cloud-sync-kit-prd.md) — §7.4, §10 R1, §11 M0
- [CodeReviewFixGuide.md](./CodeReviewFixGuide.md) — HTTP-layer fixes (401 retry, Location header, etc.)
- [AGENTS.md](../AGENTS.md) — provider semantics

---

## 1. Problem statement (R1)

From the QCam PRD:

> `uploadData(_:filename:to:progress:)` takes in-memory `Data`. **Loading a multi-GB clip into `Data` is unacceptable** on iOS.

QCam clips are large `.mov` files (Log/ProRes-adjacent). A 4 GB upload via `Data` will:

1. Allocate contiguous address space the kernel may refuse (jetsam on iOS).
2. Block or pressure memory while the camera app is still running (thermal/IO competition — PRD R4).
3. Prevent resume after interruption — if the process dies mid-upload, progress is lost unless offset is persisted externally.

**Risk R1 gates the whole cloud-backup project.** Milestone **M0** is a 2–3 day spike: OAuth round-trip + chunked/resumable upload of a **4 GB file from disk** with pause/resume, producing a decision on implementation path (§7.4).

---

## 2. Current CloudServiceKit state (audit)

### 2.1 Protocol surface

```swift
// CloudServiceProvider.swift
func uploadData(_ data: Data, filename: String, to directory: CloudItem, progressHandler: ...) async throws -> ...
func uploadFile(_ fileURL: URL, to directory: CloudItem, progressHandler: ...) async throws -> ...
```

| Provider | `uploadData` | `uploadFile` | Chunked from disk? | Resumable session? |
|----------|--------------|--------------|--------------------|--------------------|
| **Google Drive** | Builds full multipart body in memory (`body.append(data)`) | Resumable upload for any size; reads 5 MB chunks via `FileHandle` | Partial — chunk in RAM per PUT | Yes — session URL from `uploadType=resumable` |
| **OneDrive** | Full file in `requestBody` | > 4 MB uses `createUploadSession`; 5 MB chunks | Partial | Yes — `uploadUrl` + `Content-Range` |
| Dropbox | Max 150 MB; full `Data` in body | Session API for large files | Partial | Yes |
| Box | Full `Data` if ≤ 20 MB | Chunked if > 20 MB | Partial | Yes |
| Baidu / Aliyun / 115 / 123 | Full `Data` or chunk reads into `Data` per part | Similar | Partial — **one chunk in RAM at a time**, not whole file | Varies |
| WebDAV | Full `Data(contentsOf:)` then PUT | Same | **No** — loads entire file | No |
| pCloud | Full `Data` | Reads file to `Data` | **No** | No |

**Key insight:** Google Drive and OneDrive already implement **file-URL resumable uploads** in `uploadFile`. The R1 problem is:

1. **`uploadData` is inherently wrong** for large payloads — must not be used by QCam.
2. **Chunk implementations still hold each chunk in `Data`** (8–16 MB is OK; 4 GB is not).
3. **No resumable session handle** is exposed — consumers cannot persist `uploadUrl` / offset across app relaunch (M0 requirement).
4. **HTTP transport** uses `URLSession.upload(for:from: Data)` — no streaming body from `FileHandle` without lower-level APIs.
5. **`@MainActor` providers** — long uploads should not pin UI isolation (PRD R5).

### 2.2 What already works for QCam (if fixed)

For v1 providers (**Google Drive + OneDrive only**):

- Call **`uploadFile(_:to:progressHandler:)`**, never `uploadData`.
- Fix [C2 Location header](./CodeReviewFixGuide.md#c2--google-drive-resumable-upload-never-finds-location-header) before trusting Google uploads.
- Chunk size: Google uses 5 MB; OneDrive uses 5 MB (OpenDAL uses 320 KiB × 12 ≈ 3.75 MB for Graph alignment).

This is enough for **M0 spike** once C2 is fixed, but **not** enough for production QCam (no pause/resume persistence, no `CloudStorageProviding` seam, MainActor concerns).

---

## 3. Design goals (learned from OpenDAL)

Reference: `.build/opendal/core/core/src/types/write/writer.rs`, `core/services/onedrive/src/writer.rs`

OpenDAL separates **transport** from **consumer API**:

| OpenDAL concept | Swift equivalent (proposed) |
|-----------------|----------------------------|
| `Operator::writer(path)` | `CloudUploadWriter` / `startUpload(...)` |
| `Writer::write(chunk)` / `write_from(Buf)` | `writeChunk(_:at:)` or pull-based `readNextChunk()` |
| **`close()` required** — data lost if dropped | `finish()` commits; document lifecycle |
| **`abort()`** | `cancel()` deletes partial remote state where API allows |
| Capability flags (`write`, `write_can_append`) | `UploadCapabilities` per provider |
| OneDrive: chunk size multiple of 320 KiB | `OneDriveUploadPolicy.chunkSize = 327_680 * 12` |
| Google: resumable session + byte ranges | `GoogleDriveUploadSession` with persisted URL |

OpenDAL Swift bindings today only expose **`blockingWrite(Data)`** — still memory-bound. Do **not** copy that binding; copy the **Writer lifecycle** and provider-specific chunked backends.

### 3.1 Target API shape (CloudServiceKit + QCamCloudSyncKit)

**Layer A — CloudServiceKit (upstream, reusable):**

```swift
/// Sendable snapshot of an in-progress upload; persist to JSON for resume.
public struct CloudUploadSession: Codable, Sendable {
    public let provider: String
    public let remotePath: String
    public let fileURL: URL          // or clip id resolved at runtime
    public let totalBytes: Int64
    public var uploadedBytes: Int64
    public var sessionToken: String  // uploadUrl, session id, etc.
    public var expiresAt: Date?
}

public protocol CloudResumableUploading: CloudServiceProvider {
    /// Begin upload; returns session state to persist.
    func beginUpload(
        fileURL: URL,
        filename: String,
        to directory: CloudItem,
        contentType: String?
    ) async throws -> CloudUploadSession

    /// Upload bytes `[offset, offset+length)`; updates session.uploadedBytes on success.
    func uploadChunk(
        session: inout CloudUploadSession,
        progressHandler: (@Sendable (Progress) -> Void)?
    ) async throws -> CloudUploadSession

    /// Finalize when uploadedBytes == totalBytes.
    func finishUpload(session: CloudUploadSession) async throws -> CloudItem

    func cancelUpload(session: CloudUploadSession) async throws
}
```

**Layer B — QCamCloudSyncKit (app seam, PRD §6):**

```swift
protocol CloudStorageProviding: Sendable {
    func ensureFolder(_ name: String) async throws -> CloudItem
    func uploadFile(
        from fileURL: URL,
        filename: String,
        to folder: CloudItem,
        resumeSession: CloudUploadSession?,   // nil = start fresh
        onProgress: @Sendable (Int64, Int64) -> Void
    ) async throws -> (remote: CloudItem, session: CloudUploadSession?)
}
```

Implementations: `GoogleDriveStorage`, `OneDriveStorage` wrapping CloudServiceKit (or raw REST fallback per PRD §7.4 path 2).

---

## 4. Swift concurrency design (project settings)

### 4.1 CloudServiceKit (`Package.swift` today)

| Setting | Value |
|---------|--------|
| Swift tools | 6.0 |
| Platforms | iOS 17+, tvOS 17+, macOS 14+ |
| Provider isolation | `@MainActor` on providers |
| Strict concurrency | Not explicitly enabled in Package.swift — verify before migration |

### 4.2 QCamCloudSyncKit (PRD §6)

| Setting | Value |
|---------|--------|
| Swift | 5 language mode + `.defaultIsolation(MainActor.self)` |
| Engine / IO | Explicit off-main for file reads + network |

### 4.3 Isolation rules for upload work

Follow [swift-concurrency skill](../.agents/skills/swift-concurrency/SKILL.md):

| Component | Isolation | Rationale |
|-----------|-----------|-----------|
| `UploadQueueStore`, `ClipSyncLedger`, settings | `@MainActor` | UI-bound observable state |
| `UploadEngine` worker loop | **`actor UploadEngine`** or `@concurrent` Task body | Serial queue; no main-thread blocking |
| Per-chunk file read | `Task { @concurrent in ... }` | `FileHandle.readData` is synchronous IO |
| Progress callbacks | `await MainActor.run { ... }` | UI updates only on main |
| `CloudStorageProviding` mock | `Sendable` struct, no shared mutable state | Testability |

**Do not** mark the entire upload pipeline `@MainActor` because CloudServiceKit providers already are — instead:

```swift
// QCamCloudSyncKit — pattern
actor UploadEngine {
    func runNext() async {
        let task = await queueStore.dequeueEligible()
        await withTaskCancellationHandler {
            try await storage.uploadFile(from: task.fileURL, ...) { sent, total in
                Task { @MainActor in
                    coordinator.reportProgress(task.id, sent: sent, total: total)
                }
            }
        } onCancel: { ... }
    }
}
```

For CloudServiceKit refactors, prefer **`nonisolated`** upload methods on a dedicated **`UploadTransport`** type (not `@MainActor`) that holds `URLSession` + credential, called from `@concurrent` contexts. Long-term this resolves PRD R5 without `@unchecked Sendable` hacks.

### 4.4 Structured concurrency for parallel work

v1 QCam: **serial uploads** (PRD §7.5). Use:

- `async let` / `withTaskGroup` only for **MD5 precalculation** or sidecar `.json` upload (P2), not parallel video chunks.
- Chunk loop: plain `while offset < totalSize` (fixes recursive async stack issue from code review M6).

### 4.5 Background uploads (M5 fast-follow)

PRD stages this deliberately:

- v1: `beginBackgroundTask` + finish current chunk + persist `CloudUploadSession` to JSON.
- M5: `URLSessionConfiguration.background` with **file-based** `uploadTask(fromFile:)` per chunk — requires delegate-based session owned by app, not `@MainActor` provider.

Design `CloudUploadSession` now so both v1 and M5 can resume from the same persisted offset.

---

## 5. HTTP transport: streaming vs chunked `Data`

### 5.1 Short term (M0 / Phase 1) — chunked `Data` per part

Acceptable memory: **one chunk in RAM** (8–16 MB per PRD §7.5).

```
FileHandle.seek(offset)
let chunk = handle.readData(ofLength: chunkSize)  // ≤ 16 MB
URLSession.upload(for: request, from: chunk)
```

Requirements:

- Reuse open `FileHandle` across chunks (close in `defer`).
- Convert recursive `uploadChunk(offset:)` to `while` loops in Google/OneDrive providers.
- Fix Location header lookup (`"location"`).

### 5.2 Medium term (Phase 2) — `URLSessionUploadTask` from file slice

For a byte range without loading into `Data`:

```swift
// Pseudocode — use temporary slice file or NSFileHandle read into autoreleasepool
// iOS 17+: consider URLSession.upload(fromFile: URL, offset:offset, length:length)
```

Investigate `URLSessionTask` with custom `httpBodyStream` via `InputStream(fileAtPath:)` for true streaming PUT (Google resumable, OneDrive session URL).

### 5.3 Long term (Phase 3) — background session + OpenDAL-style writer

Mirror OpenDAL's contract:

- `beginUpload` → persist session
- N × `uploadChunk` → monotonic offset
- `finishUpload` / `cancelUpload`
- Capability probe: `supportsResume`, `minChunkSize`, `maxSimpleUploadSize`

---

## 6. Provider-specific notes (Google Drive & OneDrive)

### 6.1 Google Drive

**API:** [Resumable upload](https://developers.google.com/drive/api/guides/manage-uploads#resumable)

| Step | HTTP | Persist for resume |
|------|------|-------------------|
| Start session | `POST .../upload/drive/v3/files?uploadType=resumable` | `Location` header → `sessionToken` |
| Upload chunk | `PUT {sessionUrl}` + `Content-Range: bytes start-end/total` | `uploadedBytes` = end + 1 |
| Complete | 200/201 on final chunk | remote file id from JSON |

**Existing code:** `GoogleDriveServiceProvider.uploadFile` — refactor into public `CloudResumableUploading` methods.

**OpenDAL note:** gdrive writer uses simple upload for small files only; large resumable is not in OpenDAL gdrive writer yet — CloudServiceKit is ahead here once C2 is fixed.

### 6.2 OneDrive

**API:** [Create upload session](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession)

| Step | HTTP | Persist for resume |
|------|------|-------------------|
| Create session | `POST .../createUploadSession` | `uploadUrl` from JSON |
| Upload chunk | `PUT {uploadUrl}` + `Content-Range` | `uploadedBytes` |
| Complete | `201 Created` on last chunk | `CloudItem` from response |

**Chunk sizing:** Must be multiple of **320 KiB** (327,680 bytes). OpenDAL uses `327_680 * 12` = 3,932,160 bytes.

**Status codes:** `202 Accepted` mid-upload; `201 Created` on final chunk (see OpenDAL `onedrive/src/writer.rs`).

### 6.3 Small files

| Provider | Simple upload threshold |
|----------|-------------------------|
| OneDrive | ≤ 4 MB — single PUT to `.../content` |
| Google Drive | ≤ ~5 MB — multipart `uploadType=multipart` OK |

QCam sidecar `.json` (P2) uses simple path; video uses resumable.

---

## 7. Implementation paths (PRD §7.4 decision)

### Path A — Extend CloudServiceKit upstream (preferred)

**Pros:** One implementation; QCam wraps thin `CloudStorageProviding`; other apps benefit.  
**Cons:** Requires API design + tests in this repo; release coordination.

**Deliverables in CloudServiceKit:**

1. `CloudResumableUploading` protocol + `CloudUploadSession`
2. Google Drive + OneDrive conformances
3. Deprecate direct use of `uploadData` for files > threshold (doc + runtime warning)
4. `UploadTransport` actor (off-main URLSession)
5. Unit tests with `MockURLProtocol` + injectable session
6. M0 manual QA script in `Docs/`

**Estimated effort:** 3–5 days after M0 spike validates APIs.

### Path B — REST in QCamCloudSyncKit only (fallback)

**Pros:** Ship QCam without waiting for upstream release.  
**Cons:** Duplicates Google/OneDrive upload logic; drift from CloudServiceKit.

Use CloudServiceKit only for: folder list/create, auth header conventions, `CloudItem` parsing.

**When to choose:** M0 spike shows CloudServiceKit `@MainActor` + URLSession coupling cannot be fixed quickly, or upstream maintainer unavailable.

### Path C — Hybrid (recommended if Path A slips)

1. M0: Path B minimal REST in spike branch to prove 4 GB + pause/resume.
2. Port proven code into CloudServiceKit as Path A.
3. QCamCloudSyncKit switches to upstream types.

---

## 8. M0 spike checklist (gate)

**Duration:** 2–3 days (PRD §11)  
**Success criteria:**

- [ ] OAuth PKCE works for Google (`drive.file`) and OneDrive (`Files.ReadWrite` + `offline_access`)
- [ ] Upload **4 GB file** from disk without peak RSS > ~32 MB (instrument with Instruments Allocations)
- [ ] **Pause:** stop after chunk N, persist session JSON to disk
- [ ] **Resume:** relaunch process, continue from byte offset, file completes with correct size
- [ ] **Wi-Fi drop:** mid-chunk failure retries chunk (not whole file)
- [ ] Decision recorded: Path A, B, or C

**Spike repo layout (temporary):**

```
Spike/
  M0UploadSpike.swift          # CLI or XCTest performance case
  Fixtures/generate_4gb_file.sh
  spike_session.json           # persisted CloudUploadSession
```

**Metrics to capture:**

| Metric | Target |
|--------|--------|
| Peak memory during upload | < 50 MB |
| Chunks per 4 GB @ 8 MB | 512 |
| Time to first byte | < 5 s after OAuth |
| Resume after kill | ≤ 1 chunk re-sent |

---

## 9. Phased rollout

### Phase 0 — M0 spike (gate)

See §8. Blocks all QCamCloudSyncKit UI work.

### Phase 1 — CloudServiceKit upload API (Path A core)

1. Add `CloudUploadSession`, `CloudResumableUploading`
2. Refactor `GoogleDriveServiceProvider` + `OneDriveServiceProvider`
3. Fix C2 Location header
4. Replace recursive chunk loops with `while`
5. Add `UploadTransport` actor
6. Tests: session persistence, chunk boundaries, 401 retry with body (C1)

### Phase 2 — QCamCloudSyncKit integration

Per PRD §6:

1. `CloudStorageProviding` + Google/OneDrive wrappers
2. `UploadEngine` actor + `UploadQueueStore` JSON persistence
3. Wire `CloudUploadSession` into queue item state
4. `beginBackgroundTask` for in-flight chunk (U9 partial)

### Phase 3 — Hardening

1. Background `URLSession` (M5)
2. Sidecar `.json` upload (U10)
3. Thermal / capture-pause integration (`isCapturing` signal)
4. Provider capability matrix in docs

---

## 10. Testing strategy

| Layer | Tool | Cases |
|-------|------|-------|
| Chunk math | Swift Testing / XCTest | Offset boundaries, last partial chunk, OneDrive 320 KiB alignment |
| Session codec | Unit | JSON round-trip `CloudUploadSession` |
| HTTP | `MockURLProtocol` | Location header, Content-Range, 308/401 |
| Memory | XCTest measure / Instruments | 4 GB file, assert RSS bound |
| Integration | Manual QA runbook | Real Drive/OneDrive, airplane mode mid-chunk |
| Concurrency | Thread Sanitizer + strict concurrency build | No `@MainActor` blocking in engine |

**OpenDAL-inspired behavior tests** (port ideas from `core/tests/behavior/async_write.rs`):

- `test_writer_write_non_contiguous_data` → uneven chunk sizes
- `test_writer_abort` → cancel mid-upload, remote partial cleaned up if API supports

---

## 11. Documentation updates

After implementation, update:

- [ ] `README.md` — "Large files: use `uploadFile` or `CloudResumableUploading`, never `uploadData` for clips"
- [ ] `Docs/GoogleDrive.md` — resumable session + pause/resume
- [ ] `Docs/OneDrive.md` — chunk size rules
- [ ] `Docs/OtherProviders.md` — which providers support resume
- [ ] QCam PRD §7.4 — mark decision + link to this doc

---

## 12. Todo list

### M0 — Spike (gate) — **must complete before UI**

- [ ] **M0-1** Set up OAuth PKCE test harness (Google + OneDrive)
- [ ] **M0-2** Generate 4 GB local test file script
- [ ] **M0-3** Implement minimal resumable upload (Path A or B) for Google Drive
- [ ] **M0-4** Implement minimal resumable upload for OneDrive (320 KiB-aligned chunks)
- [ ] **M0-5** Persist `CloudUploadSession` JSON; verify pause/resume across process restart
- [ ] **M0-6** Measure peak memory (Instruments) — document RSS < 50 MB
- [ ] **M0-7** Record Path A / B / C decision in this doc + PRD

### CloudServiceKit — Protocol & transport

- [ ] **CSK-1** Define `CloudUploadSession` (Codable, Sendable)
- [ ] **CSK-2** Define `CloudResumableUploading` protocol
- [ ] **CSK-3** Extract `UploadTransport` actor (URLSession off `@MainActor`)
- [ ] **CSK-4** Refactor `GoogleDriveServiceProvider` → `CloudResumableUploading`
- [ ] **CSK-5** Refactor `OneDriveServiceProvider` → `CloudResumableUploading`
- [ ] **CSK-6** Fix Location header case (`"location"`) — blocks Google upload
- [ ] **CSK-7** Convert recursive chunk uploads to `while` loops (Google, OneDrive)
- [ ] **CSK-8** Align OneDrive chunk size to 320 KiB multiple (match Graph + OpenDAL)
- [ ] **CSK-9** Mark `uploadData` as unsuitable for large payloads in doc comments
- [ ] **CSK-10** Add injectable `URLSession` to Google/OneDrive providers (test seam)

### CloudServiceKit — Tests

- [ ] **CSK-T1** `test_GoogleDrive_beginUpload_returnsSessionURL`
- [ ] **CSK-T2** `test_GoogleDrive_uploadChunk_contentRange`
- [ ] **CSK-T3** `test_OneDrive_chunkSize_is320KiBAligned`
- [ ] **CSK-T4** `test_CloudUploadSession_JSONRoundTrip`
- [ ] **CSK-T5** `test_uploadFile_4GB_peakMemory` (performance test, CI optional)
- [ ] **CSK-T6** `test_401Retry_preservesChunkBody` (with C1 fix)

### QCamCloudSyncKit — App layer (after M0)

- [ ] **QCS-1** Define `CloudStorageProviding` protocol (PRD §6)
- [ ] **QCS-2** Implement `GoogleDriveStorage` wrapping `CloudResumableUploading`
- [ ] **QCS-3** Implement `OneDriveStorage`
- [ ] **QCS-4** `UploadQueueStore` — persist queue + `CloudUploadSession` per task
- [ ] **QCS-5** `UploadEngine` actor — serial worker, `@concurrent` chunk IO
- [ ] **QCS-6** Progress reporting via `MainActor.run`
- [ ] **QCS-7** Pause/resume settings integration (PRD §5.2)
- [ ] **QCS-8** `beginBackgroundTask` — finish chunk + persist on background
- [ ] **QCS-9** Mock `CloudStorageProviding` for queue/policy unit tests

### Concurrency & hardening

- [ ] **CONC-1** Audit `@MainActor` on providers vs upload hot path (PRD R5)
- [ ] **CONC-2** Enable strict concurrency in CloudServiceKit Package.swift; fix diagnostics
- [ ] **CONC-3** Document isolation diagram in this doc after refactor
- [ ] **HARD-1** Background `URLSession` spike (M5)
- [ ] **HARD-2** Cancel upload API + remote cleanup where supported

### Docs & PRD sync

- [ ] **DOC-1** Update README platform + upload guidance
- [ ] **DOC-2** Update GoogleDrive.md / OneDrive.md with resumable flow
- [ ] **DOC-3** Link this plan from QCam PRD §7.4
- [ ] **DOC-4** Add manual QA runbook (`Docs/QCamUploadQA.md`)

---

## 13. Open questions

| # | Question | Proposal |
|---|----------|----------|
| Q1 | Default chunk size 8 MB vs 16 MB? | **8 MB** for thermal/IO; OneDrive still snap to 320 KiB grid |
| Q2 | Persist session in CloudServiceKit or only in QCam queue? | **Both** — CSK defines type; QCam owns persistence path |
| Q3 | Contribute Path A upstream before QCam ships? | Yes if M0 completes in ≤3 days; else Path C |
| Q4 | Deprecate `uploadData` for large sizes at runtime? | Log warning if `data.count > 4_194_304` |

---

## 14. References

- QCam PRD: `/Volumes/SandE/Developer/apps-main/trinity-camera/docs/qcam-cloud-sync-kit-prd.md`
- OpenDAL Writer: `.build/opendal/core/core/src/types/write/writer.rs`
- OpenDAL OneDrive writer: `.build/opendal/core/services/onedrive/src/writer.rs`
- OpenDAL Google Drive writer: `.build/opendal/core/services/gdrive/src/writer.rs`
- CloudServiceKit review: [CodeReviewFixGuide.md](./CodeReviewFixGuide.md)
- Swift concurrency skill: `.agents/skills/swift-concurrency/SKILL.md`
