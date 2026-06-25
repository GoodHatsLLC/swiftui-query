import XCTest
@testable import SwiftUIQuery
@testable import SwiftUIQueryGRDB
import GRDB

final class QueryCacheObservationTests: XCTestCase {
    func testObserveDeduplicatesByHashAndStaleFlag() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let key = "user:observe"
        let data = TestUser(id: 1, name: "Same")

        try await cache.set(
            key: key,
            data: data,
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        let initialExpectation = expectation(description: "Initial observe value delivered")
        let duplicateExpectation = expectation(description: "Duplicate payload emitted")
        duplicateExpectation.isInverted = true
        let staleExpectation = expectation(description: "Stale transition emitted")
        let freshAgainExpectation = expectation(description: "Fresh transition emitted")

        let state = Synchronized(ObservationState())
        let stream = await cache.observe(key: key)

        let task = Task {
            for await entry in stream {
                guard let entry else { continue }

                let phase = state.withLock(\.phase)
                switch phase {
                case .awaitingInitial:
                    XCTAssertEqual(try entry.decode(as: TestUser.self).name, "Same")
                    XCTAssertEqual(entry.isStale, false)
                    initialExpectation.fulfill()
                    state.withLock { $0.phase = .ready }

                case .ready:
                    break

                case .duplicateWindow:
                    duplicateExpectation.fulfill()

                case .awaitingStale:
                    XCTAssertEqual(entry.isStale, true)
                    staleExpectation.fulfill()
                    state.withLock { $0.phase = .awaitingFreshAgain }

                case .awaitingFreshAgain:
                    XCTAssertEqual(entry.isStale, false)
                    freshAgainExpectation.fulfill()
                    return
                }
            }
        }
        defer { task.cancel() }

        await fulfillment(of: [initialExpectation], timeout: 1.0)

        // Updating only metadata (same payload hash, same staleness) should not emit.
        state.withLock { $0.phase = .duplicateWindow }
        try await cache.set(
            key: key,
            data: data,
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )
        await fulfillment(of: [duplicateExpectation], timeout: 0.25)
        state.withLock { $0.phase = .ready }

        // Changing staleness should emit even if payload hash is identical.
        state.withLock { $0.phase = .awaitingStale }
        try await cache.invalidate(key: key)
        await fulfillment(of: [staleExpectation], timeout: 1.0)

        // Clearing invalidation should emit again (stale -> fresh).
        try await cache.set(
            key: key,
            data: data,
            tags: [QueryTag("users")],
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )
        await fulfillment(of: [freshAgainExpectation], timeout: 1.0)
    }

    func testExpiredEntriesAreNotReturnedAndAreCollected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftUIQuery-Expiration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = CacheDatabaseConfiguration(path: url.path, useWAL: false)
        let dbPool = try createDatabasePool(configuration: configuration)

        do {
            let cache = QueryCache(dbPool: dbPool)
            try await cache.set(
                key: "user:expires",
                data: TestUser(id: 1, name: "Expired"),
                tags: [QueryTag("users")],
                staleTime: .hours(1),
                cacheTime: .hours(1)
            )
        }

        _ = try await dbPool.write { db in
            try QueryCacheEntry
                .filter(QueryCacheEntry.Columns.cacheKey == "user:expires")
                .updateAll(db, QueryCacheEntry.Columns.expiresAt.set(to: Date.distantPast))
        }

        let cache = QueryCache(dbPool: dbPool)
        let missing = try await cache.get(key: "user:expires", as: TestUser.self)
        XCTAssertNil(missing)

        let deleted = try await cache.collectGarbage()
        XCTAssertEqual(deleted, 1)

        let remaining = try await dbPool.read { db in
            try QueryCacheEntry.fetchCount(db)
        }
        XCTAssertEqual(remaining, 0)
    }
}

private struct ObservationState: Sendable {
    var phase: ObservationPhase = .awaitingInitial
}

private enum ObservationPhase: Sendable {
    case awaitingInitial
    case ready
    case duplicateWindow
    case awaitingStale
    case awaitingFreshAgain
}
