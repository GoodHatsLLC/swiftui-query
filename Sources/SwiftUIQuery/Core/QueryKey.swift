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
///     var identity: QueryIdentity { QueryIdentity("users", userId) }
///     var invalidationTags: Set<QueryTag> { [QueryTag("users")] }
/// }
/// ```
public protocol QueryKey: Hashable, Sendable {
    /// The type of data this query returns
    associatedtype Response: Codable & Sendable

    /// Exact identity for this query instance.
    ///
    /// The library derives its storage key from this structured identity. Callers
    /// should model the resource being fetched, not hand-build storage strings.
    var identity: QueryIdentity { get }

    /// Additional tags that should invalidate this query.
    ///
    /// The query's exact identity tag is always included automatically.
    var invalidationTags: Set<QueryTag> { get }
}

extension QueryKey {
    public var invalidationTags: Set<QueryTag> { [] }
}

extension QueryKey {
    var storageKey: String { identity.storageKey }

    var cacheTags: Set<QueryTag> {
        var tags = invalidationTags
        tags.insert(identity.tag)
        return tags
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
    
    /// Number of retry attempts after the first failure
    public var retryAttempts: Int
    
    /// Delay between retries
    public var retryDelay: Duration
    
    public init(
        staleTime: Duration = .seconds(30),
        cacheTime: Duration = .days(7),
        refetchOnFocus: Bool = false,
        refetchOnReconnect: Bool = true,
        retryAttempts: Int = 3,
        retryDelay: Duration = .seconds(1)
    ) {
        self.staleTime = staleTime
        self.cacheTime = cacheTime
        self.refetchOnFocus = refetchOnFocus
        self.refetchOnReconnect = refetchOnReconnect
        self.retryAttempts = retryAttempts
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
