# CloudServiceKit

Swift Package · iOS 17+ / tvOS 17+ / macOS 14+ · Depends on OAuthSwift

## Architecture

- All source is flat in `Sources/` — no nested modules.
- `CloudServiceProvider` protocol defines the file-ops contract; each provider subclass (e.g. `DropboxServiceProvider`) implements it.
- `CloudServiceConnector` is the OAuth2 base class; per-service connectors subclass it.
- `CloudItem` is the universal file/folder model; providers parse service JSON into it via `cloudItemFromJSON(_:)`.
- The library uses a native, modern `URLSession` async/await request engine (replacing `Just.swift`).
- `CloudResumableUploading` + `CloudUploadSession` support pause/resume for Google Drive and OneDrive; chunk reads use `FileChunkReader` (`Task { @concurrent in ... }`) off the main actor.
- `CloudBackgroundUploading` (0.2.0) exposes pure chunk request builders and response parsers for host-owned background `URLSession` uploads — see `Docs/BackgroundUploadSupport.md`.
- Completion handlers and async provider calls run on the **main thread** (via `@MainActor` isolation).

## Gotchas

- Some providers use file ID (Box, Dropbox), others use path. Always check `CloudItem.id` vs `.path` semantics per provider.
- `CloudItem.fixPath(with:)` exists because some services omit path in responses — call it when listing directory contents.
- `refreshAccessTokenHandler` is essential for short-lived tokens (OneDrive). Don't skip it.
- `CloudServiceConnector` uses `UIViewController` for OAuth presentation — this is iOS/Catalyst only. tvOS uses a different flow.
- Extensions on `UIViewController` for `ASWebAuthenticationPresentationContextProviding` are conditionally compiled (`#if targetEnvironment(macCatalyst) || os(iOS)`).

## Code style

- Follow existing patterns: one file per provider, class names end in `ServiceProvider` or `Connector`.
- Keep public API documented with `///` doc comments.
- Tests live in `Tests/CloudServiceKitTests/` and are registered in `Package.swift`.
