import Foundation

/// In-memory ``CacheStorage`` backed by a dictionary.
///
/// Data does not persist across process launches. Because the storage holds
/// mutable state and is `Sendable`, it is an `actor`; `QueryCache` (also an
/// actor) calls into it via `await`. Used standalone for tests/ephemeral caches
/// and as the fallback backend.
///
/// `maxEntries` is an **approximate** capacity cap by entry count (not bytes):
/// when exceeded on write, the least-recently-written entries (oldest
/// `updatedAt`) are evicted. `nil` means unbounded.
actor InMemoryCacheStorage: CacheStorage {
    private var store: [String: CacheRecord] = [:]
    private let maxEntries: Int?

    init(maxEntries: Int? = nil) {
        self.maxEntries = maxEntries
    }

    // MARK: - Reads

    public func read(key: String, now: Date) async throws -> CacheRecord? {
        guard let record = store[key] else { return nil }
        return record.isExpired(at: now) ? nil : record
    }

    public func readIgnoringExpiry(key: String) async throws -> CacheRecord? {
        store[key]
    }

    public func exists(key: String, now: Date) async throws -> Bool {
        guard let record = store[key] else { return false }
        return !record.isExpired(at: now)
    }

    // MARK: - Writes

    public func upsert(_ record: CacheRecord) async throws {
        var record = record
        if let existing = store[record.cacheKey] {
            // Preserve the original creation time on overwrite (matches GRDB).
            record.createdAt = existing.createdAt
        }
        store[record.cacheKey] = record
        enforceCapacity()
    }

    @discardableResult
    public func invalidate(tag: QueryTag, now: Date) async throws -> [String] {
        var matched: [String] = []
        for (key, record) in store
        where TagMatching.matches(tag: tag, tagSegments: record.tagSegments) {
            var updated = record
            updated.isInvalidated = true
            store[key] = updated
            matched.append(key)   // include expired entries (fix #7)
        }
        return matched
    }

    public func markStale(key: String) async throws {
        guard var record = store[key] else { return }
        record.isInvalidated = true
        store[key] = record
    }

    public func remove(key: String) async throws {
        store.removeValue(forKey: key)
    }

    public func clear() async throws {
        store.removeAll()
    }

    @discardableResult
    public func deleteExpired(now: Date) async throws -> [String] {
        let expiredKeys = store.compactMap { $0.value.isExpired(at: now) ? $0.key : nil }
        for key in expiredKeys {
            store.removeValue(forKey: key)
        }
        return expiredKeys
    }

    // MARK: - Stats

    public func statsCounts(now: Date) async throws -> CacheStorageCounts {
        CacheStorageCounts(
            total: store.count,
            stale: store.values.filter { $0.isStale(at: now) }.count,
            expired: store.values.filter { $0.isExpired(at: now) }.count
        )
    }

    // MARK: - Capacity

    private func enforceCapacity() {
        guard let maxEntries, store.count > maxEntries else { return }
        let overflow = store.count - maxEntries
        let evictKeys = store
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
            .map(\.key)
        for key in evictKeys {
            store.removeValue(forKey: key)
        }
    }
}
