import Foundation
import GRDB

// MARK: - Storage Location

/// Specifies where the cache database should be stored.
/// Internal: selected publicly via ``CacheStorageKind/GRDBLocation``.
enum CacheStorageLocation: Sendable, Equatable {
    /// Store in the Caches directory (default)
    ///
    /// Data may be cleared by the system when storage is low.
    /// Suitable for temporary cache data that can be regenerated.
    case caches

    /// Store in Application Support directory
    ///
    /// Data persists across app launches and is not cleared by the system.
    /// Suitable for persistent cache data that should survive app restarts.
    /// This is the recommended location for persistent state caching.
    case applicationSupport

    /// Store in the Documents directory
    ///
    /// Data persists and is visible to users (on macOS).
    /// Backed up by iCloud/iTunes.
    case documents

    /// Store at a custom URL
    ///
    /// Use this for complete control over the storage location.
    case custom(URL)

    /// In-memory storage (for testing)
    ///
    /// Data does not persist across app launches.
    case inMemory

    /// Resolves the storage location to a file URL
    ///
    /// - Parameter filename: The database filename (e.g., "SwiftUIQuery.sqlite")
    /// - Returns: The full URL to the database file
    public func resolveURL(filename: String = "SwiftUIQuery.sqlite") -> URL {
        switch self {
        case .caches:
            let cacheDir = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first!
            return cacheDir.appendingPathComponent(filename)

        case .applicationSupport:
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            // Create SwiftUIQuery subdirectory
            let dir = appSupport.appendingPathComponent("SwiftUIQuery")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(filename)

        case .documents:
            let docsDir = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            let dir = docsDir.appendingPathComponent("SwiftUIQuery")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(filename)

        case .custom(let url):
            // Ensure parent directory exists
            let parentDir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            return url

        case .inMemory:
            // Use a unique temporary path for in-memory-like behavior
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftUIQuery-\(UUID().uuidString).sqlite")
        }
    }

    /// Whether this location persists data across app launches
    public var isPersistent: Bool {
        switch self {
        case .caches:
            // Caches can be cleared by the system, so not truly persistent
            return false
        case .applicationSupport, .documents, .custom:
            return true
        case .inMemory:
            return false
        }
    }
}

/// Creates and configures the database migrator for SwiftUIQuery
func createMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    
    #if DEBUG
    // In debug mode, wipe and recreate if schema changes
    // This is safe for a cache database
    migrator.eraseDatabaseOnSchemaChange = true
    #endif
    
    migrator.registerMigration("v1_createQueryCache") { db in
        try db.create(table: "query_cache") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("cacheKey", .text).notNull().unique()
            t.column("queryHash", .text).notNull()
            t.column("responseData", .blob).notNull()
            t.column("responseType", .text).notNull()
            t.column("tags", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("staleAt", .datetime)
            t.column("expiresAt", .datetime)
            t.column("etag", .text)
            t.column("isInvalidated", .boolean).notNull().defaults(to: false)
        }
        
        // Index for key lookups
        try db.create(index: "idx_cache_key", on: "query_cache", columns: ["cacheKey"])
        
        // Index for tag-based queries (used by invalidation)
        try db.create(index: "idx_cache_tags", on: "query_cache", columns: ["tags"])
        
        // Index for garbage collection
        try db.create(index: "idx_cache_expires", on: "query_cache", columns: ["expiresAt"])
        
        // Index for stale queries
        try db.create(
            index: "idx_cache_stale",
            on: "query_cache",
            columns: ["staleAt", "isInvalidated"]
        )
    }

    migrator.registerMigration("v2_clearLegacyStringCacheKeys") { db in
        try db.execute(sql: "DELETE FROM query_cache")
    }
    
    return migrator
}

// MARK: - Database Setup

/// Configuration for the persistent (GRDB) cache database.
/// Internal: configured publicly via ``CacheStorageKind/GRDBLocation``.
struct CacheDatabaseConfiguration: Sendable {
    /// Path to the database file
    public let path: String

    /// The storage location used for this configuration
    public let storageLocation: CacheStorageLocation

    /// Whether to use WAL mode (recommended for concurrent access)
    public let useWAL: Bool

