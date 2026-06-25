import Foundation

/// A backend-agnostic, pure-data cache record.
///
/// `CacheRecord` is the currency exchanged between ``QueryCache`` and any
/// ``CacheStorage`` backend, and (from Phase 2 onward) the payload delivered by
/// cache-change observation. It carries no persistence-framework conformances —
/// the GRDB backend maps it to/from its internal record type, while the
/// in-memory and Codable backends store it directly.
///
/// It deliberately omits GRDB's autoincrement `id` (a storage implementation
/// detail nothing outside the database reads).
public struct CacheRecord: Sendable, Equatable, Codable {
    /// Unique cache key (e.g. `"user:123"`).
    public var cacheKey: String

    /// SHA-256 hash of `responseData`. Drives observation de-duplication.
    public var queryHash: String

    /// JSON-encoded response payload.
    public var responseData: Data

    /// Type name of the cached value (debugging aid).
    public var responseType: String

    /// Decoded tag hierarchy. Each inner array is one tag's path segments,
    /// e.g. `[["users"], ["users", "123"]]`.
    public var tagSegments: [[String]]

    /// When the entry was first created.
    public var createdAt: Date

    /// When the entry was last written.
    public var updatedAt: Date

    /// When the data becomes stale (triggers background refetch). `nil` = never.
    public var staleAt: Date?

    /// When the entry should be garbage collected. `nil` = never.
    public var expiresAt: Date?

    /// HTTP ETag for conditional requests.
    public var etag: String?

    /// Whether the entry has been explicitly invalidated.
    public var isInvalidated: Bool

    public init(
        cacheKey: String,
        queryHash: String,
        responseData: Data,
        responseType: String,
        tagSegments: [[String]],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        staleAt: Date? = nil,
        expiresAt: Date? = nil,
        etag: String? = nil,
        isInvalidated: Bool = false
    ) {
        self.cacheKey = cacheKey
        self.queryHash = queryHash
        self.responseData = responseData
        self.responseType = responseType
        self.tagSegments = tagSegments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
        self.etag = etag
        self.isInvalidated = isInvalidated
    }

    /// Whether the cached data is stale right now (uses the system clock).
    public var isStale: Bool { isStale(at: Date()) }

    /// Whether the cached data is stale at the given instant.
    ///
    /// Mirrors the previous `QueryCacheEntry.isStale(at:)` semantics verbatim.
    public func isStale(at date: Date) -> Bool {
        isInvalidated || (staleAt.map { $0 < date } ?? false)
    }

    /// Whether the entry should be garbage collected at the given instant.
    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 < date } ?? false
    }

    /// Decode the stored response payload to a concrete type.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: responseData)
    }
}
