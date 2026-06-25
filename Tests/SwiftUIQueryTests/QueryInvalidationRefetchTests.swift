import XCTest
@testable import SwiftUIQuery

@MainActor
final class QueryInvalidationRefetchTests: XCTestCase {
    func testInvalidateTagTriggersAtMostOneRefetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let counter = Counter()
        let key = TestUserQuery(userId: 123)

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counter.incrementAndGet()
                if n >= 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return TestUser(id: 123, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        await client.invalidate(tag: QueryTag("users"))

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }

        try? await Task.sleep(for: .milliseconds(400))
        let count = await counter.value()
        XCTAssertEqual(count, 2)
    }

    func testInvalidateKeyTriggersAtMostOneRefetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let counter = Counter()
        let key = TestUserQuery(userId: 456)

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counter.incrementAndGet()
                if n >= 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return TestUser(id: 456, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        await client.invalidate(key: key)

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }

        try? await Task.sleep(for: .milliseconds(400))
        let count = await counter.value()
        XCTAssertEqual(count, 2)
    }

    func testInvalidateParentTagRefetchesAllActiveChildQueriesOnce() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key1 = TestUserQuery(userId: 1)
        let key2 = TestUserQuery(userId: 2)
        let counter1 = Counter()
        let counter2 = Counter()

        let observer1 = client.query(
            key1,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counter1.incrementAndGet()
                if n >= 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return TestUser(id: 1, name: "User1 \(n)")
            }
        )

        let observer2 = client.query(
            key2,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counter2.incrementAndGet()
                if n >= 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return TestUser(id: 2, name: "User2 \(n)")
            }
        )

        observer1.startObserving()
        observer2.startObserving()

        try await eventually(timeout: 2.0) {
            let cached1 = try? await cache.get(key: key1.cacheKey, as: TestUser.self)
            let cached2 = try? await cache.get(key: key2.cacheKey, as: TestUser.self)
            return cached1?.data.name == "User1 1" && cached2?.data.name == "User2 1"
        }

        await client.invalidate(tag: QueryTag("users"))

        try await eventually(timeout: 3.0) {
            let cached1 = try? await cache.get(key: key1.cacheKey, as: TestUser.self)
            let cached2 = try? await cache.get(key: key2.cacheKey, as: TestUser.self)
            return cached1?.data.name == "User1 2" && cached2?.data.name == "User2 2"
        }

        try? await Task.sleep(for: .milliseconds(400))
        let count1 = await counter1.value()
        let count2 = await counter2.value()
        XCTAssertEqual(count1, 2)
        XCTAssertEqual(count2, 2)
    }

    func testInvalidateKeyRefetchesAllObserversForSameKey() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 777)
        let counterA = Counter()
        let counterB = Counter()

        let observerA = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counterA.incrementAndGet()
                return TestUser(id: 777, name: "A \(n)")
            }
        )

        let observerB = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counterB.incrementAndGet()
                return TestUser(id: 777, name: "B \(n)")
            }
        )

        observerA.startObserving()
        observerB.startObserving()

        try await eventually(timeout: 2.0) {
            let a = await counterA.value()
            let b = await counterB.value()
            return a == 1 && b == 1
        }

        await client.invalidate(key: key)

        let a = await counterA.value()
        let b = await counterB.value()
        XCTAssertEqual(a, 2)
        XCTAssertEqual(b, 2)
    }

    func testInvalidateWaitsForTriggeredRefetchToFinish() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )

        let key = TestUserQuery(userId: 888)
        let counter = Counter()

        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryCount: 1),
            fetcher: {
                let n = await counter.incrementAndGet()
                if n == 2 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                return TestUser(id: 888, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 2.0) {
            await counter.value() == 1
        }

        let startedAt = Date()
        await client.invalidate(key: key)
        let elapsed = Date().timeIntervalSince(startedAt)

        let count = await counter.value()
        XCTAssertEqual(count, 2)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
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
