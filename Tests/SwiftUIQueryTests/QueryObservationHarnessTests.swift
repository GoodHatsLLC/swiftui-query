// This harness exercises the Linux-only `@Query` test wrapper. Guard the entire
// file so macOS/iOS builds (which import SwiftUI) keep using the SwiftUI
// DynamicProperty wrapper without seeing Linux-specific APIs.
#if !canImport(SwiftUI)

import XCTest
@testable import SwiftUIQuery
#if canImport(Observation)
import Observation
#endif

final class QueryObservationHarnessTests: XCTestCase {
    func testLinuxQueryWrapperPublishesChangesThroughObservation() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = await MainActor.run { QueryClient(cache: cache) }
        let counter = FetchCounter()

        let harness = await MainActor.run {
            QueryHarness(
                client: client,
                fetcher: {
                    await counter.increment()
                    return TestUser(id: 1, name: "Observed User")
                }
            )
        }

        let changeExpectation = expectation(description: "Observation callback fired")

        await MainActor.run {
            harness.observeDataChange {
                changeExpectation.fulfill()
            }

            harness.start()
        }

        await fulfillment(of: [changeExpectation], timeout: 2.0)

        let fetched = await counter.value
        XCTAssertEqual(fetched, 1)
        let observedName = await MainActor.run { harness.user.data?.name }
        XCTAssertEqual(observedName, "Observed User")
    }
}

// MARK: - Helpers

@MainActor
private final class QueryHarness {
    @Query<TestUserQuery>
    private var internalUser: QueryState<TestUser>

    var user: QueryState<TestUser> { internalUser }

    init(
        client: QueryClient,
        fetcher: @escaping @Sendable () async throws -> TestUser
    ) {
        _internalUser = Query(
            TestUserQuery(userId: 1),
            client: client,
            options: .init(staleTime: .seconds(0)),
            fetcher: fetcher
        )
    }

    func start() {
        _internalUser.start()
    }

    func observeDataChange(_ onChange: @Sendable @escaping () -> Void) {
        let observer = _internalUser.observerForTesting
        observer.track({ observer.state.data }, onChange: onChange)
    }
}

private actor FetchCounter {
    private var count = 0

    func increment() { count += 1 }
    var value: Int { count }
}

#endif
