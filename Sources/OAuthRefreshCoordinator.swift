import Foundation

/// Coalesces concurrent OAuth refresh requests for the same key.
///
/// Microsoft rotates refresh tokens on each use; parallel refreshes with the same
/// refresh token can invalidate the session and cause a token-exchange storm.
public actor OAuthRefreshCoordinator<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    public init() {}

    public func refresh(
        key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task {
            try await operation()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        return try await task.value
    }
}
