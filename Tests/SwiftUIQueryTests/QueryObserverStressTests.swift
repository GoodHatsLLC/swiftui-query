import XCTest
@testable import SwiftUIQuery

@MainActor
final class QueryObserverStressTests: XCTestCase {
    func testInvalidationAfterStoppingManyObserversDoesNotTriggerRefetches() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = Counter()

        let observers: [QueryObserver<TestUserQuery>] = (0..<50).map { id in
            client.query(
                TestUserQuery(userId: id),
                options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryAttempts: 1),
                fetcher: {
                    let n = await counter.incrementAndGet()
                    return TestUser(id: id, name: "Fetch \(n)")
                }
            )
        }

        for observer in observers {
            observer.startObserving()
        }

        try await eventually(timeout: 2.0) {
            let count = await counter.value()
            return count == 50
        }

        for observer in observers {
            observer.stopObserving()
        }

        let before = await counter.value()
        try await client.invalidate(tag: QueryTag("users"))
        try? await Task.sleep(for: .milliseconds(250))
        let after = await counter.value()

        XCTAssertEqual(before, after)
    }

    func testStartThenImmediateStopCancelsInitialFetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = Counter()

        let key = TestUserQuery(userId: 9_999)
        let observer = client.query(
            key,
            options: .init(staleTime: .hours(1), cacheTime: .hours(1), retryAttempts: 1),
            fetcher: {
                try await Task.sleep(for: .seconds(1))
                let n = await counter.incrementAndGet()
                return TestUser(id: 9_999, name: "Fetch \(n)")
            }
        )

        observer.startObserving()
        observer.stopObserving()

        try? await Task.sleep(for: .milliseconds(250))
        let count = await counter.value()
        XCTAssertEqual(count, 0)
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
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition not met before timeout")
}

