import GRDB
import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

final class DatabaseMigrationIdempotencyTests: XCTestCase {
    func testCreateDatabasePoolMigrateIsIdempotent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-MigrateTwice-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = CacheDatabaseConfiguration(path: url.path, useWAL: false)

        var firstPool: DatabasePool? = try createDatabasePool(configuration: configuration)
        try await firstPool?.write { db in
            var entry = QueryCacheEntry(
                cacheKey: "user:migrate",
                queryHash: "test-hash",
                responseData: Data("{}".utf8),
                responseType: "Test",
                tags: QueryTag("users").jsonEncoded,
                createdAt: Date(),
                updatedAt: Date(),
                staleAt: nil,
                expiresAt: Date().addingTimeInterval(60),
                isInvalidated: false
            )
            try entry.save(db)
        }
        firstPool = nil

        let secondPool = try createDatabasePool(configuration: configuration)
        let count = try await secondPool.read { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == "user:migrate")
                .fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    func testV2MigrationClearsLegacyCacheRows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-MigrateLegacy-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = CacheDatabaseConfiguration(path: url.path, useWAL: false)

        var legacyPool: DatabasePool? = try DatabasePool(path: url.path)
        try await legacyPool?.write { db in
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
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v1_createQueryCache"]
            )

            var entry = QueryCacheEntry(
                cacheKey: "user:legacy",
                queryHash: "test-hash",
                responseData: Data("{}".utf8),
                responseType: "Test",
                tags: QueryTag("users").jsonEncoded,
                createdAt: Date(),
                updatedAt: Date(),
                staleAt: nil,
                expiresAt: Date().addingTimeInterval(60),
                isInvalidated: false
            )
            try entry.save(db)
        }
        legacyPool = nil

        let migratedPool = try createDatabasePool(configuration: configuration)
        let count = try await migratedPool.read { db in
            try QueryCacheEntry.fetchCount(db)
        }
        XCTAssertEqual(count, 0)
    }
}
