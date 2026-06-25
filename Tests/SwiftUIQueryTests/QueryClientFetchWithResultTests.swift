import XCTest
@testable import SwiftUIQuery

@MainActor
final class QueryClientFetchWithResultTests: XCTestCase {
    func testFetchWithResultReturnsFreshCacheWithoutRefreshing() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 123)

        try await cache.set(
            storageKey: key.storageKey,
            data: TestUser(id: 123, name: "Cached"),
            tags: key.cacheTags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let fetchCalls = Counter()
        let result = try await client.fetchWithResult(key) {
            await fetchCalls.increment()
            return TestUser(id: 123, name: "Fetched")
        }

        XCTAssertEqual(result.data.name, "Cached")
        XCTAssertEqual(result.isFromCache, true)
        XCTAssertEqual(result.isStale, false)
        XCTAssertEqual(result.isRefreshing, false)
        let calls = await fetchCalls.value()
        XCTAssertEqual(calls, 0)
    }

    func testFetchWithResultFetchesFreshDataWhenCacheIsInvalidated() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 456)

        try await cache.set(
            storageKey: key.storageKey,
            data: TestUser(id: 456, name: "Cached"),
            tags: key.cacheTags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )
        try await cache.invalidate(storageKey: key.storageKey)

        let fetchCalls = Counter()
        let result = try await client.fetchWithResult(key) {
            let n = await fetchCalls.incrementAndGet()
            return TestUser(id: 456, name: "Fetched \(n)")
        }

        XCTAssertEqual(result.data.name, "Fetched 1")
        XCTAssertEqual(result.isFromCache, false)
        XCTAssertEqual(result.isStale, false)
        XCTAssertEqual(result.isRefreshing, false)
    }

    func testFetchWithResultFetchesFreshDataWhenCacheIsTimeStale() async throws {
        let now = Synchronized(Date(timeIntervalSince1970: 0))
        let clock = QueryClock(now: { now.withLock { $0 } })
        let cache = try QueryCache(storage: .inMemory, clock: clock)
        let client = QueryClient(cache: cache, clock: clock)
        let key = TestUserQuery(userId: 457)

        try await cache.set(
            storageKey: key.storageKey,
            data: TestUser(id: 457, name: "Cached"),
            tags: key.cacheTags,
            staleTime: .seconds(10),
            cacheTime: .hours(1)
        )

        now.withLock { $0 = $0.addingTimeInterval(11) }

        let fetchCalls = Counter()
        let result = try await client.fetchWithResult(key) {
            let n = await fetchCalls.incrementAndGet()
            return TestUser(id: 457, name: "Fetched \(n)")
        }

        XCTAssertEqual(result.data.name, "Fetched 1")
        XCTAssertEqual(result.isFromCache, false)
        XCTAssertEqual(result.isStale, false)
        XCTAssertEqual(result.isRefreshing, false)
    }

    func testPrefetchOnlyFetchesWhenMissingOrStale() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 777)

        let fetchCalls = Counter()
        try await client.prefetch(key, options: .init(staleTime: .hours(1), cacheTime: .hours(1))) {
            let n = await fetchCalls.incrementAndGet()
            return TestUser(id: 777, name: "Prefetch \(n)")
        }

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(storageKey: key.storageKey, as: TestUser.self)
            return cached?.data.name == "Prefetch 1"
        }

        // Second prefetch should no-op because the cache is fresh.
        try await client.prefetch(key, options: .init(staleTime: .hours(1), cacheTime: .hours(1))) {
            let n = await fetchCalls.incrementAndGet()
            return TestUser(id: 777, name: "Prefetch \(n)")
        }
        let calls = await fetchCalls.value()
        XCTAssertEqual(calls, 1)
    }

    func testPrefetchDoesNotRegisterActiveObserver() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 778)

        let fetchCalls = Counter()
        try await client.prefetch(key, options: .init(staleTime: .hours(1), cacheTime: .hours(1))) {
            let n = await fetchCalls.incrementAndGet()
            return TestUser(id: 778, name: "Prefetch \(n)")
        }

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(storageKey: key.storageKey, as: TestUser.self)
            return cached?.data.name == "Prefetch 1"
        }

        try await client.invalidate(key)
        try? await Task.sleep(for: .milliseconds(250))

        let calls = await fetchCalls.value()
        XCTAssertEqual(calls, 1)
    }

    func testStatsReportsCacheEntryCounts() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let key = TestUserQuery(userId: 1001)

        try await client.setQueryData(key, data: TestUser(id: 1001, name: "Stats"))

        let stats = try await client.stats()
        XCTAssertEqual(stats.totalEntries, 1)
        XCTAssertEqual(stats.staleEntries, 0)
        XCTAssertEqual(stats.expiredEntries, 0)
    }
}

private actor Counter {
    private var count = 0

    func increment() { count += 1 }

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    func value() -> Int { count }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition not met before timeout")
}
