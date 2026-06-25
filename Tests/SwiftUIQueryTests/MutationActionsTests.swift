// MutationActions is part of the SwiftUI-only property wrapper surface.
#if canImport(SwiftUI)

import XCTest
@testable import SwiftUIQuery

@MainActor
final class MutationActionsTests: XCTestCase {
    func testProjectedValueResetClearsState() async throws {
        let mutation = MutationState<Int, Int>(
            mutationFn: { input in input + 1 }
        )

        XCTAssertTrue(mutation.isIdle)
        XCTAssertNil(mutation.data)

        _ = try await mutation.mutate(41)
        XCTAssertTrue(mutation.isSuccess)
        XCTAssertEqual(mutation.data, 42)

        let actions = MutationActions(state: mutation)
        actions.reset()

        XCTAssertTrue(mutation.isIdle)
        XCTAssertNil(mutation.data)
        XCTAssertNil(mutation.error)
        XCTAssertNil(mutation.variables)
        XCTAssertNil(mutation.submittedAt)
    }
}

#endif
