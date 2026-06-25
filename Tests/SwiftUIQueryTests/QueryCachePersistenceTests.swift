import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

@MainActor
final class QueryCachePersistenceTests: XCTestCase {
    func testPersistentCacheSurvivesNewQueryClientInstance() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-Persistence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let storage: CacheStorageKind = .grdb(.custom(path: url.path, useWAL: false))
        let key = TestUserQuery(userId: 4242)

        do {
            let client = QueryClient(storage: storage)
            await client.setQueryData(key, data: TestUser(id: 4242, name: "Persisted"))
        }

        do {
            let client = QueryClient(storage: storage)
            let loaded = await client.getQueryData(key)
            XCTAssertEqual(loaded?.name, "Persisted")
        }
    }
}

