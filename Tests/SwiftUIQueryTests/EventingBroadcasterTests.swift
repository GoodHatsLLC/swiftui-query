import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

/// Phase 2 regression tests: in-memory broadcaster eventing + fixes #5 and #7.
final class EventingBroadcasterTests: XCTestCase {

    // MARK: - Fix #7: tag invalidation returns expired-but-not-GC'd keys

    func testInvalidateReturnsExpiredMatchedKeys() async throws {
        // Drive the storage directly so the memory L1 (which never filters by
        // expiry) cannot mask the fix — this exercises the backend path that
        // previously dropped expired keys.
        let storage = try GRDBCacheStorage(configuration: .inMemory)
        let past = Date(timeIntervalSince1970: 1_000)
        try await storage.upsert(
            CacheRecord(
                cacheKey: "user:1",
                queryHash: "h",
                responseData: Data("{}".utf8),
                responseType: "TestUser",
                tagSegments: [["users"]],
                createdAt: past,
                updatedAt: past,
                staleAt: past,
                expiresAt: past,        // already expired
                isInvalidated: false
            )
        )

        let matched = try await storage.invalidate(tag: QueryTag("users"), now: Date())
        XCTAssertTrue(
            matched.contains("user:1"),
            "An expired-but-not-GC'd entry must still be returned so its observer is refetched (#7)"
        )
    }

    // MARK: - No-loop guarantee under staleTime == .zero

    @MainActor
    func testStaleTimeZeroDoesNotRunawayRefetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let count = Synchronized(0)
        let observer = QueryObserver(
            key: TestUserQuery(userId: 1),
            fetcher: {
                count.withLock { $0 += 1 }
                return TestUser(id: 1, name: "A")
            },
            cache: cache,
            options: QueryOptions(staleTime: .zero)
        )

        observer.startObserving()
        try await Task.sleep(for: .milliseconds(400))
        observer.stopObserving()

        let n = count.withLock { $0 }
        XCTAssertLessThanOrEqual(
            n, 2,
            "staleTime == .zero must not cause a runaway fetch→set→observe→fetch loop (got \(n))"
        )
        XCTAssertGreaterThanOrEqual(n, 1, "the initial fetch should still happen")
    }

    // MARK: - Fix #5: observe loop refetches on an invalidated entry

    @MainActor
    func testObserveLoopRefetchesInvalidatedEntryWithoutClient() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let count = Synchronized(0)
        // No client => the QueryClient.triggerRefetch path is absent, isolating
        // the observe-loop refetch introduced by fix #5.
        let observer = QueryObserver(
            key: TestUserQuery(userId: 1),
            fetcher: {
                count.withLock { $0 += 1 }
                return TestUser(id: 1, name: "A")
            },
            cache: cache,
            options: QueryOptions(staleTime: .seconds(60)),
            client: nil
        )

        observer.startObserving()
        try await Task.sleep(for: .milliseconds(250))
        let afterInitial = count.withLock { $0 }

        try await cache.invalidate(key: TestUserQuery(userId: 1).cacheKey)
        try await Task.sleep(for: .milliseconds(350))
        observer.stopObserving()

        let total = count.withLock { $0 }
        XCTAssertGreaterThan(
            total, afterInitial,
            "the observe loop must refetch when it sees an invalidated entry, even without a client (#5)"
        )
    }
}
