import XCTest
@testable import SwiftUIQuery

final class MutationClientInjectionTests: XCTestCase {
    func testMutationInvalidatesUsingInjectedClient() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let client = await MainActor.run { QueryClient(cache: cache) }

        let key = TestUserQuery(userId: 999)
        try await cache.set(
            key: key.cacheKey,
            data: TestUser(id: 999, name: "Cached"),
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let mutation = await MainActor.run {
            MutationState<Void, Void>(
                name: "TestMutation",
                mutationFn: { },
                invalidateTags: [QueryTag("users")],
                client: client
            )
        }

        _ = try await mutation.mutate(())

        let cached = try await cache.get(key: key.cacheKey, as: TestUser.self)
        XCTAssertEqual(cached?.data.name, "Cached")
        XCTAssertEqual(cached?.isStale, true)
    }
}

