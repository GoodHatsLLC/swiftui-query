import XCTest
@testable import SwiftUIQuery
#if !os(Linux)

final class InvalidationTrackerTests: XCTestCase {

    // Helper tags
    private let usersTag = QueryTag("users")
    private let postsTag = QueryTag("posts")
    private let commentsTag = QueryTag("comments")

    // MARK: - Basic Tracking

    func testBeginEndInvalidation() async throws {
        let tracker = await makeTracker()

        var isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertFalse(isInvalidating)
        var currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)

        let token = try await beginInvalidation(tracker, tag: usersTag)
        isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertTrue(isInvalidating)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 1)

        await endInvalidation(tracker, token: token)
        isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertFalse(isInvalidating)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)
    }

    func testNestedInvalidations() async throws {
        let tracker = await makeTracker()

        let token1 = try await beginInvalidation(tracker, tag: usersTag)
        var currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 1)

        let token2 = try await beginInvalidation(tracker, tag: postsTag)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 2)

        let token3 = try await beginInvalidation(tracker, tag: commentsTag)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 3)

        await endInvalidation(tracker, token: token3)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 2)

        await endInvalidation(tracker, token: token2)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 1)

        await endInvalidation(tracker, token: token1)
        currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)
    }

    // MARK: - Cycle Detection

    func testCycleDetectionWithTags() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: false, logWarnings: false))

        let token1 = try await beginInvalidation(tracker, tag: usersTag)
        let token2 = try await beginInvalidation(tracker, tag: usersTag)

        XCTAssertTrue(token2.wasSkipped)
        let cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 1)

        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }

    func testCycleDetectionThrows() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: true, logWarnings: false))

        let token1 = try await beginInvalidation(tracker, tag: usersTag)

        await XCTAssertThrowsErrorAsync({ try await beginInvalidation(tracker, tag: usersTag) }) { error in
            guard case InvalidationTracker.TrackerError.cycleDetected(let info) = error else {
                XCTFail("Expected cycleDetected error")
                return
            }
            XCTAssertEqual(info.trigger, "tag:users")
            XCTAssertEqual(info.depth, 1)
        }

        await endInvalidation(tracker, token: token1)
    }

    func testCycleDetectionWithKeys() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: false, logWarnings: false))

        let token1 = try await MainActor.run { try tracker.beginInvalidation(key: "user:123") }
        let token2 = try await MainActor.run { try tracker.beginInvalidation(key: "user:123") }

        XCTAssertTrue(token2.wasSkipped)
        let cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 1)

        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }

    func testIndirectCycleDetection() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: false, logWarnings: false))

        let tokenA = try await beginInvalidation(tracker, tag: usersTag, source: "A")
        let tokenB = try await beginInvalidation(tracker, tag: postsTag, source: "B")
        let tokenC = try await beginInvalidation(tracker, tag: commentsTag, source: "C")

        let tokenA2 = try await beginInvalidation(tracker, tag: usersTag, source: "A2")
        XCTAssertTrue(tokenA2.wasSkipped)
        let cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 1)

        let chain = await read(tracker) { $0.currentChain }
        XCTAssertEqual(chain.count, 3)
        XCTAssertEqual(chain[0].source, "A")
        XCTAssertEqual(chain[1].source, "B")
        XCTAssertEqual(chain[2].source, "C")

        await endInvalidation(tracker, token: tokenA2)
        await endInvalidation(tracker, token: tokenC)
        await endInvalidation(tracker, token: tokenB)
        await endInvalidation(tracker, token: tokenA)
    }

    // MARK: - Depth Limiting

    func testMaxDepthExceeded() async throws {
        let tracker = await makeTracker(.init(maxDepth: 3, throwOnCycle: false, logWarnings: false))

        let token1 = try await beginInvalidation(tracker, tag: QueryTag("tag1"))
        let token2 = try await beginInvalidation(tracker, tag: QueryTag("tag2"))
        let token3 = try await beginInvalidation(tracker, tag: QueryTag("tag3"))

        let token4 = try await beginInvalidation(tracker, tag: QueryTag("tag4"))
        XCTAssertTrue(token4.wasSkipped)
        let depthExceededCount = await read(tracker) { $0.stats }.depthExceededCount
        XCTAssertEqual(depthExceededCount, 1)

        await endInvalidation(tracker, token: token4)
        await endInvalidation(tracker, token: token3)
        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }

    func testMaxDepthThrows() async {
        let tracker = await makeTracker(.init(maxDepth: 2, throwOnCycle: true, logWarnings: false))

        let token1 = try! await beginInvalidation(tracker, tag: QueryTag("tag1"))
        let token2 = try! await beginInvalidation(tracker, tag: QueryTag("tag2"))

        await XCTAssertThrowsErrorAsync({ try await beginInvalidation(tracker, tag: QueryTag("tag3")) }) { error in
            guard case InvalidationTracker.TrackerError.maxDepthExceeded(let depth, let maxDepth, _) = error else {
                XCTFail("Expected maxDepthExceeded error")
                return
            }
            XCTAssertEqual(depth, 3)
            XCTAssertEqual(maxDepth, 2)
        }

        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }

    // MARK: - WithInvalidation

    func testWithInvalidation() async throws {
        let tracker = await makeTracker()

        var operationRan = false

        try await tracker.withInvalidation(tag: usersTag) {
            operationRan = true
            let isInvalidating = await read(tracker) { $0.isInvalidating }
            XCTAssertTrue(isInvalidating)
            let currentDepth = await read(tracker) { $0.currentDepth }
            XCTAssertEqual(currentDepth, 1)
        }

        XCTAssertTrue(operationRan)
        let isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertFalse(isInvalidating)
        let currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)
    }

    func testWithInvalidationCleansUpOnError() async {
        let tracker = await makeTracker()

        do {
            try await tracker.withInvalidation(tag: usersTag) {
                let currentDepth = await read(tracker) { $0.currentDepth }
                XCTAssertEqual(currentDepth, 1)
                throw CycleTestError.intentionalError
            }
            XCTFail("Should have thrown")
        } catch is CycleTestError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertFalse(isInvalidating)
        let currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)
    }

    // MARK: - Statistics

    func testStatistics() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: false, logWarnings: false))

        var stats = await read(tracker) { $0.stats }
        XCTAssertEqual(stats.totalInvalidations, 0)
        XCTAssertEqual(stats.cyclesDetected, 0)
        XCTAssertEqual(stats.maxDepthReached, 0)

        let token1 = try await beginInvalidation(tracker, tag: usersTag)
        stats = await read(tracker) { $0.stats }
        XCTAssertEqual(stats.totalInvalidations, 1)
        XCTAssertEqual(stats.maxDepthReached, 1)

        let token2 = try await beginInvalidation(tracker, tag: postsTag)
        stats = await read(tracker) { $0.stats }
        XCTAssertEqual(stats.totalInvalidations, 2)
        XCTAssertEqual(stats.maxDepthReached, 2)

        _ = try await beginInvalidation(tracker, tag: usersTag)
        stats = await read(tracker) { $0.stats }
        XCTAssertEqual(stats.totalInvalidations, 3)
        XCTAssertEqual(stats.cyclesDetected, 1)

        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }

    func testReset() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: false, logWarnings: false))

        _ = try await beginInvalidation(tracker, tag: usersTag)
        _ = try await beginInvalidation(tracker, tag: usersTag) // cycle

        var cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 1)
        var isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertTrue(isInvalidating)

        await MainActor.run { tracker.reset() }

        cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 0)
        isInvalidating = await read(tracker) { $0.isInvalidating }
        XCTAssertFalse(isInvalidating)
        let currentDepth = await read(tracker) { $0.currentDepth }
        XCTAssertEqual(currentDepth, 0)
    }

    // MARK: - Callback

    func testOnCycleDetectedCallback() async throws {
        // Use nonisolated(unsafe) to satisfy Sendable requirement in test
        nonisolated(unsafe) var detectedCycle: InvalidationTracker.CycleInfo?

        let tracker = await makeTracker(.init(
            throwOnCycle: false,
            logWarnings: false,
            onCycleDetected: { info in
                detectedCycle = info
            }
        ))

        let token1 = try await beginInvalidation(tracker, tag: usersTag, source: "source1")
        _ = try await beginInvalidation(tracker, tag: usersTag, source: "source2")

        XCTAssertNotNil(detectedCycle)
        XCTAssertEqual(detectedCycle?.trigger, "tag:users")
        XCTAssertEqual(detectedCycle?.chain.count, 1)
        XCTAssertEqual(detectedCycle?.chain[0].source, "source1")

        await endInvalidation(tracker, token: token1)
    }

    // MARK: - Configuration Presets

    func testStrictConfiguration() {
        let config = InvalidationTracker.Configuration.strict
        XCTAssertEqual(config.maxDepth, 5)
        XCTAssertTrue(config.throwOnCycle)
        XCTAssertTrue(config.logWarnings)
    }

    func testPermissiveConfiguration() {
        let config = InvalidationTracker.Configuration.permissive
        XCTAssertEqual(config.maxDepth, 20)
        XCTAssertFalse(config.throwOnCycle)
        XCTAssertTrue(config.logWarnings)
    }

    // MARK: - CycleInfo Description

    func testCycleInfoDescription() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: true, logWarnings: false))

        let token1 = try await beginInvalidation(tracker, tag: usersTag, source: "mutation1")

        do {
            _ = try await beginInvalidation(tracker, tag: usersTag, source: "mutation2")
            XCTFail("Should have thrown")
        } catch let error as InvalidationTracker.TrackerError {
            if case .cycleDetected(let info) = error {
                XCTAssertTrue(info.description.contains("Cycle detected"))
                XCTAssertTrue(info.description.contains("tag:users"))
            } else {
                XCTFail("Expected cycleDetected error")
            }
        }

        await endInvalidation(tracker, token: token1)
    }

    // MARK: - Different Tags Don't Cycle

    func testDifferentTagsNoCycle() async throws {
        let tracker = await makeTracker(.init(throwOnCycle: true, logWarnings: false))

        let token1 = try await beginInvalidation(tracker, tag: usersTag)
        let token2 = try await beginInvalidation(tracker, tag: postsTag)
        let token3 = try await beginInvalidation(tracker, tag: commentsTag)

        XCTAssertFalse(token1.wasSkipped)
        XCTAssertFalse(token2.wasSkipped)
        XCTAssertFalse(token3.wasSkipped)
        let cyclesDetected = await read(tracker) { $0.stats }.cyclesDetected
        XCTAssertEqual(cyclesDetected, 0)

        await endInvalidation(tracker, token: token3)
        await endInvalidation(tracker, token: token2)
        await endInvalidation(tracker, token: token1)
    }
}

// MARK: - Test Helpers

private enum CycleTestError: Error {
    case intentionalError
}

// MARK: - MainActor Helpers

private func makeTracker(
    _ configuration: InvalidationTracker.Configuration = .default
) async -> InvalidationTracker {
    await MainActor.run { InvalidationTracker(configuration: configuration) }
}

private func beginInvalidation(
    _ tracker: InvalidationTracker,
    tag: QueryTag,
    source: String? = nil
) async throws -> InvalidationToken {
    try await MainActor.run { try tracker.beginInvalidation(tag: tag, source: source) }
}

private func endInvalidation(
    _ tracker: InvalidationTracker,
    token: InvalidationToken
) async {
    await MainActor.run { tracker.endInvalidation(token) }
}

private func read<T: Sendable>(_ tracker: InvalidationTracker, _ value: @MainActor (InvalidationTracker) -> T) async -> T {
    await MainActor.run { value(tracker) }
}

extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail(message.isEmpty ? "Expected error" : message, file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
#endif
