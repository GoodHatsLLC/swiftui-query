import XCTest
@testable import SwiftUIQuery

final class QueryTagTests: XCTestCase {
    
    func testTagMatching() {
        let users = QueryTag("users")
        let user123 = QueryTag("users", "123")
        let user123Posts = QueryTag("users", "123", "posts")
        let posts = QueryTag("posts")
        
        // Parent matches children
        XCTAssertTrue(users.matches(user123))
        XCTAssertTrue(users.matches(user123Posts))
        XCTAssertTrue(user123.matches(user123Posts))
        
        // Self matches
        XCTAssertTrue(users.matches(users))
        XCTAssertTrue(user123.matches(user123))
        
        // Child doesn't match parent
        XCTAssertFalse(user123.matches(users))
        XCTAssertFalse(user123Posts.matches(user123))
        
        // Unrelated tags don't match
        XCTAssertFalse(users.matches(posts))
        XCTAssertFalse(posts.matches(users))
    }
    
    func testTagJsonEncoding() {
        let tag = QueryTag("users", "123", "posts")
        let json = tag.jsonEncoded
        
        XCTAssertTrue(json.contains("users"))
        XCTAssertTrue(json.contains("123"))
        XCTAssertTrue(json.contains("posts"))
    }
    
    func testTagDescription() {
        let tag = QueryTag("users", "123", "posts")
        XCTAssertEqual(tag.description, "users.123.posts")
    }

    func testTagSetJsonEncodingPreservesHierarchy() throws {
        let tags: Set<QueryTag> = [
            QueryTag("users"),
            QueryTag("users", "123"),
            QueryTag("users", "123", "posts")
        ]

        let json = tags.jsonEncoded
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([[String]].self, from: data)

        XCTAssertEqual(decoded, [
            ["users"],
            ["users", "123"],
            ["users", "123", "posts"]
        ])
    }

    func testTagSetJsonEncodingIsDeterministic() {
        let tags: Set<QueryTag> = [
            QueryTag("posts"),
            QueryTag("users"),
            QueryTag("users", "2")
        ]

        let baseline = tags.jsonEncoded
        for _ in 0..<20 {
            XCTAssertEqual(tags.jsonEncoded, baseline)
        }
    }
    
    func testTagFactories() {
        // Test creating tags with multiple segments
        let user = QueryTag("users", "123")
        XCTAssertEqual(user.segments, ["users", "123"])

        let userPosts = QueryTag("users", "456", "posts")
        XCTAssertEqual(userPosts.segments, ["users", "456", "posts"])
    }
}

final class QueryStateTests: XCTestCase {
    
    func testInitialState() async {
        await MainActor.run {
            let state = QueryState<String>()

            XCTAssertNil(state.data)
            XCTAssertNil(state.error)
            XCTAssertEqual(state.status, .idle)
            XCTAssertEqual(state.fetchStatus, .idle)
            XCTAssertFalse(state.isPending)
            XCTAssertFalse(state.isLoading)
            XCTAssertFalse(state.isSuccess)
            XCTAssertFalse(state.isError)
        }
    }

    func testSetData() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setData("Hello")

            XCTAssertEqual(state.data, "Hello")
            XCTAssertEqual(state.status, .success)
            XCTAssertTrue(state.isSuccess)
            XCTAssertNotNil(state.dataUpdatedAt)
        }
    }

    func testSetError() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setError(TestError.test)

            XCTAssertNotNil(state.error)
            XCTAssertEqual(state.status, .error)
            XCTAssertTrue(state.isError)
            XCTAssertEqual(state.failureCount, 1)
        }
    }

    func testSetFetching() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setFetching(true)

            XCTAssertEqual(state.fetchStatus, .fetching)
            XCTAssertEqual(state.status, .pending)
            XCTAssertTrue(state.isPending)
            XCTAssertTrue(state.isLoading)
        }
    }

    func testIsRefetching() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setData("Hello")
            state.setFetching(true)

            XCTAssertTrue(state.isRefetching)
            XCTAssertTrue(state.isSuccess)  // Still success because we have data
        }
    }

    func testReset() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setData("Hello")
            state.reset()

            XCTAssertNil(state.data)
            XCTAssertEqual(state.status, .idle)
        }
    }

    func testBackgroundErrorTracking() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setData("Existing")

            state.setBackgroundError(TestError.test)

            XCTAssertEqual(state.status, .success)
            XCTAssertNotNil(state.backgroundError)
            XCTAssertTrue(state.hasBackgroundError)
            XCTAssertEqual(state.failureCount, 1)
            XCTAssertNotNil(state.backgroundErrorUpdatedAt)
        }
    }

    func testBackgroundErrorClearsOnSuccess() async {
        await MainActor.run {
            let state = QueryState<String>()
            state.setData("Existing")
            state.setBackgroundError(TestError.test)

            state.setData("Updated")

            XCTAssertFalse(state.hasBackgroundError)
            XCTAssertNil(state.backgroundError)
            XCTAssertNil(state.backgroundErrorUpdatedAt)
        }
    }
}

final class QueryOptionsTests: XCTestCase {
    
    func testDefaultOptions() {
        let options = QueryOptions.default

        XCTAssertEqual(options.staleTime, .seconds(30))
        XCTAssertEqual(options.cacheTime, .days(7))
        XCTAssertEqual(options.retryAttempts, 3)
    }
    
    func testCustomOptions() {
        let options = QueryOptions(
            staleTime: .minutes(10),
            cacheTime: .hours(1),
            retryAttempts: 5
        )
        
        XCTAssertEqual(options.staleTime, .minutes(10))
        XCTAssertEqual(options.cacheTime, .hours(1))
        XCTAssertEqual(options.retryAttempts, 5)
    }
}

final class DurationExtensionTests: XCTestCase {
    
    func testMinutes() {
        let duration = Duration.minutes(5)
        XCTAssertEqual(duration.timeInterval, 300)
    }
    
    func testHours() {
        let duration = Duration.hours(2)
        XCTAssertEqual(duration.timeInterval, 7200)
    }
    
    func testDays() {
        let duration = Duration.days(1)
        XCTAssertEqual(duration.timeInterval, 86400)
    }
}

// MARK: - Test Helpers

enum TestError: Error {
    case test
}

struct TestUser: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct TestUserQuery: QueryKey {
    typealias Response = TestUser
    let userId: Int

    var identity: QueryIdentity { QueryIdentity("users", userId) }
    var invalidationTags: Set<QueryTag> { [QueryTag("users")] }
}
