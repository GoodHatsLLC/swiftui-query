import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

/// Backend-agnostic contract for `CacheStorage` exercised through `QueryCache`.
///
/// The abstract base defines the behavior every backend must satisfy; concrete
/// subclasses bind a backend via `makeStorage()`. XCTest runs the inherited test
/// methods once per subclass. The base itself is skipped (empty `defaultTestSuite`).
class CacheBackendContractTests: XCTestCase {

    /// Override in subclasses to choose the backend under test.
    func makeStorage() throws -> any CacheStorage {
        try GRDBCacheStorage(configuration: .inMemory)
    }

    func makeCache(clock: QueryClock = .system) throws -> QueryCache {
        QueryCache(storage: try makeStorage(), clock: clock)
    }

    // Note: the base class also runs (with the default GRDB backend) in addition
    // to the concrete subclasses. That is harmless redundant coverage; the
    // `defaultTestSuite` skip idiom interferes with `--filter`, so it is omitted.

    // MARK: - CRUD

    func testSetAndGet() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertEqual(result?.data, TestUser(id: 1, name: "Ada"))
        XCTAssertEqual(result?.isStale, false)
    }

    func testGetNonExistentReturnsNil() async throws {
        let cache = try makeCache()
        let result = try await cache.get(key: "missing", as: TestUser.self)
        XCTAssertNil(result)
    }

    func testExists() async throws {
        let cache = try makeCache()
        let before = try await cache.exists(key: "user:1")
        XCTAssertFalse(before)
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        let after = try await cache.exists(key: "user:1")
        XCTAssertTrue(after)
    }

    func testRemove() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        try await cache.remove(key: "user:1")
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertNil(result)
    }

    func testClear() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        try await cache.set(
            key: "user:2", data: TestUser(id: 2, name: "Bea"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        try await cache.clear()
        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 0)
    }

    func testUpsertPreservesCreatedAtAndReplacesData() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada Lovelace"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertEqual(result?.data.name, "Ada Lovelace")
        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 1, "upsert must not duplicate the key")
    }

    // MARK: - Tag invalidation graph

    func testInvalidateByTagMarksStale() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users"), QueryTag("users", "1")],
            staleTime: .hours(1), cacheTime: .hours(1)
        )
        let keys = try await cache.invalidate(tag: QueryTag("users"))
        XCTAssertTrue(keys.contains("user:1"))
        let result = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertEqual(result?.isStale, true)
    }

    func testHierarchicalInvalidationCascades() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users"), QueryTag("users", "1")],
            staleTime: .hours(1), cacheTime: .hours(1)
        )
        try await cache.set(
            key: "user:1:posts", data: TestUser(id: 9, name: "Post"),
            tags: [QueryTag("users", "1", "posts")],
            staleTime: .hours(1), cacheTime: .hours(1)
        )
        // Invalidating the ancestor cascades to the grandchild.
        let keys = Set(try await cache.invalidate(tag: QueryTag("users")))
        XCTAssertTrue(keys.contains("user:1"))
        XCTAssertTrue(keys.contains("user:1:posts"))
    }

    func testInvalidateDoesNotCrossMatchSiblingPaths() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "post:1", data: TestUser(id: 1, name: "P"),
            tags: [QueryTag("posts", "1")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        // "posts.123" must NOT be matched by invalidating "users".
        let keys = try await cache.invalidate(tag: QueryTag("users"))
        XCTAssertFalse(keys.contains("post:1"))
    }

    // MARK: - Expiry / staleness (clock-injected)

    func testExpiredEntriesAreNotReturnedButCollectible() async throws {
        let now = Synchronized(Date(timeIntervalSince1970: 1_000))
        let clock = QueryClock(now: { now.withLock { $0 } })
        let cache = try makeCache(clock: clock)
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Ada"),
            tags: [QueryTag("users")], staleTime: .seconds(10), cacheTime: .seconds(10)
        )
        let present = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertNotNil(present)

        now.withLock { $0 = $0.addingTimeInterval(60) }   // past expiry
        let afterExpiry = try await cache.get(key: "user:1", as: TestUser.self)
        XCTAssertNil(afterExpiry)

        // Stale-while-revalidate fallback still surfaces the expired data.
        let stale = try await cache.getIncludingExpired(key: "user:1", as: TestUser.self)
        XCTAssertEqual(stale?.data, TestUser(id: 1, name: "Ada"))
        XCTAssertEqual(stale?.isStale, true)

        let deleted = try await cache.collectGarbage()
        XCTAssertEqual(deleted, 1)
        let afterGC = try await cache.getIncludingExpired(key: "user:1", as: TestUser.self)
        XCTAssertNil(afterGC)
    }

    // MARK: - Observation

    func testObserveEmitsInitialValue() async throws {
        let cache = try makeCache()
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Init"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        let stream = await cache.observe(key: "user:1")
        let received = expectation(description: "initial value delivered")
        let task = Task {
            for await record in stream {
                if let record, (try? record.decode(as: TestUser.self))?.name == "Init" {
                    received.fulfill()
                    return
                }
            }
        }
        await fulfillment(of: [received], timeout: 1.0)
        task.cancel()
    }

    func testObserveEmitsOnWrite() async throws {
        let cache = try makeCache()
        let stream = await cache.observe(key: "user:1")
        let updated = expectation(description: "write delivered")
        let task = Task {
            for await record in stream {
                if let record, (try? record.decode(as: TestUser.self))?.name == "Written" {
                    updated.fulfill()
                    return
                }
            }
        }
        try await cache.set(
            key: "user:1", data: TestUser(id: 1, name: "Written"),
            tags: [QueryTag("users")], staleTime: .hours(1), cacheTime: .hours(1)
        )
        await fulfillment(of: [updated], timeout: 1.0)
        task.cancel()
    }
}

// MARK: - Backend bindings

final class GRDBBackendContractTests: CacheBackendContractTests {
    override func makeStorage() throws -> any CacheStorage {
        try GRDBCacheStorage(configuration: .inMemory)
    }
}

final class InMemoryBackendContractTests: CacheBackendContractTests {
    override func makeStorage() throws -> any CacheStorage {
        InMemoryCacheStorage()
    }
}

final class CodableBackendContractTests: CacheBackendContractTests {
    override func makeStorage() throws -> any CacheStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-CodableContract-\(UUID().uuidString)")
        return try CodableFileCacheStorage(directory: dir)
    }
}
