import XCTest
@testable import SwiftUIQuery

@MainActor
final class QueryObserverAutoRefetchTests: XCTestCase {
    func testRefetchOnFocusTriggersBackgroundFetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 7)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: true,
                refetchOnReconnect: false,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 7, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        await lifecycle.emitForTesting(.didBecomeActive)

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testRefetchOnFocusDoesNotRunAfterStopObserving() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 70)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: true,
                refetchOnReconnect: false,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 70, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        observer.stopObserving()
        await lifecycle.emitForTesting(.didBecomeActive)
        try? await Task.sleep(for: .milliseconds(200))

        let cached = try await cache.get(key: key.cacheKey, as: TestUser.self)
        XCTAssertEqual(cached?.data.name, "Fetch 1")
        let count = await counter.value()
        XCTAssertEqual(count, 1)
    }

    func testRefetchOnReconnectTriggersOnUnsatisfiedToSatisfiedTransition() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 8)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: false,
                refetchOnReconnect: true,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 8, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        await connectivity.setStatusForTesting(.unsatisfied)
        await connectivity.setStatusForTesting(.satisfied)

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testRefetchOnReconnectDoesNotRunOnInitialSatisfiedStatus() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 80)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: false,
                refetchOnReconnect: true,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 80, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        try? await Task.sleep(for: .milliseconds(250))
        let count = await counter.value()
        XCTAssertEqual(count, 1)
    }

    func testRefetchOnReconnectDoesNotRunAfterStopObserving() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 81)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: false,
                refetchOnReconnect: true,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 81, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        observer.stopObserving()
        await connectivity.setStatusForTesting(.unsatisfied)
        await connectivity.setStatusForTesting(.satisfied)
        try? await Task.sleep(for: .milliseconds(250))

        let cached = try await cache.get(key: key.cacheKey, as: TestUser.self)
        XCTAssertEqual(cached?.data.name, "Fetch 1")
        let count = await counter.value()
        XCTAssertEqual(count, 1)
    }
}

private actor Counter {
    private var count = 0

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
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
