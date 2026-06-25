import XCTest
@testable import SwiftUIQuery

@MainActor
final class QueryActionsTests: XCTestCase {
    func testQueryActionsSetGetInvalidateAndRefetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        let key = TestUserQuery(userId: 42)
        let observer = client.query(
            key,
            options: .init(staleTime: .seconds(0), retryAttempts: 1),
            fetcher: {
                let next = await counter.incrementAndGet()
                return TestUser(id: 42, name: "Fetch \(next)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 15.0) {
            let cached = try? await cache.get(storageKey: key.storageKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        let actions = QueryActions(observer: observer, client: client, key: key)
        try await actions.setData(TestUser(id: 42, name: "Manual"))
        let manual = try await actions.getData()
        XCTAssertEqual(manual?.name, "Manual")

        try await actions.invalidate()
        try await eventually(timeout: 15.0) {
            let cached = try? await cache.get(storageKey: key.storageKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }
}

// MARK: - Helpers

private actor FetchCounter {
    private var count = 0

    func incrementAndGet() -> Int {
        count += 1
        return count
    }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        await MainActor.run {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition not met before timeout")
}
