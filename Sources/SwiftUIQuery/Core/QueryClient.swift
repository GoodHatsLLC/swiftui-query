import Foundation

/// Central coordinator for all query operations.
///
/// QueryClient manages:
/// - Cache access and invalidation
/// - Active query tracking
/// - Prefetching
/// - Global configuration
///
/// Access via the shared instance or inject via environment:
/// ```swift
/// @Environment(\.queryClient) var client
/// ```
@MainActor
public final class QueryClient: Sendable {
    // MARK: - Shared Instance

    /// Shared query client instance
    public static let shared = try! QueryClient()

    // MARK: - Properties

    /// The underlying cache
    let cache: QueryCache

    /// Clock used for time-based cache behavior.
    public let clock: QueryClock

    /// Default options for queries
    public let defaultOptions: QueryOptions

    /// Tracks invalidation chains to detect cycles
    let invalidationTracker: InvalidationTracker

    /// Emits app lifecycle events for automatic refetch behavior.
    let lifecycleMonitor: AppLifecycleMonitor

    /// Emits network connectivity changes for automatic refetch behavior.
    let connectivityMonitor: ConnectivityMonitor

    /// Track active queries for refetching on invalidation.
    /// Multiple observers may exist for the same key.
    private var activeQueries: [String: [AnyWeakQueryObserver]] = [:]

    // MARK: - Initialization

    public init(
        storage: CacheStorageKind = .inMemory,
        clock: QueryClock = .system,
        defaultOptions: QueryOptions = .default
    ) throws {
        self.cache = try QueryCache(storage: storage, clock: clock)
        self.clock = clock
        self.defaultOptions = defaultOptions
        self.invalidationTracker = InvalidationTracker(configuration: .default)
        self.lifecycleMonitor = .shared
        self.connectivityMonitor = .shared
    }

    /// For testing with a specific cache
    internal init(
        cache: QueryCache,
        clock: QueryClock = .system,
        defaultOptions: QueryOptions = .default,
        invalidationTracking: InvalidationTracker.Configuration = .default,
        lifecycleMonitor: AppLifecycleMonitor = .shared,
        connectivityMonitor: ConnectivityMonitor = .shared
    ) {
        self.cache = cache
        self.clock = clock
        self.defaultOptions = defaultOptions
        self.invalidationTracker = InvalidationTracker(configuration: invalidationTracking)
        self.lifecycleMonitor = lifecycleMonitor
        self.connectivityMonitor = connectivityMonitor
    }
    
    // MARK: - Query API

    /// Fetch data for a query, using cache when fresh
    public func fetch<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws -> K.Response {
        try await fetchWithResult(key, options: options, fetcher: fetcher).data
    }

    /// Fetch data with metadata about cache status.
    ///
    /// Returns a `FetchResult` containing the data along with information about:
    /// - Whether the data came from cache
    /// - Whether the cached data is stale
    /// - Whether a background refresh was triggered
    ///
    /// Use this when you need to show UI indicators for stale/refreshing data:
    /// ```swift
    /// let result = try await queryClient.fetchWithResult(query) { ... }
    /// if result.isTentative {
    ///     // Show data with "refreshing" indicator
    /// }
    /// ```
    public func fetchWithResult<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws -> FetchResult<K.Response> {
        let opts = options ?? defaultOptions

        // Check cache first
        if let cached = try await cache.get(identity: key.identity, as: K.Response.self) {
            if !cached.isStale {
                return FetchResult(
                    data: cached.data,
                    isFromCache: true,
                    isStale: false,
                    isRefreshing: false
                )
            }

            // Imperative fetches make stale refresh failures explicit. Observed
            // queries still use stale-while-revalidate through `QueryObserver`.
        }

        // No fresh cache - fetch fresh.
        let data = try await fetchAndCache(key: key, options: opts, fetcher: fetcher)
        return FetchResult(
            data: data,
            isFromCache: false,
            isStale: false,
            isRefreshing: false
        )
    }
    
