import Foundation
#if canImport(Observation)
import Observation
#endif

// MARK: - Type-Erased Equality

/// Check if two values are equal when both conform to Equatable, otherwise return false.
/// Uses existential type erasure to handle generic types at runtime.
private func areEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    guard let lhsEquatable = lhs as? any Equatable else { return false }
    return lhsEquatable.isEqual(to: rhs)
}

private extension Equatable {
    func isEqual(to other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

/// The status of a query's data
public enum QueryStatus: String, Sendable, Equatable {
    /// No query has been initiated
    case idle
    /// Query is fetching for the first time (no data yet)
    case pending
    /// Query completed successfully
    case success
    /// Query failed with an error
    case error
}

/// The fetch status of a query (separate from data status)
public enum FetchStatus: String, Sendable, Equatable {
    /// Not currently fetching
    case idle
    /// Currently fetching (initial or background)
    case fetching
    /// Fetch paused (e.g., due to network unavailability)
    case paused
}

/// Result enum for pattern matching in views
public enum QueryResult<T: Sendable>: Sendable {
    case idle
    case loading
    case success(T)
    case error(Error)

    public var data: T? {
        if case .success(let data) = self { return data }
        return nil
    }

    public var error: Error? {
        if case .error(let error) = self { return error }
        return nil
    }
}

// MARK: - Fetch Result

/// Metadata about a fetch operation's result.
///
/// Use this to understand the provenance of returned data and show appropriate UI:
/// - `isFromCache`: Data was returned from cache (may be stale)
/// - `isStale`: Cached data is past its stale time
/// - `isRefreshing`: A background refresh is in progress
///
/// Example usage:
/// ```swift
/// let result = try await queryClient.fetchWithResult(query) { ... }
/// if result.isStale {
///     // Show data with "refreshing" indicator
/// }
/// ```
public struct FetchResult<T: Sendable>: Sendable {
    /// The fetched data
    public let data: T

    /// Whether the data was returned from cache (vs fresh network fetch)
    public let isFromCache: Bool

    /// Whether the cached data is past its stale time
    public let isStale: Bool

    /// Whether a background refresh was triggered for stale data
    public let isRefreshing: Bool

    public init(data: T, isFromCache: Bool, isStale: Bool, isRefreshing: Bool) {
        self.data = data
        self.isFromCache = isFromCache
        self.isStale = isStale
        self.isRefreshing = isRefreshing
    }

    /// Data is tentative (stale and being refreshed)
    public var isTentative: Bool {
        isStale && isRefreshing
    }
}

/// Observable query state for SwiftUI integration.
///
/// This class tracks the complete state of a query, including:
/// - Current data (if any)
/// - Loading states (initial vs background refetch)
/// - Error states
/// - Timestamps
///
/// Use the computed properties for common state checks:
/// ```swift
/// if query.isLoading {
///     ProgressView()
/// } else if let data = query.data {
///     ContentView(data: data)
/// }
/// ```
#if canImport(Observation)
@Observable
#endif
@MainActor
public final class QueryState<T: Sendable>: Sendable {
    // MARK: - Core State
    
    /// The latest successfully fetched data
    public private(set) var data: T?
    
    /// The latest error, if any
    public private(set) var error: Error?

    /// The latest non-fatal error encountered while keeping cached data
    public private(set) var backgroundError: Error?

    /// The latest cancellation event, if any.
    ///
    /// Cancellation is never surfaced as a primary error or background error.
    /// It is tracked here as a non-primary output for consumers who wish to
    /// display it unobtrusively (e.g. a subtle indicator). Cancellation events
    /// never overwrite cached data or change the query's ``status``.
    public private(set) var cancellationError: Error?

    /// When a cancellation last occurred
    public private(set) var cancellationUpdatedAt: Date?

    /// The status of the query data
    public private(set) var status: QueryStatus = .idle
    
    /// The status of the current/last fetch operation
    public private(set) var fetchStatus: FetchStatus = .idle
    
    /// When the data was last successfully updated
    public private(set) var dataUpdatedAt: Date?

    /// When an error last occurred
    public private(set) var errorUpdatedAt: Date?

    /// When a background error last occurred
    public private(set) var backgroundErrorUpdatedAt: Date?
    
    /// Number of times the query has failed consecutively
    public private(set) var failureCount: Int = 0

    /// True when the current cached data is known to be stale.
    public private(set) var isStale: Bool = false
    
    // MARK: - Derived State (React Query style)
    
    /// True when status is pending (first-time load, no data)
    public var isPending: Bool { status == .pending }
    
    /// True when loading for the first time (pending + fetching)
    public var isLoading: Bool { isPending && isFetching }
    
    /// True when query completed successfully
    public var isSuccess: Bool { status == .success }
    
    /// True when query is in error state
    public var isError: Bool { status == .error }
    
    /// True when currently fetching
    public var isFetching: Bool { fetchStatus == .fetching }
    
    /// True when refetching in the background (have data + fetching)
    public var isRefetching: Bool { isSuccess && isFetching }

    /// True when refreshing data in the background.
    public var isRefreshing: Bool { isRefetching }
    
    /// True when fetch is paused
    public var isPaused: Bool { fetchStatus == .paused }
    
    /// True if data exists, regardless of staleness
    public var hasData: Bool { data != nil }

    /// True when a background refresh failed but cached data remains
    public var hasBackgroundError: Bool { backgroundError != nil }

    /// True when the most recent fetch was cancelled
    public var wasCancelled: Bool { cancellationError != nil }
    
    // MARK: - Result for Pattern Matching
    
    /// Convenience for switch statements in views
    public var result: QueryResult<T> {
        switch status {
        case .idle:
            return .idle
        case .pending:
            return .loading
        case .success:
            if let data {
                return .success(data)
            }
            return .loading
        case .error:
            if let error {
                return .error(error)
            }
            return .idle
        }
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    public init(data: T) {
        self.data = data
        self.status = .success
        self.dataUpdatedAt = Date()
    }
    
    // MARK: - Internal State Updates
    
    func setData(_ data: T, isStale: Bool = false) {
        // Skip update if already in success state with same data (when Equatable)
        if status == .success, let existing = self.data, areEqual(existing, data), self.isStale == isStale {
            return
        }
        self.data = data
        self.isStale = isStale
        self.status = .success
        self.dataUpdatedAt = Date()
        self.error = nil
        self.backgroundError = nil
        self.backgroundErrorUpdatedAt = nil
        self.cancellationError = nil
        self.cancellationUpdatedAt = nil
        self.failureCount = 0
    }

    func setError(_ error: Error) {
        self.error = error
        self.errorUpdatedAt = Date()
        self.backgroundError = nil
        self.backgroundErrorUpdatedAt = nil
        self.failureCount += 1
        // Only set status to error if we don't have data
        if data == nil {
            self.status = .error
            self.isStale = false
        }
    }

    func setBackgroundError(_ error: Error) {
        self.error = error
        self.errorUpdatedAt = Date()
        self.backgroundError = error
        self.backgroundErrorUpdatedAt = Date()
        self.failureCount += 1
    }

    func setCancellation(_ error: Error) {
        self.cancellationError = error
        self.cancellationUpdatedAt = Date()
        // If the initial (no-data) fetch was cancelled, don't leave the query
        // stuck in `.pending` forever — return to `.idle` so it can retry (#12).
        if data == nil && status == .pending {
            self.status = .idle
        }
    }

    func setFetching(_ fetching: Bool) {
        self.fetchStatus = fetching ? .fetching : .idle
        if fetching && data == nil && status != .error {
            self.status = .pending
        }
    }
    
    func setPaused(_ paused: Bool) {
        self.fetchStatus = paused ? .paused : .idle
    }
    
    func reset() {
        self.data = nil
        self.error = nil
        self.status = .idle
        self.fetchStatus = .idle
        self.isStale = false
        self.dataUpdatedAt = nil
        self.errorUpdatedAt = nil
        self.backgroundError = nil
        self.backgroundErrorUpdatedAt = nil
        self.cancellationError = nil
        self.cancellationUpdatedAt = nil
        self.failureCount = 0
    }
}

// MARK: - Equatable for Value Types

extension QueryState: Equatable where T: Equatable {
    // Equatable requires nonisolated == operator, which is safe here because
    // we only compare Sendable value types that don't require actor isolation.
    public nonisolated static func == (lhs: QueryState<T>, rhs: QueryState<T>) -> Bool {
        MainActor.assumeIsolated {
            lhs.data == rhs.data &&
            lhs.status == rhs.status &&
            lhs.fetchStatus == rhs.fetchStatus &&
            lhs.isStale == rhs.isStale
        }
    }
}
