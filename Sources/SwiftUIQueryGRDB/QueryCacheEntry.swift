import Foundation
import GRDB
import SwiftUIQuery

/// GRDB record for cached query responses.
/// Internal: an implementation detail of ``GRDBCacheStorage``; the public
/// record type is ``CacheRecord``.
struct QueryCacheEntry: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "query_cache"
    
    // MARK: - Properties
    
    public var id: Int64?
    
    /// Unique cache key (e.g., "user:123")
    public var cacheKey: String
    
    /// SHA256 hash of response data for integrity checks
    public var queryHash: String
    
    /// JSON-encoded response data
    public var responseData: Data
    
    /// Type name for debugging
    public var responseType: String
    
    /// JSON array of tag segments for prefix queries
    public var tags: String
    
    /// When the entry was first created
    public var createdAt: Date
    
    /// When the entry was last updated
    public var updatedAt: Date
    
    /// When the data becomes stale (triggers background refetch)
    public var staleAt: Date?
    
    /// When to garbage collect the entry
    public var expiresAt: Date?
    
    /// HTTP ETag for conditional requests
    public var etag: String?
    
    /// Whether manually invalidated
    public var isInvalidated: Bool
    
    // MARK: - Column Definitions
    
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let cacheKey = Column(CodingKeys.cacheKey)
        public static let queryHash = Column(CodingKeys.queryHash)
        public static let responseData = Column(CodingKeys.responseData)
        public static let responseType = Column(CodingKeys.responseType)
        public static let tags = Column(CodingKeys.tags)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let staleAt = Column(CodingKeys.staleAt)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let etag = Column(CodingKeys.etag)
        public static let isInvalidated = Column(CodingKeys.isInvalidated)
    }
    
    // MARK: - Lifecycle
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
    
    // MARK: - Computed Properties
    
    /// Whether the cached data is stale
    public var isStale: Bool {
        isStale(at: Date())
    }
    
    public func isStale(at date: Date) -> Bool {
        isInvalidated || (staleAt.map { $0 < date } ?? false)
    }

    /// Whether the entry should be garbage collected
    public var isExpired: Bool {
        isExpired(at: Date())
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 < date } ?? false
    }
    
    // MARK: - Initialization
    
    public init(
        id: Int64? = nil,
        cacheKey: String,
        queryHash: String,
        responseData: Data,
        responseType: String,
        tags: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        staleAt: Date? = nil,
        expiresAt: Date? = nil,
        etag: String? = nil,
        isInvalidated: Bool = false
    ) {
        self.id = id
        self.cacheKey = cacheKey
        self.queryHash = queryHash
        self.responseData = responseData
        self.responseType = responseType
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
        self.etag = etag
        self.isInvalidated = isInvalidated
    }
}

// MARK: - Tag-Based Queries

extension QueryCacheEntry {
    /// Find all entries matching a tag prefix (for hierarchical invalidation)
    ///
    /// Tags are stored as JSON array-of-arrays where each nested array represents
    /// one tag path (for example: `[["users"], ["users","123"]]`).
    ///
    /// Legacy caches may contain a flat string array. This is tolerated for
    /// backwards compatibility.
    public static func matching(tag: QueryTag, in db: Database) throws -> [QueryCacheEntry] {
        try matching(tag: tag, now: Date(), in: db)
    }

    public static func matching(tag: QueryTag, now: Date, in db: Database) throws -> [QueryCacheEntry] {
        let candidates = try QueryCacheEntry
            .filter(Columns.expiresAt == nil || Columns.expiresAt > now)
            .fetchAll(db)

        return candidates.filter { matches(tag: tag, encodedTags: $0.tags) }
    }
    
    /// Get all cache keys matching a tag prefix
    public static func keysMatching(tag: QueryTag, in db: Database) throws -> [String] {
        try keysMatching(tag: tag, now: Date(), in: db)
    }

    public static func keysMatching(tag: QueryTag, now: Date, in db: Database) throws -> [String] {
        let candidates = try QueryCacheEntry
            .filter(Columns.expiresAt == nil || Columns.expiresAt > now)
            .fetchAll(db)

        return candidates
            .filter { matches(tag: tag, encodedTags: $0.tags) }
            .map(\.cacheKey)
    }
    
    /// Mark matching entries as invalidated
    @discardableResult
    public static func invalidate(tag: QueryTag, in db: Database) throws -> Int {
        let entries = try QueryCacheEntry.fetchAll(db)
        let ids: [Int64] = entries.compactMap { entry -> Int64? in
            guard matches(tag: tag, encodedTags: entry.tags) else { return nil }
            return entry.id
        }

        guard !ids.isEmpty else { return 0 }

        var updated = 0
        for id in ids {
            updated += try QueryCacheEntry
                .filter(Columns.id == id)
                .updateAll(db, Columns.isInvalidated.set(to: true))
        }
        return updated
    }
    
    /// Mark a specific entry as stale
    @discardableResult
    public static func markStale(key: String, in db: Database) throws -> Bool {
        try QueryCacheEntry
            .filter(Columns.cacheKey == key)
            .updateAll(db, Columns.isInvalidated.set(to: true)) > 0
    }
    
    /// Delete expired entries (garbage collection)
    @discardableResult
    public static func deleteExpired(in db: Database) throws -> Int {
        try deleteExpired(now: Date(), in: db)
    }

    @discardableResult
    public static func deleteExpired(now: Date, in db: Database) throws -> Int {
        try QueryCacheEntry
            .filter(Columns.expiresAt != nil && Columns.expiresAt < now)
            .deleteAll(db)
    }

    private static func matches(tag: QueryTag, encodedTags: String) -> Bool {
        // Delegates to the shared, backend-agnostic matcher so every backend
        // uses one matching primitive.
        TagMatching.matches(
            tag: tag,
            tagSegments: TagMatching.decodeSegments(fromJSON: encodedTags)
        )
    }
}

// MARK: - Decoding Helpers

extension QueryCacheEntry {
    /// Decode the stored response data to a specific type
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: responseData)
    }
}
