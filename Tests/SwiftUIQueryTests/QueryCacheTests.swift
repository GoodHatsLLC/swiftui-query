import XCTest
@testable import SwiftUIQuery

final class QueryCacheTests: XCTestCase {

    var cache: QueryCache!

    // Helper tags
    private let usersTag = QueryTag("users")
    private func userTag(_ id: Int) -> QueryTag { QueryTag("users", "\(id)") }
    private func userPostsTag(_ id: Int) -> QueryTag { QueryTag("users", "\(id)", "posts") }

    override func setUp() async throws {
        // Use in-memory database for tests
        cache = try QueryCache(storage: .inMemory)
    }

    func testSetAndGet() async throws {
        let user = TestUser(id: 1, name: "Test")

        try await cache.set(
            storageKey: "user:1",
            data: user,
            tags: [usersTag, userTag(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        let result = try await cache.get(storageKey: "user:1", as: TestUser.self)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data, user)
        XCTAssertFalse(result?.isStale ?? true)
    }

    func testGetNonExistent() async throws {
        let result = try await cache.get(storageKey: "nonexistent", as: TestUser.self)
        XCTAssertNil(result)
    }

    func testExists() async throws {
        let user = TestUser(id: 1, name: "Test")

        let initialExists = try await cache.exists(storageKey: "user:1")
        XCTAssertFalse(initialExists)

        try await cache.set(
            storageKey: "user:1",
            data: user,
            tags: [usersTag],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        let finalExists = try await cache.exists(storageKey: "user:1")
        XCTAssertTrue(finalExists)
    }

    func testInvalidateByTag() async throws {
        // Set up multiple users
        for i in 1...3 {
            try await cache.set(
                storageKey: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [usersTag, userTag(i)],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }

        // Invalidate all users
        let invalidated = try await cache.invalidate(tag: usersTag)
        XCTAssertEqual(invalidated.count, 3)

        // Check they're now stale
        let result = try await cache.get(storageKey: "user:1", as: TestUser.self)
        XCTAssertTrue(result?.isStale ?? false)
    }

    func testInvalidateSpecificTag() async throws {
        // Set up users
        for i in 1...3 {
            try await cache.set(
                storageKey: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [usersTag, userTag(i)],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }

        // Invalidate only user 2
        let invalidated = try await cache.invalidate(tag: userTag(2))
        XCTAssertEqual(invalidated.count, 1)
        XCTAssertTrue(invalidated.contains("user:2"))

        // User 1 should still be fresh
        let result1 = try await cache.get(storageKey: "user:1", as: TestUser.self)
        XCTAssertFalse(result1?.isStale ?? true)

        // User 2 should be stale
        let result2 = try await cache.get(storageKey: "user:2", as: TestUser.self)
        XCTAssertTrue(result2?.isStale ?? false)
    }

    func testHierarchicalInvalidation() async throws {
        // Set up user and their posts
        try await cache.set(
            storageKey: "user:1",
            data: TestUser(id: 1, name: "User 1"),
            tags: [usersTag, userTag(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        try await cache.set(
            storageKey: "user:1:posts",
            data: ["Post 1", "Post 2"],
            tags: [userTag(1), userPostsTag(1)],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        // Invalidate user 1 - should cascade to posts
        let invalidated = try await cache.invalidate(tag: userTag(1))
        XCTAssertEqual(invalidated.count, 2)

        let userResult = try await cache.get(storageKey: "user:1", as: TestUser.self)
        XCTAssertTrue(userResult?.isStale ?? false)

        let postsResult = try await cache.get(storageKey: "user:1:posts", as: [String].self)
        XCTAssertTrue(postsResult?.isStale ?? false)
    }

    func testInvalidateDoesNotCrossMatchUnrelatedTagPaths() async throws {
        try await cache.set(
            storageKey: "mixed:entry",
            data: "Mixed",
            tags: [QueryTag("users", "123"), QueryTag("posts")],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        try await cache.set(
            storageKey: "posts:123",
            data: "Posts 123",
            tags: [QueryTag("posts", "123")],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        let invalidated = try await cache.invalidate(tag: QueryTag("posts", "123"))
        XCTAssertEqual(Set(invalidated), ["posts:123"])

        let mixed = try await cache.get(storageKey: "mixed:entry", as: String.self)
        let exact = try await cache.get(storageKey: "posts:123", as: String.self)

        XCTAssertFalse(mixed?.isStale ?? true)
        XCTAssertTrue(exact?.isStale ?? false)
    }

    func testRemove() async throws {
        let user = TestUser(id: 1, name: "Test")

        try await cache.set(
            storageKey: "user:1",
            data: user,
            tags: [usersTag],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        try await cache.remove(storageKey: "user:1")

        let result = try await cache.get(storageKey: "user:1", as: TestUser.self)
        XCTAssertNil(result)
    }

    func testClear() async throws {
        for i in 1...5 {
            try await cache.set(
                storageKey: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [usersTag],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }

        try await cache.clear()

        for i in 1...5 {
            let result = try await cache.get(storageKey: "user:\(i)", as: TestUser.self)
            XCTAssertNil(result)
        }
    }

    func testStats() async throws {
        for i in 1...3 {
            try await cache.set(
                storageKey: "user:\(i)",
                data: TestUser(id: i, name: "User \(i)"),
                tags: [usersTag],
                staleTime: .minutes(5),
                cacheTime: .hours(1)
            )
        }

        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 3)
        XCTAssertEqual(stats.staleEntries, 0)
    }

    func testDeterministicHashing() {
        let payload = Data("deterministic".utf8)
        let second = Data("deterministic".utf8)

        XCTAssertEqual(payload.sha256Hash, second.sha256Hash)
        XCTAssertEqual(payload.sha256Hash, payload.sha256Hash)
    }

    func testUpsertBehavior() async throws {
        let user1 = TestUser(id: 1, name: "Original")
        let user2 = TestUser(id: 1, name: "Updated")

        try await cache.set(
            storageKey: "user:1",
            data: user1,
            tags: [usersTag],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        try await cache.set(
            storageKey: "user:1",
            data: user2,
            tags: [usersTag],
            staleTime: .minutes(5),
            cacheTime: .hours(1)
        )

        let result = try await cache.get(storageKey: "user:1", as: TestUser.self)
        XCTAssertEqual(result?.data.name, "Updated")

        // Should still only have 1 entry
        let stats = try await cache.stats()
        XCTAssertEqual(stats.totalEntries, 1)
    }
}
