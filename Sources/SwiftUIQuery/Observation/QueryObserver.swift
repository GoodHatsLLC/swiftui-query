import Foundation
#if canImport(Observation)
import Observation
#endif

/// Bridges cache changes to @Observable for SwiftUI integration.
///
/// QueryObserver manages the lifecycle of a query:
/// 1. Checks cache for existing data
/// 2. Returns cached data immediately if available
/// 3. Triggers background refetch if data is stale
/// 4. Subscribes to cache changes for reactive updates
#if canImport(Observation)
@Observable
#endif
@MainActor
public final class QueryObserver<K: QueryKey> {
    // MARK: - Public State
    
    /// The current query state
    public private(set) var state: QueryState<K.Response>
    
    // MARK: - Private Properties

    private let key: K
    private let fetcher: @Sendable () async throws -> K.Response
    private let cache: QueryCache
    private let options: QueryOptions
    private let clock: QueryClock
    private let lifecycleMonitor: AppLifecycleMonitor
    private let connectivityMonitor: ConnectivityMonitor
    private weak var client: QueryClient?

    private var observationTask: Task<Void, Never>?
    private var fetchTask: Task<K.Response, Error>?
    /// Invalidation epoch at which the current `fetchTask` started.
    private var fetchTaskEpoch = 0
    /// Bumped each time the observer learns of an invalidation. Lets a forced
    /// invalidation refetch supersede a fetch that *predates* the invalidation,
    /// while two concurrent manual refetches (same epoch) still de-duplicate.
    private var invalidationEpoch = 0
    /// Guards fetch teardown so a superseded fetch can't clobber the new one's state.
    private var fetchGeneration = 0
    private var lifecycleTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var isStarted = false
    private var isObserving = false  // True once observeCacheChanges() is running
    private var lastObservedStale: Bool?
    private var storageKey: String { key.storageKey }

    // MARK: - Initialization

    init(
        key: K,
        fetcher: @escaping @Sendable () async throws -> K.Response,
        cache: QueryCache,
        options: QueryOptions = .default,
        clock: QueryClock = .system,
        lifecycleMonitor: AppLifecycleMonitor = .shared,
        connectivityMonitor: ConnectivityMonitor = .shared,
        client: QueryClient? = nil
    ) {
        self.key = key
        self.fetcher = fetcher
        self.cache = cache
        self.options = options
        self.clock = clock
        self.lifecycleMonitor = lifecycleMonitor
        self.connectivityMonitor = connectivityMonitor
        self.client = client
        self.state = QueryState()
    }
    
    // MARK: - Lifecycle
    
