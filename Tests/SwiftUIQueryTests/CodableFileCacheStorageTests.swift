import XCTest
@testable import SwiftUIQuery

/// Codable-backend-specific behavior: on-disk persistence and corruption recovery.
/// (The shared CRUD/invalidation/observe contract is covered by
/// `CodableBackendContractTests`.)
final class CodableFileCacheStorageTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-CodableTests-\(UUID().uuidString)")
    }

    private func makeRecord(key: String) -> CacheRecord {
        CacheRecord(
            storageKey: key,
            queryHash: "hash",
            responseData: Data(#"{"id":1,"name":"Ada"}"#.utf8),
            responseType: "TestUser",
            tags: [QueryTag("users")],
            staleAt: Date.distantFuture,
            expiresAt: Date.distantFuture
        )
    }

    private func jsonFiles(in dir: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    func testDataPersistsAcrossStorageInstances() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try CodableFileCacheStorage(directory: dir)
        try await first.upsert(makeRecord(key: "user:1"))

        // A fresh instance over the same directory sees the persisted record.
        let second = try CodableFileCacheStorage(directory: dir)
        let loaded = try await second.readIgnoringExpiry(storageKey: "user:1")
        XCTAssertEqual(loaded?.storageKey, "user:1")
        XCTAssertEqual(loaded?.responseData, makeRecord(key: "user:1").responseData)
    }

    func testOneFilePerKey() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = try CodableFileCacheStorage(directory: dir)
        try await storage.upsert(makeRecord(key: "user:1"))
        try await storage.upsert(makeRecord(key: "user:2"))
        try await storage.upsert(makeRecord(key: "user:1"))   // upsert, not a new file

        XCTAssertEqual(try jsonFiles(in: dir).count, 2)
    }

    func testCorruptFileIsTreatedAsMissAndDeleted() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = try CodableFileCacheStorage(directory: dir)
        try await storage.upsert(makeRecord(key: "user:1"))

        // Corrupt the on-disk file with non-decodable bytes.
        let files = try jsonFiles(in: dir)
        XCTAssertEqual(files.count, 1)
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: files[0])

        // The read reports a miss (so the observer would refetch)...
        let result = try await storage.readIgnoringExpiry(storageKey: "user:1")
        XCTAssertNil(result)

        // ...and the corrupt file is removed (recovery).
        XCTAssertTrue(try jsonFiles(in: dir).isEmpty)
    }

    func testCorruptedCacheRecoversViaObserverRefetch() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed a corrupt file for the query's key so the first load fails to
        // decode and must refetch (end-to-end corruption recovery, backend-neutral
        // behavior proven on the Codable backend).
        let storage = try CodableFileCacheStorage(directory: dir)
        try await storage.upsert(
            CacheRecord(
                storageKey: TestUserQuery(userId: 1).storageKey,
                queryHash: "h",
                responseData: Data([0x00]),        // not valid JSON for TestUser
                responseType: "TestUser",
                tags: [QueryTag("users")],
                staleAt: Date.distantFuture,
                expiresAt: Date.distantFuture
            )
        )

        let cache = QueryCache(storage: storage)
        let fetchCount = Synchronized(0)
        let recovered = await MainActor.run {
            QueryObserver(
                key: TestUserQuery(userId: 1),
                fetcher: {
                    fetchCount.withLock { $0 += 1 }
                    return TestUser(id: 1, name: "Recovered")
                },
                cache: cache,
                options: QueryOptions(staleTime: .hours(1))
            )
        }
        await MainActor.run { recovered.startObserving() }
        try await Task.sleep(for: .milliseconds(400))
        await MainActor.run { recovered.stopObserving() }

        XCTAssertGreaterThanOrEqual(fetchCount.withLock { $0 }, 1, "corrupt cache must trigger a refetch")
        let result = try await cache.get(storageKey: TestUserQuery(userId: 1).storageKey, as: TestUser.self)
        XCTAssertEqual(result?.data, TestUser(id: 1, name: "Recovered"))
    }
}
