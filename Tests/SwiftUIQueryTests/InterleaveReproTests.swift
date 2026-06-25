import XCTest
@testable import SwiftUIQuery
#if !os(Linux)

/// Regression tests for the InvalidationTracker reentrancy fix (#1).
///
/// Before the fix, two `withInvalidation` scopes interleaving on the MainActor
/// across an `await` corrupted a single shared LIFO stack: entries leaked, and a
/// leaked tag then spuriously tripped cycle detection, silently dropping all
/// later invalidations. The fix scopes each invalidation tree with `@TaskLocal`,
/// so concurrent trees are isolated while genuine in-tree reentry is still caught.
final class InterleaveReproTests: XCTestCase {

    /// Two interleaving invalidation scopes must each unwind cleanly — no leak.
    @MainActor
    func testInterleavedInvalidationDoesNotLeakChain() async throws {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 5, throwOnCycle: true))

        // Operation A: begins, suspends on yields, then resumes and ends.
        let a = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("A")) {
                await Task.yield()
                await Task.yield()
            }
        }

        // Ensure A has begun and suspended before B starts.
        await Task.yield()

        let b = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("B")) {
                await Task.yield()
            }
        }

        _ = try await a.value
        _ = try await b.value

        XCTAssertEqual(tracker.currentDepth, 0, "Chain leaked: \(tracker.currentChain.map(\.identifier))")
        XCTAssertFalse(tracker.isInvalidating)
    }

    /// After interleaved invalidations complete, a normal invalidation of the same
    /// tag must NOT be mis-detected as a cycle (the bug silently dropped it).
    @MainActor
    func testNoFalseCycleAfterConcurrentInvalidations() async throws {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 5, throwOnCycle: true))

        let a = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("A")) {
                await Task.yield(); await Task.yield()
            }
        }
        await Task.yield()
        let b = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("B")) { await Task.yield() }
        }
        _ = try? await a.value
        _ = try? await b.value

        var threw = false
        do {
            try await tracker.withInvalidation(tag: QueryTag("A")) {}
        } catch {
            threw = true
        }
        XCTAssertFalse(threw, "A fresh invalidation of A must not trip a spurious cycle")
        XCTAssertEqual(tracker.stats.cyclesDetected, 0)
    }

    /// Concurrent invalidations of the *same* tag in separate trees are independent
    /// — neither should see the other's chain, so neither is dropped as a cycle.
    @MainActor
    func testConcurrentSiblingTreesAreIsolated() async throws {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 5, throwOnCycle: true))

        let a = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("X")) {
                await Task.yield(); await Task.yield()
            }
        }
        await Task.yield()
        let b = Task { @MainActor in
            try await tracker.withInvalidation(tag: QueryTag("X")) { await Task.yield() }
        }

        // Both must complete without throwing a (false) cycle error.
        try await a.value
        try await b.value
        XCTAssertEqual(tracker.currentDepth, 0)
    }

    /// A genuine in-tree reentry (A → A within one task) must STILL be detected.
    @MainActor
    func testRealCascadeStillDetectsCycle() async throws {
        let tracker = InvalidationTracker(configuration: .init(maxDepth: 5, throwOnCycle: true))

        var reachedInner = false
        var threw = false
        do {
            try await tracker.withInvalidation(tag: QueryTag("A")) {
                try await tracker.withInvalidation(tag: QueryTag("A")) {
                    reachedInner = true
                }
            }
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "A genuine A→A reentry within one task must be detected")
        XCTAssertFalse(reachedInner, "the cyclic inner operation must not run")
    }
}
#endif
