import GRDB
import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB

@MainActor
final class CancellationBehaviorTests: XCTestCase {
    func testQueryCacheObserveCancelsPromptly() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let key = "cancel:observe"

        try await cache.set(
            key: key,
            data: TestUser(id: 1, name: "Seeded"),
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let started = expectation(description: "Received first observation")
        let finished = expectation(description: "Observation task finished after cancellation")

        let task = Task {
            defer { finished.fulfill() }
            var didStart = false
            for await entry in await cache.observe(key: key) {
                if entry != nil, !didStart {
                    didStart = true
                    started.fulfill()
                }
                // After the first value, block awaiting further values so the task
                // stays alive until it is cancelled.
                if didStart {
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        break
                    }
                }
            }
        }

        await fulfillment(of: [started], timeout: 1.0)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1.0)
    }

    func testCancellingBackgroundFetchDoesNotSetErrorOrClearCachedData() async throws {
        let configuration = CacheDatabaseConfiguration.inMemory
        let dbPool = try createDatabasePool(configuration: configuration)
        let cache = QueryCache(dbPool: dbPool)

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 987)
        let seeded = TestUser(id: 987, name: "Seeded")

        try await cache.set(
            key: key.cacheKey,
            data: seeded,
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        // Force time-based staleness without toggling invalidation.
        _ = try await dbPool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == key.cacheKey)
                .updateAll(db, QueryCacheEntry.Columns.staleAt.set(to: Date.distantPast))
        }

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                // Make this cancellable and long enough that the test can cancel.
                try await Task.sleep(for: .seconds(2))
                return TestUser(id: 987, name: "Fetched")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.isFetching
        }

        observer.stopObserving()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(observer.state.data?.name, "Seeded")
        XCTAssertNil(observer.state.error)
        XCTAssertNil(observer.state.backgroundError)
        XCTAssertTrue(observer.state.isSuccess)
        // Cancellation is tracked as a non-primary output
        XCTAssertTrue(observer.state.wasCancelled)
        XCTAssertNotNil(observer.state.cancellationError)
    }

    func testURLSessionCancellationIsNotSurfacedAsError() async throws {
        let configuration = CacheDatabaseConfiguration.inMemory
        let dbPool = try createDatabasePool(configuration: configuration)
        let cache = QueryCache(dbPool: dbPool)

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 555)

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                throw URLError(.cancelled)
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.wasCancelled
        }

        // URLError.cancelled should not become a primary error
        XCTAssertNil(observer.state.error)
        XCTAssertNil(observer.state.backgroundError)
        // It should be tracked as a cancellation
        XCTAssertTrue(observer.state.wasCancelled)
        XCTAssertNotNil(observer.state.cancellationError)
        // Status should remain idle (no data was ever set)
        XCTAssertNotEqual(observer.state.status, .error)
    }

    func testCancellationDoesNotOverwriteCachedData() async throws {
        let configuration = CacheDatabaseConfiguration.inMemory
        let dbPool = try createDatabasePool(configuration: configuration)
        let cache = QueryCache(dbPool: dbPool)

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 333)
        let seeded = TestUser(id: 333, name: "Cached")

        try await cache.set(
            key: key.cacheKey,
            data: seeded,
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                throw URLError(.cancelled)
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.data != nil
        }

        // Force a refetch that will fail with cancellation
        await observer.refetch()

        // Cached data must be preserved
        XCTAssertEqual(observer.state.data?.name, "Cached")
        XCTAssertEqual(observer.state.status, .success)
        XCTAssertNil(observer.state.error)
    }

    func testSuccessfulFetchClearsCancellationState() async throws {
        let configuration = CacheDatabaseConfiguration.inMemory
        let dbPool = try createDatabasePool(configuration: configuration)
        let cache = QueryCache(dbPool: dbPool)

        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 444)

        let shouldCancel = CancellationGate(initialValue: true)
        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                if await shouldCancel.value() {
                    throw CancellationError()
                }
                return TestUser(id: 444, name: "Fetched")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            observer.state.wasCancelled
        }
        XCTAssertTrue(observer.state.wasCancelled)

        // Now fetch successfully
        await shouldCancel.set(false)
        await observer.refetch()

        try await eventually(timeout: 2.0) {
            observer.state.data != nil
        }

        // Cancellation state should be cleared on success
        XCTAssertFalse(observer.state.wasCancelled)
        XCTAssertNil(observer.state.cancellationError)
        XCTAssertEqual(observer.state.data?.name, "Fetched")
    }
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

private actor CancellationGate {
    private var shouldCancel: Bool

    init(initialValue: Bool) {
        self.shouldCancel = initialValue
    }

    func value() -> Bool {
        shouldCancel
    }

    func set(_ shouldCancel: Bool) {
        self.shouldCancel = shouldCancel
    }
}
