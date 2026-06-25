import XCTest
@testable import SwiftUIQuery

final class UncheckedSendableTests: XCTestCase {
    func testUncheckedSendableStoresWrappedValue() {
        let wrapper = UncheckedSendable(wrappedValue: 123)
        XCTAssertEqual(wrapper.wrappedValue, 123)
    }
}

