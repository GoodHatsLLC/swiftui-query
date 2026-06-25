import Foundation
import GRDB
import SwiftUIQuery

/// GRDB/SQLite-backed ``CacheStorage``.
///
/// Owns the `DatabasePool` and performs **persistence only**; change-eventing is
/// the in-memory broadcaster owned by `QueryCache` in the core module.
struct GRDBCacheStorage: CacheStorage {
    /// The underlying pool. Not part of the public API.
    let pool: DatabasePool

    /// Build a backend from a database configuration (creates the pool + migrates).
    init(configuration: CacheDatabaseConfiguration) throws {
        self.pool = try createDatabasePool(configuration: configuration)
    }

    /// Wrap an existing pool (used by tests / direct injection).
    init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Reads

    public func read(storageKey: String, now: Date) async throws -> CacheRecord? {
        try await pool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == storageKey)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > now
                )
                .fetchOne(db)?
                .toCacheRecord()
        }
    }

    public func readIgnoringExpiry(storageKey: String) async throws -> CacheRecord? {
        try await pool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == storageKey)
                .fetchOne(db)?
                .toCacheRecord()
        }
    }

    public func exists(storageKey: String, now: Date) async throws -> Bool {
        try await pool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == storageKey)
                .filter(
                    QueryCacheEntry.Columns.expiresAt == nil ||
                    QueryCacheEntry.Columns.expiresAt > now
                )
                .fetchCount(db) > 0
        }
    }

    // MARK: - Writes

    public func upsert(_ record: CacheRecord) async throws {
        try await pool.write { db in
            var entry = QueryCacheEntry(record: record)

            // Preserve identity + original creation time on overwrite.
            if let existing = try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == record.storageKey)
                .fetchOne(db) {
                entry.id = existing.id
                entry.createdAt = existing.createdAt
            }

            try entry.save(db)
        }
    }

    @discardableResult
    public func invalidate(tag: QueryTag, now: Date) async throws -> [String] {
        try await pool.write { db in
            // Match in Swift (never in SQL), identical to the prior behavior.
            let matched = try QueryCacheEntry.fetchAll(db).filter { entry in
                entry.decodedTags.containsMatch(for: tag)
            }
            for id in matched.compactMap(\.id) {
                _ = try QueryCacheEntry
                    .filter(QueryCacheEntry.Columns.id == id)
                    .updateAll(db, QueryCacheEntry.Columns.isInvalidated.set(to: true))
            }
            // Return ALL matched keys, including expired ones (fix #7).
            return matched.map(\.cacheKey)
        }
    }

    public func markStale(storageKey: String) async throws {
        _ = try await pool.write { db in
            try QueryCacheEntry.markStale(key: storageKey, in: db)
        }
    }

    public func remove(storageKey: String) async throws {
        _ = try await pool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == storageKey)
                .deleteAll(db)
        }
    }

    public func clear() async throws {
        _ = try await pool.write { db in
            try QueryCacheEntry.deleteAll(db)
        }
    }

    @discardableResult
    public func deleteExpired(now: Date) async throws -> [String] {
        try await pool.write { db in
            let expired = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.expiresAt != nil &&
                    QueryCacheEntry.Columns.expiresAt < now
                )
                .fetchAll(db)
            let keys = expired.map(\.cacheKey)
            _ = try QueryCacheEntry.deleteExpired(now: now, in: db)
            return keys
        }
    }

    // MARK: - Stats

    public func statsCounts(now: Date) async throws -> CacheStorageCounts {
        try await pool.read { db in
            let total = try QueryCacheEntry.fetchCount(db)

            let stale = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.isInvalidated == true ||
                    (QueryCacheEntry.Columns.staleAt != nil &&
                     QueryCacheEntry.Columns.staleAt < now)
                )
                .fetchCount(db)

            let expired = try QueryCacheEntry
                .filter(
                    QueryCacheEntry.Columns.expiresAt != nil &&
                    QueryCacheEntry.Columns.expiresAt < now
                )
                .fetchCount(db)

            return CacheStorageCounts(total: total, stale: stale, expired: expired)
        }
    }
}

// MARK: - QueryCacheEntry <-> CacheRecord mapping

extension QueryCacheEntry {
    /// Build a GRDB record from a backend-agnostic ``CacheRecord``.
    init(record: CacheRecord) {
        self.init(
            id: nil,
            cacheKey: record.storageKey,
            queryHash: record.queryHash,
            responseData: record.responseData,
            responseType: record.responseType,
            tags: Self.encodeTags(record.tags),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            staleAt: record.staleAt,
            expiresAt: record.expiresAt,
            etag: record.etag,
            isInvalidated: record.isInvalidated
        )
    }

    /// Project this GRDB record to a backend-agnostic ``CacheRecord``.
    func toCacheRecord() -> CacheRecord {
        CacheRecord(
            storageKey: cacheKey,
            queryHash: queryHash,
            responseData: responseData,
            responseType: responseType,
            tags: decodedTags,
            createdAt: createdAt,
            updatedAt: updatedAt,
            staleAt: staleAt,
            expiresAt: expiresAt,
            etag: etag,
            isInvalidated: isInvalidated
        )
    }
}
