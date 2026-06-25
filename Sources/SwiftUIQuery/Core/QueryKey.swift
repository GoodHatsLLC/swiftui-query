import Foundation

/// Defines a cacheable query with type-safe response.
///
/// Implement this protocol to define your queries:
///
/// ```swift
/// struct UserQuery: QueryKey {
///     typealias Response = User
///     let userId: Int
///
///     var cacheKey: String { "user:\(userId)" }
///     var tags: Set<QueryTag> { [.users, .user(userId)] }
/// }
/// ```
public protocol QueryKey: Hashable, Sendable {
    /// The type of data this query returns
    associatedtype Response: Codable & Sendable
    
    /// Unique cache identifier for this specific query instance.
    /// Should be deterministic and unique across all query instances.
    var cacheKey: String { get }
    
    /// Tags for hierarchical invalidation.
    /// Include all relevant tags that should trigger cache invalidation.
    var tags: Set<QueryTag> { get }
}

// MARK: - Type-Erased Query Key

/// Type-erased wrapper for QueryKey to store in collections
public struct AnyQueryKey: Hashable, Sendable {
    public let cacheKey: String
    public let tags: Set<QueryTag>
    private let hashValue_: Int
    
    public init<K: QueryKey>(_ key: K) {
        self.cacheKey = key.cacheKey
        self.tags = key.tags
        self.hashValue_ = key.hashValue
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
        hasher.combine(hashValue_)
    }
    
    public static func == (lhs: AnyQueryKey, rhs: AnyQueryKey) -> Bool {
        lhs.cacheKey == rhs.cacheKey && lhs.hashValue_ == rhs.hashValue_
    }
}

// MARK: - Query Configuration

/// Configuration options for a query
public struct QueryOptions: Sendable, Equatable {
    /// Time after which cached data is considered stale
    public var staleTime: Duration
    
    /// Time after which cached data is garbage collected
    public var cacheTime: Duration
    
    /// Whether to refetch when the app becomes active (focus/foreground).
    public var refetchOnFocus: Bool
    
    /// Whether to refetch when network reconnects
    public var refetchOnReconnect: Bool
    
    /// Number of retry attempts on failure
    public var retryCount: Int
    
    /// Delay between retries
    public var retryDelay: Duration
    
    public init(
        staleTime: Duration = .seconds(30),
        cacheTime: Duration = .days(7),
        refetchOnFocus: Bool = false,
        refetchOnReconnect: Bool = true,
        retryCount: Int = 3,
        retryDelay: Duration = .seconds(1)
    ) {
        self.staleTime = staleTime
        self.cacheTime = cacheTime
        self.refetchOnFocus = refetchOnFocus
        self.refetchOnReconnect = refetchOnReconnect
        self.retryCount = retryCount
        self.retryDelay = retryDelay
    }
    
    public static let `default` = QueryOptions()
}

// MARK: - Duration Extensions

extension Duration {
    public static func minutes(_ minutes: Int) -> Duration {
        .seconds(minutes * 60)
    }
    
    public static func hours(_ hours: Int) -> Duration {
        .seconds(hours * 3600)
    }
    
    public static func days(_ days: Int) -> Duration {
        .seconds(days * 86400)
    }
    
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
