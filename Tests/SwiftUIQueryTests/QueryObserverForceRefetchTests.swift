import XCTest
@testable import SwiftUIQuery

/// Phase 7 regression tests: `fetch(force:)` honors `force` (#2) without breaking
/// de-duplication of concurrent manual refetches.
@MainActor
final class QueryObserverForceRefetchTests: XCTestCase {

    /// An invalidation-driven forced refetch must supersede an in-flight fetch
    /// that predates the invalidation, so it can't serve pre-invalidation data.
    func testInvalidationRefetchSupersedesStaleInFlightFetch() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let calls = Synchronized(0)

        let observer = QueryObserver(
            key: TestUserQuery(userId: 1),
            fetcher: {
                let n = calls.withLock { $0 += 1; return $0 }
                if n == 1 {
                    // Slow first fetch — still in flight when invalidation arrives.
                    try await Task.sleep(for: .milliseconds(400))
                    return TestUser(id: 1, name: "stale")
                }
                return TestUser(id: 1, name: "fresh")
            },
            cache: cache,
            options: QueryOptions(staleTime: .seconds(60), retryCount: 1)
        )

        observer.startObserving()
        try await Task.sleep(for: .milliseconds(80))   // let the first fetch start

        // Invalidation-driven forced refetch supersedes the in-flight #1.
        await observer.triggerRefetch()

        try await Task.sleep(for: .milliseconds(150))
        observer.stopObserving()

        XCTAssertEqual(observer.data?.name, "fresh", "forced refetch must win over the superseded stale fetch")
        XCTAssertNil(observer.error, "the superseded fetch's cancellation must not surface as an error")
        XCTAssertGreaterThanOrEqual(calls.withLock { $0 }, 2)
    }

    /// Two concurrent *manual* refetches (no invalidation between them) share one
    /// in-flight request — force must not turn them into two network calls.
    func testConcurrentManualRefetchesStillDedup() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let calls = Synchronized(0)

        let observer = QueryObserver(
            key: TestUserQuery(userId: 1),
            fetcher: {
                calls.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(150))
                return TestUser(id: 1, name: "v")
            },
            cache: cache,
            options: QueryOptions(staleTime: .seconds(60), retryCount: 1)
        )

        // Two forced refetches issued together must collapse onto one fetch.
        async let a = observer.refetch()
        async let b = observer.refetch()
        _ = await (a, b)

        XCTAssertEqual(calls.withLock { $0 }, 1, "concurrent manual refetches must share one request")
    }
}
