import Foundation

/// A simple time provider used to make time-based cache behavior testable.
///
/// `SwiftUIQuery` uses wall-clock time for:
/// - cache expiration (`cacheTime`)
/// - staleness (`staleTime`)
///
/// Inject a custom clock in tests to avoid flakiness and to deterministically
/// assert fresh → stale → expired transitions.
public struct QueryClock: Sendable {
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public static let system = QueryClock()
}