    /// Start observing the cache and fetching data
    public func startObserving() {
        guard !isStarted else { return }
        isStarted = true

        client?.registerActiveObserver(self, forKey: storageKey)

        let cache = cache
        let identity = key.identity
        observationTask = Task { @MainActor [weak self, cache, identity] in
            guard let self else { return }
            await self.loadFromCache()

            self.isObserving = true
            defer { self.isObserving = false }

            for await entry in await cache.observe(identity: identity) {
                guard !Task.isCancelled else { break }

                if let entry {
                    do {
                        let isStale = entry.isStale(at: clock.now())
                        let data = try entry.decode(as: K.Response.self)
                        state.setData(data, isStale: isStale)

                        let previouslyStale = lastObservedStale ?? false
                        lastObservedStale = isStale

                        // Avoid infinite fetch loops when staleTime is .zero by
                        // only refreshing on the *transition* from fresh -> stale.
                        if options.staleTime > .zero, !entry.isInvalidated, isStale, !previouslyStale {
                            try? await fetchInBackground()
                        } else if entry.isInvalidated, client == nil {
                            // Fix #5 (no-client fallback): with a client, invalidation
                            // refetch is driven authoritatively by
                            // QueryClient.triggerRefetch (which supersedes stale
                            // in-flight fetches). Without a client, the observe loop
                            // must drive it. De-duped via the in-flight `fetchTask`
                            // guard, and one-shot since the next successful fetch
                            // clears `isInvalidated`.
                            try? await fetchInBackground()
                        }
                    } catch {
                        // Decode error - data corrupted, refetch
                        _ = try? await fetch(force: true)
                    }
                }
            }
        }

        if options.refetchOnFocus {
            lifecycleTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let stream = await self.lifecycleMonitor.events()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    guard self.isStarted else { break }

                    switch event {
                    case .didBecomeActive:
                        try? await self.refetchForTrigger()
                    }
                }
            }
        }

        if options.refetchOnReconnect {
            connectivityTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let stream = await self.connectivityMonitor.statuses()
                var previousStatus: ConnectivityMonitor.Status?

                for await status in stream {
                    guard !Task.isCancelled else { break }
                    guard self.isStarted else { break }

                    if previousStatus == .unsatisfied, status == .satisfied {
                        try? await self.refetchForTrigger()
                    }
                    previousStatus = status
                }
            }
        }
    }
    
    /// Stop observing and cancel pending fetches
    public func stopObserving() {
        isStarted = false
        isObserving = false
        observationTask?.cancel()
        observationTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        connectivityTask?.cancel()
        connectivityTask = nil

        client?.unregisterActiveObserver(self, forKey: storageKey)
    }

    @MainActor
    deinit {
        observationTask?.cancel()
        fetchTask?.cancel()
        lifecycleTask?.cancel()
        connectivityTask?.cancel()
        // Eagerly drop our registry entry instead of waiting for the client's
        // lazy cleanup pass (#17).
        client?.unregisterActiveObserver(self, forKey: storageKey)
    }
    
    // MARK: - Public Actions
    
    /// Manually trigger a refetch
    @discardableResult
    public func refetch() async throws -> K.Response {
        try await fetch(force: true)
    }

    /// Invalidation-driven forced refetch used by `QueryClient`. Marks a new
    /// invalidation epoch so the refetch supersedes any in-flight fetch that
    /// predates the invalidation (#2), then refetches.
    func markInvalidationAndRefetch() async {
        invalidationEpoch &+= 1
        _ = try? await fetch(force: true)
    }
    
    /// Invalidate and refetch
    ///
    /// Routes through QueryClient to ensure proper cycle detection via InvalidationTracker.
    public func invalidate() async throws {
        if let client {
            // Route through QueryClient for cycle detection
            try await client.invalidate(key, source: "QueryObserver<\(K.self)>")
        } else {
            // Fallback: direct cache invalidation (no cycle detection)
            try await cache.invalidate(identity: key.identity)
            _ = try await refetch()
        }
    }
    
    // MARK: - Private Methods
    
    private func loadFromCache() async {
        do {
            // Try loading from cache, including expired entries as a stale fallback.
            // This implements stale-while-revalidate even for expired data, ensuring
            // the user sees their previous data immediately while fresh data loads.
            if let cached = try await cache.getIncludingExpired(identity: key.identity, as: K.Response.self) {
                state.setData(cached.data, isStale: cached.isStale)
                lastObservedStale = cached.isStale

                // Background refetch if data is stale or expired
                if cached.isStale {
                    try? await fetchInBackground()
                }
            } else {
                lastObservedStale = false
                // No cache - fetch immediately
                _ = try? await fetch(force: false)
            }
        } catch {
            lastObservedStale = false
            // Cache read failed - fetch from network
            _ = try? await fetch(force: false)
        }
    }
    
    @discardableResult
    private func fetch(force: Bool) async throws -> K.Response {
        // Deduplicate in-flight fetches. A forced refetch (#2) supersedes an
        // in-flight fetch ONLY when that fetch predates the latest invalidation
        // (`fetchTaskEpoch < invalidationEpoch`) — so an invalidation can't be
        // defeated by piggybacking on a stale request, while two concurrent
        // manual refetches (same epoch) still share one request.
        if let task = fetchTask {
            let supersedesStaleInFlight = force && fetchTaskEpoch < invalidationEpoch
            if !supersedesStaleInFlight {
                return try await task.value
            }
            task.cancel()
        }

        fetchGeneration &+= 1
        let generation = fetchGeneration
        fetchTaskEpoch = invalidationEpoch

        state.setFetching(true)

        let task = Task { [fetcher, options] () throws -> K.Response in
            let maxAttempts = max(1, options.retryAttempts + 1)
            var lastError: Error?

            for attempt in 0..<maxAttempts {
                do {
                    return try await fetcher()
                } catch {
                    lastError = error

                    // Don't retry on cancellation
                    if error.isCancellation { throw error }

                    // Wait before retry
                    if attempt < maxAttempts - 1 {
                        try await Task.sleep(for: options.retryDelay)
                    }
                }
            }

            throw lastError ?? CancellationError()
        }

        fetchTask = task

        defer {
            // Only tear down shared state if we are still the current fetch; a
            // later forced fetch may have superseded us.
            if fetchGeneration == generation {
                fetchTask = nil
                state.setFetching(false)
            }
        }

        do {
            let data = try await task.value

            // If a later forced fetch superseded us, discard this (now stale)
            // result rather than writing it back over the fresh one. Covers
            // fetchers that swallow cancellation and return anyway.
                guard fetchGeneration == generation else { throw CancellationError() }

            try await cache.set(
                identity: key.identity,
                data: data,
                tags: key.cacheTags,
                staleTime: options.staleTime,
                cacheTime: options.cacheTime
            )

            // Only set data directly if observation loop isn't running yet.
            // When observing, the cache change will trigger setData via observeCacheChanges().
            if !isObserving {
                state.setData(data, isStale: false)
            }
            return data
        } catch {
            // Don't treat cancellation as a primary or background error.
            // Cancellations should never overwrite cached data or change the
            // query status. And if we were superseded, leave state entirely to
            // the superseding fetch.
            if error.isCancellation {
                if fetchGeneration == generation {
                    state.setCancellation(error)
                }
                throw error
            }

            if state.hasData {
                state.setBackgroundError(error)
            } else {
                state.setError(error)
            }

            throw error
        }
    }
    
    private func fetchInBackground() async throws {
        _ = try await fetch(force: false)
    }

    private func refetchForTrigger() async throws {
        // Avoid piling on background fetches if we're already fetching.
        guard fetchTask == nil else { return }

        if state.hasData {
            try await fetchInBackground()
        } else {
            _ = try await fetch(force: false)
        }
    }
}

// MARK: - Convenience Extensions

extension QueryObserver {
    /// Access the underlying data directly
    public var data: K.Response? { state.data }
    
    /// Access the underlying error directly
    public var error: Error? { state.error }
    
    /// Check if currently loading
    public var isLoading: Bool { state.isLoading }
    
    /// Check if refetching in background
    public var isRefetching: Bool { state.isRefetching }

    /// True when the most recent fetch was cancelled
    public var wasCancelled: Bool { state.wasCancelled }
}
