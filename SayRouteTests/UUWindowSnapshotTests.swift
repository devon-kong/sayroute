import ApplicationServices
import XCTest
@testable import SayRoute

@MainActor
final class UUWindowSnapshotTests: XCTestCase {
    func testMissingOrUnrelatedFrontmostApplicationCannotCaptureAWindow() async {
        XCTAssertNil(UUWindowSnapshot.capture(for: nil))
        XCTAssertNil(UUWindowSnapshot.capture(for: NSRunningApplication.current))
    }

    func testAnApplicationElementCannotActAsAWindow() {
        XCTAssertNil(UUWindowSnapshot.inspect(AXUIElementCreateApplication(-1)))
    }
}
