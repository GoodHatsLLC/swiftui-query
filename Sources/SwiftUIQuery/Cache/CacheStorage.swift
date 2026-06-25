import Foundation

/// Persistence backend for ``QueryCache``.
///
/// A `CacheStorage` is responsible for **persistence only** — durable read/write
/// of ``CacheRecord`` values and tag-based queries. It performs **no eventing**:
/// change broadcasting is owned by ``QueryCache`` (the in-memory broadcaster),
/// identical across all backends.
///
/// Three backends conform to this protocol: a GRDB/SQLite backend
/// (``GRDBCacheStorage``), an in-memory backend, and a one-file-per-key Codable
/// backend. `QueryCache` is an `actor`, so calls into the storage are serialized
/// within the process; backends need no additional internal locking unless they
/// hold their own mutable state (the in-memory backend is an `actor` for that
/// reason).
///
/// `now` is passed in for expiry filtering rather than read from a clock inside
/// the backend, so the injected ``QueryClock`` continues to drive staleness and
/// expiration uniformly (and deterministically in tests).
///
/// Backends are selected via ``CacheStorageKind``. This protocol is public so
/// additional backends (e.g. the GRDB backend in the `SwiftUIQueryGRDB` module,
/// or a custom one) can conform and be supplied via `CacheStorageKind.custom`.
public protocol CacheStorage: Sendable {
    /// Fetch a non-expired record. Returns `nil` if absent or expired at `now`.
    func read(key: String, now: Date) async throws -> CacheRecord?

    /// Fetch a record regardless of expiry (stale-while-revalidate fallback).
    func readIgnoringExpiry(key: String) async throws -> CacheRecord?

    /// Whether a non-expired record exists for `key` at `now`.
    func exists(key: String, now: Date) async throws -> Bool

    /// Insert or replace a record by `cacheKey`. Implementations preserve the
    /// original `createdAt` when overwriting an existing record.
    func upsert(_ record: CacheRecord) async throws

    /// Mark every record whose tags match `tag` as invalidated.
    ///
    /// - Returns: the cache keys of every matched record, **including expired
    ///   ones** (fix #7) — an observer displaying expired-but-not-GC'd data must
    ///   still be refetched. The caller uses these to broadcast + drive refetch.
    @discardableResult
    func invalidate(tag: QueryTag, now: Date) async throws -> [String]

    /// Mark a single record invalidated. No-op if the key is absent.
    func markStale(key: String) async throws

    /// Remove a single record.
    func remove(key: String) async throws

    /// Remove all records.
    func clear() async throws

    /// Delete expired records (garbage collection).
    /// - Returns: the cache keys that were deleted (so the caller can broadcast
    ///   removal to live observers, matching the prior `ValueObservation` behavior).
    @discardableResult
    func deleteExpired(now: Date) async throws -> [String]

    /// Aggregate counts for statistics.
    func statsCounts(now: Date) async throws -> CacheStorageCounts
}

/// Aggregate persistence counts surfaced through ``CacheStats``.
public struct CacheStorageCounts: Sendable {
    public let total: Int
    public let stale: Int
    public let expired: Int

    public init(total: Int, stale: Int, expired: Int) {
        self.total = total
        self.stale = stale
        self.expired = expired
    }
}
