import XCTest
@testable import SwiftUIQuery

final class QueryClockTests: XCTestCase {
    func testQueryCacheStalenessUsesInjectedClock() async throws {
        let now = Synchronized(Date(timeIntervalSince1970: 0))
        let clock = QueryClock(now: { now.withLock { $0 } })
        let cache = try QueryCache(storage: .inMemory, clock: clock)

        let key = "user:clock:stale"
        try await cache.set(
            key: key,
            data: TestUser(id: 1, name: "Cached"),
            tags: [QueryTag("users")],
            staleTime: .seconds(10),
            cacheTime: .hours(1)
        )

        let fresh = try await cache.get(key: key, as: TestUser.self)
        XCTAssertEqual(fresh?.isStale, false)

        now.withLock { $0 = $0.addingTimeInterval(11) }
        let stale = try await cache.get(key: key, as: TestUser.self)
        XCTAssertEqual(stale?.isStale, true)
    }

    func testQueryCacheExpirationUsesInjectedClock() async throws {
        let now = Synchronized(Date(timeIntervalSince1970: 0))
        let clock = QueryClock(now: { now.withLock { $0 } })
        let cache = try QueryCache(storage: .inMemory, clock: clock)

        let key = "user:clock:expires"
        try await cache.set(
            key: key,
            data: TestUser(id: 2, name: "Cached"),
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .seconds(10)
        )

        let existsBefore = try await cache.exists(key: key)
        XCTAssertEqual(existsBefore, true)

        now.withLock { $0 = $0.addingTimeInterval(11) }
        let expired = try await cache.get(key: key, as: TestUser.self)
        XCTAssertNil(expired)
        let existsAfter = try await cache.exists(key: key)
        XCTAssertEqual(existsAfter, false)
    }
}