    /// Maximum database size in bytes (for cache pressure management)
    public let maxSize: Int64?

    /// Creates a cache configuration with a storage location
    ///
    /// - Parameters:
    ///   - storageLocation: Where to store the cache database (default: `.caches`)
    ///   - filename: The database filename (default: "SwiftUIQuery.sqlite")
    ///   - useWAL: Whether to use WAL mode (default: true)
    ///   - maxSize: Optional maximum database size in bytes
    public init(
        storageLocation: CacheStorageLocation = .caches,
        filename: String = "SwiftUIQuery.sqlite",
        useWAL: Bool = true,
        maxSize: Int64? = nil
    ) {
        self.storageLocation = storageLocation
        self.path = storageLocation.resolveURL(filename: filename).path
        self.useWAL = storageLocation == .inMemory ? false : useWAL
        self.maxSize = maxSize
    }

    /// Creates a cache configuration with a custom path
    ///
    /// - Parameters:
    ///   - path: The full path to the database file
    ///   - useWAL: Whether to use WAL mode (default: true)
    ///   - maxSize: Optional maximum database size in bytes
    public init(
        path: String,
        useWAL: Bool = true,
        maxSize: Int64? = nil
    ) {
        self.path = path
        self.storageLocation = .custom(URL(fileURLWithPath: path))
        self.useWAL = useWAL
        self.maxSize = maxSize
    }

    // MARK: - Factory Methods

    /// Ephemeral cache that does not persist across app launches
    ///
    /// Data is stored in the system caches directory and may be cleared
    /// by the system when storage is low.
    public static var ephemeral: CacheDatabaseConfiguration {
        CacheDatabaseConfiguration(storageLocation: .caches)
    }

    /// Persistent cache that survives app launches
    ///
    /// Data is stored in Application Support and is not cleared by the system.
    /// This is the recommended configuration for persistent state caching.
    public static var persistent: CacheDatabaseConfiguration {
        CacheDatabaseConfiguration(storageLocation: .applicationSupport)
    }

    /// Persistent cache in the Documents directory
    ///
    /// Data persists and is backed up by iCloud/iTunes.
    /// Visible to users on macOS in Finder.
    public static var documents: CacheDatabaseConfiguration {
        CacheDatabaseConfiguration(storageLocation: .documents)
    }

    /// In-memory-style database (for testing)
    ///
    /// Uses a temporary on-disk path to avoid WAL limitations of SQLite's
    /// pure in-memory databases on some platforms.
    public static var inMemory: CacheDatabaseConfiguration {
        CacheDatabaseConfiguration(storageLocation: .inMemory)
    }

    /// Whether this configuration uses persistent storage
    public var isPersistent: Bool {
        storageLocation.isPersistent
    }
}

/// Creates and configures a database pool for the cache
func createDatabasePool(configuration: CacheDatabaseConfiguration) throws -> DatabasePool {
    var config = Configuration()

    // Avoid WAL when explicitly disabled
    config.journalMode = configuration.useWAL ? .wal : .default

    // Performance optimizations for a cache database
    config.prepareDatabase { db in
        // Use WAL mode for better concurrent access
        if configuration.useWAL {
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        
        // Reasonable page size for typical cache entries
        let pageSizeBytes: Int64 = 4096
        try db.execute(sql: "PRAGMA page_size = \(pageSizeBytes)")

        if let maxSizeBytes = configuration.maxSize {
            // Best-effort size cap. SQLite enforces a page-count limit, so we
            // convert bytes -> pages. Note: WAL files are not accounted for.
            let maxPageCount = max(Int64(1), maxSizeBytes / pageSizeBytes)
            try db.execute(sql: "PRAGMA max_page_count = \(maxPageCount)")
        }
        
        // Keep some pages in memory
        try db.execute(sql: "PRAGMA cache_size = -2000") // 2MB
        
        // Synchronous = NORMAL is a good balance for cache
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        
        // Enable foreign keys if we add relations later
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    
    let dbPool = try DatabasePool(path: configuration.path, configuration: config)
    
    // Run migrations
    try createMigrator().migrate(dbPool)
    
    return dbPool
}
