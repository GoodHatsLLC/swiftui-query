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
}
