import GRDB
import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

@MainActor
final class CorruptedCacheRecoveryTests: XCTestCase {
    func testCorruptedCachedPayloadTriggersRefetchAndRecovers() async throws {
        let dbPool = try createDatabasePool(configuration: .inMemory)
        let cache = QueryCache(storage: GRDBCacheStorage(pool: dbPool))

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 321)
        let corrupted = Data([0x00])
        let now = Date()

        try await dbPool.write { db in
            var record = QueryCacheEntry(
                cacheKey: key.storageKey,
                queryHash: corrupted.sha256Hash,
                responseData: corrupted,
                responseType: String(describing: TestUser.self),
                tags: key.cacheTags.jsonEncoded,
                createdAt: now,
                updatedAt: now,
                staleAt: now.addingTimeInterval(60),
                expiresAt: now.addingTimeInterval(60 * 60),
                isInvalidated: false
            )
            try record.save(db)
        }

        let fetchCalls = Counter()
        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryAttempts: 1),
            fetcher: {
                let n = await fetchCalls.incrementAndGet()
                return TestUser(id: 321, name: "Fetched \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.data?.name == "Fetched 1"
        }

        let cached = try await cache.get(storageKey: key.storageKey, as: TestUser.self)
        XCTAssertEqual(cached?.data.name, "Fetched 1")

        let calls = await fetchCalls.value()
        XCTAssertEqual(calls, 1)
    }
}

private actor Counter {
    private var count = 0

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    func value() -> Int { count }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition not met before timeout")
}

