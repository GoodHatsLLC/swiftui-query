import Foundation
#if canImport(CryptoKit)
import CryptoKit
private typealias PlatformSHA256 = CryptoKit.SHA256
#else
import Crypto
private typealias PlatformSHA256 = Crypto.SHA256
#endif

/// Result of a cache lookup
struct CacheResult<T: Sendable>: Sendable {
    let data: T
    let isStale: Bool
    let updatedAt: Date
    
    init(data: T, isStale: Bool, updatedAt: Date) {
        self.data = data
        self.isStale = isStale
        self.updatedAt = updatedAt
    }
}

/// Thread-safe cache manager.
///
/// `QueryCache` owns the in-memory L1 cache and the change-event broadcaster;
/// durable persistence is delegated to an injected ``CacheStorage`` backend
/// (GRDB / in-memory / Codable). Change events are produced by an in-memory
/// broadcaster fired on every write — identical across all backends — rather
/// than by database observation.
actor QueryCache {
    private let storage: any CacheStorage
    private var memoryCache: [String: AnyCacheEntry] = [:]
    private let clock: QueryClock
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Ensure deterministic encoding so payload hashing and observation deduplication
        // remain stable even for types that contain Dictionaries.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    // MARK: - Eventing (in-memory broadcaster)

    /// Per-key fan-out of cache-change events. Replaces GRDB `ValueObservation`.
    private var subscribers: [String: [UUID: Subscriber]] = [:]

    /// One observation subscription: its continuation plus a per-subscriber
    /// de-dup baseline so a change only emits when the payload hash or the
    /// invalidation flag actually changes (mirrors GRDB `removeDuplicates`).
    private struct Subscriber {
        let continuation: AsyncStream<CacheRecord?>.Continuation
        var lastSignature: BroadcastSignature?
    }

    /// Identity used to suppress duplicate emissions: payload hash + invalidation.
    /// Timestamp-only changes do not alter it, which preserves the
    /// `staleTime == .zero` no-loop guarantee.
    private struct BroadcastSignature: Equatable {
        let hash: String
        let isInvalidated: Bool
    }

    // MARK: - Initialization

    /// Inject a storage backend directly (advanced / custom backends).
    init(storage: any CacheStorage, clock: QueryClock = .system) {
        self.storage = storage
        self.clock = clock
    }

    /// Create a cache with the chosen storage backend (default: in-memory).
    init(storage kind: CacheStorageKind = .inMemory, clock: QueryClock = .system) throws {
        self.storage = try kind.makeStorage()
        self.clock = clock
    }
    
    // MARK: - Read Operations
    
    /// Get a cached value by key
    func get<T: Codable & Sendable>(identity: QueryIdentity, as type: T.Type) async throws -> CacheResult<T>? {
        try await get(storageKey: identity.storageKey, as: type)
    }

    func get<T: Codable & Sendable>(storageKey: String, as type: T.Type) async throws -> CacheResult<T>? {
        let now = clock.now()

        // Check memory cache first
        if let entry = memoryCache[storageKey] as? CacheEntry<T> {
            if entry.isExpired(at: now) {
                memoryCache.removeValue(forKey: storageKey)
            } else {
            return CacheResult(
                data: entry.data,
                isStale: entry.isStale(at: now),
                updatedAt: entry.updatedAt
            )
            }
        }

        // Fall back to persistent store
        guard let record = try await storage.read(storageKey: storageKey, now: now) else {
            return nil
        }
        let data = try decoder.decode(T.self, from: record.responseData)
        return CacheResult(
            data: data,
            isStale: record.isStale(at: now),
            updatedAt: record.updatedAt
        )
    }
    
    /// Get a cached value by key, including expired entries as a stale fallback.
    ///
    /// Unlike `get(key:as:)`, this method returns expired entries marked as stale
    /// rather than filtering them out. Use this when you want to display stale data
    /// while fetching fresh data (stale-while-revalidate for expired entries).
    func getIncludingExpired<T: Codable & Sendable>(identity: QueryIdentity, as type: T.Type) async throws -> CacheResult<T>? {
        try await getIncludingExpired(storageKey: identity.storageKey, as: type)
    }

    func getIncludingExpired<T: Codable & Sendable>(storageKey: String, as type: T.Type) async throws -> CacheResult<T>? {
        // Check non-expired cache first (normal path)
        if let result = try await get(storageKey: storageKey, as: type) {
            return result
        }

        // Fall back to expired entries in persistent store
        guard let record = try await storage.readIgnoringExpiry(storageKey: storageKey) else {
            return nil
        }
        let data = try decoder.decode(T.self, from: record.responseData)
        // Always mark as stale since the entry is expired
        return CacheResult(
            data: data,
            isStale: true,
            updatedAt: record.updatedAt
        )
    }

    /// Check if a key exists in cache
    func exists(identity: QueryIdentity) async throws -> Bool {
        try await exists(storageKey: identity.storageKey)
    }

    func exists(storageKey: String) async throws -> Bool {
        let now = clock.now()
        if let entry = memoryCache[storageKey] {
            if entry.isExpired(at: now) {
                memoryCache.removeValue(forKey: storageKey)
            } else {
                return true
            }
        }

        return try await storage.exists(storageKey: storageKey, now: now)
    }
    
    // MARK: - Write Operations
    
    /// Set a cached value
    func set<T: Codable & Sendable>(
        identity: QueryIdentity,
        data: T,
        tags: Set<QueryTag>,
        staleTime: Duration,
        cacheTime: Duration
    ) async throws {
        var tags = tags
        tags.insert(identity.tag)
        try await set(
            storageKey: identity.storageKey,
            data: data,
            tags: tags,
            staleTime: staleTime,
            cacheTime: cacheTime
        )
    }

    func set<T: Codable & Sendable>(
        storageKey: String,
        data: T,
        tags: Set<QueryTag>,
        staleTime: Duration,
        cacheTime: Duration
    ) async throws {
        let now = clock.now()
        let responseData = try encoder.encode(data)
        let staleAt = now.addingTimeInterval(staleTime.timeInterval)
        let expiresAt = now.addingTimeInterval(cacheTime.timeInterval)

        // Persist first (write-through). Only update the in-memory L1 cache and
        // broadcast once the backend has accepted the write, so a failed persist
        // can't leave memory and storage divergent (#15). `createdAt` is preserved
        // on overwrite inside the backend's upsert.
        let record = CacheRecord(
            storageKey: storageKey,
            queryHash: responseData.sha256Hash,
            responseData: responseData,
            responseType: String(describing: T.self),
            tags: tags,
            createdAt: now,
            updatedAt: now,
            staleAt: staleAt,
            expiresAt: expiresAt,
            etag: nil,
            isInvalidated: false
        )
        try await storage.upsert(record)

        memoryCache[storageKey] = CacheEntry(
            data: data,
            tags: tags,
            updatedAt: now,
            staleAt: staleAt,
            expiresAt: expiresAt
        )
        broadcast(storageKey: storageKey, record: record)
    }
    
    // MARK: - Invalidation
    
    /// Invalidate all entries matching a tag prefix
    func invalidate(tag: QueryTag) async throws -> [String] {
        // Mark as stale in memory
        var memoryKeys: [String] = []
        for (key, entry) in memoryCache {
            if entry.tags.containsMatch(for: tag) {
                entry.markStale()
                memoryKeys.append(key)
            }
        }

        // Mark as invalidated in the persistent store; returns ALL matched keys
        // (including expired ones — fix #7).
        let now = clock.now()
        let storeKeys = try await storage.invalidate(tag: tag, now: now)

        let allKeys = Array(Set(memoryKeys + storeKeys))

        // Notify observers of the invalidation toggle.
        for key in allKeys {
            await broadcastCurrent(storageKey: key)
        }

        return allKeys
    }

    /// Invalidate a specific key
    func invalidate(identity: QueryIdentity) async throws {
        try await invalidate(storageKey: identity.storageKey)
    }

    func invalidate(storageKey: String) async throws {
        memoryCache[storageKey]?.markStale()
        try await storage.markStale(storageKey: storageKey)
        await broadcastCurrent(storageKey: storageKey)
    }

    /// Remove a specific key from cache entirely
    func remove(identity: QueryIdentity) async throws {
        try await remove(storageKey: identity.storageKey)
    }

    func remove(storageKey: String) async throws {
        memoryCache.removeValue(forKey: storageKey)
        try await storage.remove(storageKey: storageKey)
        broadcast(storageKey: storageKey, record: nil)
    }

    /// Clear all cache entries
    func clear() async throws {
        memoryCache.removeAll()
        try await storage.clear()
        for key in Array(subscribers.keys) {
            broadcast(storageKey: key, record: nil)
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Remove expired entries from the cache
    func collectGarbage() async throws -> Int {
        // Clear expired from memory cache
        let now = clock.now()
        memoryCache = memoryCache.filter { !$0.value.isExpired(at: now) }

        // Delete expired from the persistent store, then notify observers of
        // each evicted key (matches the prior ValueObservation behavior).
        let deletedKeys = try await storage.deleteExpired(now: now)
        for key in deletedKeys {
            broadcast(storageKey: key, record: nil)
        }
        return deletedKeys.count
    }
    
    // MARK: - Observation

    /// Observe changes to a specific cache key.
    ///
    /// Backed by an in-memory broadcaster (no database observation). The stream:
    /// - emits the **current record** immediately on subscribe (initial value),
    ///   matching the prior `ValueObservation` behavior;
    /// - thereafter emits on every write to `key`, **de-duplicated per subscriber**
    ///   by `(payload hash, isInvalidated)` so timestamp-only changes do not emit
    ///   (this preserves the `staleTime == .zero` no-loop guarantee);
    /// - emits `nil` when the key is removed or garbage-collected;
    /// - is cleaned up automatically when the consumer cancels (`onTermination`).
    func observe(identity: QueryIdentity) async -> AsyncStream<CacheRecord?> {
        await observe(storageKey: identity.storageKey)
    }

    func observe(storageKey: String) async -> AsyncStream<CacheRecord?> {
        let (stream, continuation) = AsyncStream<CacheRecord?>.makeStream()
        let id = UUID()

        // Read the current value for the initial emission. The remainder of this
        // method runs without suspension, so registration + initial yield are
        // atomic with respect to other actor work.
        let initial = try? await storage.readIgnoringExpiry(storageKey: storageKey)
        let signature = initial.map {
            BroadcastSignature(hash: $0.queryHash, isInvalidated: $0.isInvalidated)
        }

        subscribers[storageKey, default: [:]][id] = Subscriber(
            continuation: continuation,
            lastSignature: signature
        )

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id, forKey: storageKey) }
        }

        continuation.yield(initial)
        return stream
    }

    /// Broadcast a post-write record to all subscribers of `key`, de-duplicating
    /// per subscriber by `(hash, isInvalidated)`.
    private func broadcast(storageKey: String, record: CacheRecord?) {
        guard var subs = subscribers[storageKey], !subs.isEmpty else { return }
        let signature = record.map {
            BroadcastSignature(hash: $0.queryHash, isInvalidated: $0.isInvalidated)
        }
        for (id, sub) in subs where sub.lastSignature != signature {
            subs[id]?.lastSignature = signature
            sub.continuation.yield(record)
        }
        subscribers[storageKey] = subs
    }

    /// Broadcast the current persisted record for `key` (used after invalidation,
    /// where the caller doesn't already hold the updated record).
    private func broadcastCurrent(storageKey: String) async {
        guard subscribers[storageKey]?.isEmpty == false else { return }
        let record = try? await storage.readIgnoringExpiry(storageKey: storageKey)
        broadcast(storageKey: storageKey, record: record)
    }

    private func removeSubscriber(id: UUID, forKey key: String) {
        subscribers[key]?.removeValue(forKey: id)
        if subscribers[key]?.isEmpty == true {
            subscribers.removeValue(forKey: key)
        }
    }
    
    // MARK: - Stats
    
    /// Get cache statistics
    func stats() async throws -> CacheStats {
        let now = clock.now()
        let counts = try await storage.statsCounts(now: now)

        return CacheStats(
            totalEntries: counts.total,
            staleEntries: counts.stale,
            expiredEntries: counts.expired,
            memoryEntries: memoryCache.count
        )
    }
}

// MARK: - Supporting Types

/// Cache statistics
public struct CacheStats: Sendable {
    public let totalEntries: Int
    public let staleEntries: Int
    public let expiredEntries: Int
    public let memoryEntries: Int
}

/// Type-erased cache entry protocol
protocol AnyCacheEntry: AnyObject {
    var tags: Set<QueryTag> { get }
    func markStale()
    func isExpired(at date: Date) -> Bool
}

/// Typed in-memory cache entry
final class CacheEntry<T: Sendable>: AnyCacheEntry {
    let data: T
    let tags: Set<QueryTag>
    let updatedAt: Date
    private let staleAt: Date
    private let expiresAt: Date
    private var _isInvalidated = false
    
    init(data: T, tags: Set<QueryTag>, updatedAt: Date, staleAt: Date, expiresAt: Date) {
        self.data = data
        self.tags = tags
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
    }
    
    func isStale(at date: Date) -> Bool {
        _isInvalidated || staleAt < date
    }
    
    func markStale() {
        _isInvalidated = true
    }
    
    func isExpired(at date: Date) -> Bool {
        expiresAt < date
    }
}

// MARK: - Data Extensions

extension Data {
    var sha256Hash: String {
        let digest = PlatformSHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
