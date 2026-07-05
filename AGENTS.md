# CloudServiceKit

Swift Package · iOS 13+ / tvOS 14+ · Depends on OAuthSwift

## Architecture

- All source is flat in `Sources/` — no nested modules.
- `CloudServiceProvider` protocol defines the file-ops contract; each provider subclass (e.g. `DropboxServiceProvider`) implements it.
- `CloudServiceConnector` is the OAuth2 base class; per-service connectors subclass it.
- `CloudItem` is the universal file/folder model; providers parse service JSON into it via `cloudItemFromJSON(_:)`.
- `Just.swift` is a vendored HTTP helper — treat it as a dependency, not project code.
- Completion handlers fire on the **main thread** by convention.

## Gotchas

- Some providers use file ID (Box, Dropbox), others use path. Always check `CloudItem.id` vs `.path` semantics per provider.
- `CloudItem.fixPath(with:)` exists because some services omit path in responses — call it when listing directory contents.
- `refreshAccessTokenHandler` is essential for short-lived tokens (OneDrive). Don't skip it.
- `CloudServiceConnector` uses `UIViewController` for OAuth presentation — this is iOS/Catalyst only. tvOS uses a different flow.
- Extensions on `UIViewController` for `ASWebAuthenticationPresentationContextProviding` are conditionally compiled (`#if targetEnvironment(macCatalyst) || os(iOS)`).

## Code style

- Follow existing patterns: one file per provider, class names end in `ServiceProvider` or `Connector`.
- Keep public API documented with `///` doc comments.
- No tests exist yet — when adding, create a `Tests/` directory and register in Package.swift.
