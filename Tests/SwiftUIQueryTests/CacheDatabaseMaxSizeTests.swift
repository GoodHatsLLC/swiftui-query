import GRDB
import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

final class CacheDatabaseMaxSizeTests: XCTestCase {
    func testCreateDatabasePoolAppliesMaxSizeAsMaxPageCount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-MaxSize-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let maxSizeBytes: Int64 = 4096 * 256 // 1MB
        let configuration = CacheDatabaseConfiguration(path: url.path, useWAL: false, maxSize: maxSizeBytes)
        let dbPool = try createDatabasePool(configuration: configuration)

        let (pageSize, maxPageCount) = try await dbPool.read { db in
            struct MissingPragmaRow: Error {}
            guard
                let pageSizeRow = try Row.fetchOne(db, sql: "PRAGMA page_size"),
                let maxPageCountRow = try Row.fetchOne(db, sql: "PRAGMA max_page_count")
            else {
                throw MissingPragmaRow()
            }

            let pageSize: Int64 = pageSizeRow[0]
            let maxPageCount: Int64 = maxPageCountRow[0]
            return (pageSize, maxPageCount)
        }

        XCTAssertEqual(pageSize, 4096)
        XCTAssertEqual(maxPageCount, max(Int64(1), maxSizeBytes / pageSize))
    }
}
