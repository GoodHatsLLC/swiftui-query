import XCTest
@testable import SwiftUIQuery

final class QueryObserverLifecycleTests: XCTestCase {
    func testQueryObserverDoesNotRetainItselfAfterStartObserving() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = await MainActor.run { QueryClient(cache: cache) }

        let key = TestUserQuery(userId: 123_456)
        try await cache.set(
            storageKey: key.storageKey,
            data: TestUser(id: 123_456, name: "Seeded"),
            tags: key.cacheTags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        @MainActor
        final class WeakBox<T: AnyObject> {
            weak var value: T?
        }

        let box = await MainActor.run { WeakBox<QueryObserver<TestUserQuery>>() }

        await MainActor.run {
            let observer = client.query(
                key,
                options: .init(staleTime: .hours(1)),
                fetcher: { TestUser(id: 123_456, name: "Fetched") }
            )
            observer.startObserving()
            box.value = observer
        }

        for _ in 0..<50 {
            if (await MainActor.run { box.value }) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let value = await MainActor.run { box.value }
        XCTAssertNil(value)
    }
}