    /// Create an observable query state for SwiftUI
    public func query<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) -> QueryObserver<K> {
        let observer = QueryObserver(
            key: key,
            fetcher: fetcher,
            cache: cache,
            options: options ?? defaultOptions,
            clock: clock,
            lifecycleMonitor: lifecycleMonitor,
            connectivityMonitor: connectivityMonitor,
            client: self
        )

        return observer
    }
    
    // MARK: - Invalidation API

    /// Invalidate all queries matching the tag prefix
    ///
    /// This method tracks the invalidation chain to detect cyclical dependencies.
    /// If a cycle is detected, behavior depends on the `InvalidationTracker.Configuration`:
    /// - With `throwOnCycle: true`, throws `InvalidationTracker.TrackerError.cycleDetected`
    /// - With `throwOnCycle: false` (default), logs a warning and skips the cyclic invalidation
    ///
    /// - Parameter tag: The tag to invalidate (invalidates all queries with matching tag prefix)
    /// - Parameter source: Optional source identifier for debugging (e.g., "CreatePostMutation")
    public func invalidate(tag: QueryTag, source: String? = nil) async throws {
        try await invalidationTracker.withInvalidation(tag: tag, source: source) {
            let invalidatedKeys = try await cache.invalidate(tag: tag)
            await triggerRefetches(forKeys: invalidatedKeys)
            cleanupActiveQueries()
        }
    }

    /// Invalidate a specific query by key
    ///
    /// - Parameter key: The query key to invalidate
    /// - Parameter source: Optional source identifier for debugging
    public func invalidate<K: QueryKey>(_ key: K, source: String? = nil) async throws {
        try await invalidationTracker.withInvalidation(key: key.storageKey, source: source) {
            try await cache.invalidate(identity: key.identity)
            await triggerRefetches(forKeys: [key.storageKey])
        }
    }

    /// Get invalidation tracking statistics
    var invalidationStats: InvalidationTracker.Stats {
        invalidationTracker.stats
    }
    
    // MARK: - Direct Cache Manipulation
    
    /// Set query data directly in cache
    public func setQueryData<K: QueryKey>(_ key: K, data: K.Response) async throws {
        try await cache.set(
            identity: key.identity,
            data: data,
            tags: key.cacheTags,
            staleTime: defaultOptions.staleTime,
            cacheTime: defaultOptions.cacheTime
        )
    }
    
    /// Get cached data for a query
    public func getQueryData<K: QueryKey>(_ key: K) async throws -> K.Response? {
        try await cache.get(identity: key.identity, as: K.Response.self)?.data
    }
    
    /// Remove a query from cache
    public func removeQueryData<K: QueryKey>(_ key: K) async throws {
        try await cache.remove(identity: key.identity)
    }
    
    // MARK: - Prefetching
    
    /// Prefetch a query in the background
    public func prefetch<K: QueryKey>(
        _ key: K,
        options: QueryOptions? = nil,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws {
        let opts = options ?? defaultOptions
        
        // Only prefetch if not already cached and fresh
        if let cached = try await cache.get(identity: key.identity, as: K.Response.self),
           !cached.isStale {
            return
        }
        
        _ = try await fetchAndCache(key: key, options: opts, fetcher: fetcher)
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached data
    public func clear() async throws {
        try await cache.clear()
    }
    
    /// Run garbage collection
    public func collectGarbage() async throws {
        _ = try await cache.collectGarbage()
        cleanupActiveQueries()
    }
    
    /// Get cache statistics
    public func stats() async throws -> CacheStats {
        try await cache.stats()
    }
    
    // MARK: - Private Helpers
    
    private func fetchAndCache<K: QueryKey>(
        key: K,
        options: QueryOptions,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) async throws -> K.Response {
        let data = try await fetcher()
        
        try await cache.set(
            identity: key.identity,
            data: data,
            tags: key.cacheTags,
            staleTime: options.staleTime,
            cacheTime: options.cacheTime
        )
        
        return data
    }

    private func triggerRefetches(forKeys keys: [String]) async {
        let observers = activeObservers(forKeys: keys)
        guard !observers.isEmpty else { return }
        for observer in observers {
            await observer.triggerRefetch()
        }
    }

    private func activeObservers(forKeys keys: [String]) -> [any QueryObserverProtocol] {
        var observers: [any QueryObserverProtocol] = []
        var seen: Set<ObjectIdentifier> = []

        for key in keys {
            for wrapper in activeQueries[key] ?? [] {
                guard let observer = wrapper.observer else { continue }
                let identifier = ObjectIdentifier(observer)
                if seen.insert(identifier).inserted {
                    observers.append(observer)
                }
            }
        }

        return observers
    }
    
    private func cleanupActiveQueries() {
        activeQueries = activeQueries.compactMapValues { wrappers in
            let alive = wrappers.filter { $0.observer != nil }
            return alive.isEmpty ? nil : alive
        }
    }

    func registerActiveObserver(_ observer: QueryObserverProtocol, forKey key: String) {
        let identifier = ObjectIdentifier(observer)
        var wrappers = activeQueries[key] ?? []

        if !wrappers.contains(where: { $0.identifier == identifier }) {
            wrappers.append(AnyWeakQueryObserver(observer))
        }

        activeQueries[key] = wrappers
        cleanupActiveQueries()
    }

    func unregisterActiveObserver(_ observer: QueryObserverProtocol, forKey key: String) {
        let identifier = ObjectIdentifier(observer)

        if var wrappers = activeQueries[key] {
            wrappers.removeAll { $0.identifier == identifier || $0.observer == nil }

            if wrappers.isEmpty {
                activeQueries.removeValue(forKey: key)
            } else {
                activeQueries[key] = wrappers
            }
        }

        cleanupActiveQueries()
    }
}

// MARK: - Type-Erased Observer Wrapper

/// Weak wrapper for active query tracking
private final class AnyWeakQueryObserver: @unchecked Sendable {
    private weak var _observer: AnyObject?

    init(_ observer: QueryObserverProtocol) {
        self._observer = observer
    }
    
    var observer: (any QueryObserverProtocol)? {
        _observer as? any QueryObserverProtocol
    }

    var identifier: ObjectIdentifier? {
        _observer.map(ObjectIdentifier.init)
    }
}

/// Protocol for type-erased query observer access
@MainActor
protocol QueryObserverProtocol: AnyObject {
    func triggerRefetch() async
}

extension QueryObserver: QueryObserverProtocol {
    func triggerRefetch() async {
        await markInvalidationAndRefetch()
    }
}
