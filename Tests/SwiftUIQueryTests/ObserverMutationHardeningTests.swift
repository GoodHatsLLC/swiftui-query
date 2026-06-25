import XCTest
@testable import SwiftUIQuery

/// Phase 8 hardening regressions: #14, #16, #12.
@MainActor
final class ObserverMutationHardeningTests: XCTestCase {

    // MARK: - #14: missing client is validated up-front

    func testMutateValidatesMissingClientBeforeRunning() async throws {
        let ran = Synchronized(false)
        let mutation = MutationState<Int, Int>(
            mutationFn: { input in
                ran.withLock { $0 = true }
                return input + 1
            },
            invalidateTags: [QueryTag("users")]   // requires a client, but none provided
        )

        do {
            _ = try await mutation.mutate(1)
            XCTFail("expected missingQueryClient")
        } catch MutationStateError.missingQueryClient {
            // expected
        }

        XCTAssertFalse(ran.withLock { $0 }, "mutationFn must not run when the client is missing")
        XCTAssertEqual(mutation.status, .idle, "a config error must not corrupt status to .success/.error")
        XCTAssertNil(mutation.data)
    }

    // MARK: - #16: reset is not clobbered by a superseded mutation's late completion

    func testResetDuringInFlightMutationSurvivesLateCompletion() async throws {
        let mutation = MutationState<Int, Int>(
            mutationFn: { input in
                try await Task.sleep(for: .milliseconds(300))
                return input + 1
            }
        )

        let task = Task { try await mutation.mutate(1) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(mutation.status, .pending)

        mutation.reset()
        XCTAssertEqual(mutation.status, .idle)

        _ = try? await task.value   // let the superseded mutation complete

        XCTAssertEqual(mutation.status, .idle, "reset state must survive the late completion")
        XCTAssertNil(mutation.data, "a superseded mutation must not restore data after reset")
    }

    // MARK: - #12: cancelled initial fetch doesn't get stuck in .pending

    func testCancelledInitialFetchDoesNotStickPending() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let observer = QueryObserver(
            key: TestUserQuery(userId: 1),
            fetcher: {
                try await Task.sleep(for: .seconds(10))   // hang until cancelled
                return TestUser(id: 1, name: "x")
            },
            cache: cache,
            options: QueryOptions(staleTime: .seconds(60))
        )

        observer.startObserving()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(observer.state.isPending, "initial fetch should be pending")

        observer.stopObserving()   // cancels the in-flight initial fetch
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertFalse(observer.state.isPending, "a cancelled initial fetch must not stay stuck .pending")
        XCTAssertEqual(observer.state.status, .idle)
    }
}
