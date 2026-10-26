import AppKit
import XCTest
@testable import SayRoute

final class RecoveryNoticeTests: XCTestCase {
    private func notice(_ text: String, mode: OverlayPositionMode = .followMouse, x: CGFloat = 500) -> RecoveryNotice {
        RecoveryNotice(message: text, placement: OverlayPlacementContext(mode: mode, anchor: NSPoint(x: x, y: 400),
            displays: [OverlayDisplay(id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))]))
    }

    func testDeferredFailureRetainsItsOwnSessionPlacement() {
        var state = RecoveryNoticeState()
        let oldSession = notice("old", mode: .followMouse, x: 700)
        state.setBusy(true)
        state.receive(oldSession)
        let nextSession = notice("new", mode: .screenTop, x: 30)
        XCTAssertNil(state.visibleNotice)
        state.setBusy(false)
        XCTAssertEqual(state.visibleNotice?.placement, oldSession.placement)
        XCTAssertNotEqual(state.visibleNotice?.placement, nextSession.placement)
        state.receive(nextSession)
        XCTAssertEqual(state.visibleNotice, nextSession)
    }

    func testRecordingDefersLatestNoticeAndDismissalDoesNotReplay() {
        var state = RecoveryNoticeState()
        state.receive(notice("first"))
        XCTAssertEqual(state.visibleNotice?.message, "first")
        state.setBusy(true)
        XCTAssertNil(state.visibleNotice)
        state.receive(notice("second"))
        state.receive(notice("latest"))
        XCTAssertNil(state.visibleNotice)
        state.setBusy(false)
        XCTAssertEqual(state.visibleNotice?.message, "latest")
        state.dismiss()
        state.setBusy(true)
        state.setBusy(false)
        XCTAssertNil(state.visibleNotice)
    }

    func testOverlayAndNoticeShareTopAnchorOnOffsetScreen() {
        let screen = NSRect(x: -1920, y: 160, width: 1920, height: 1040)
        let overlay = OverlayGeometry.frame(in: screen, height: 76)
        let notice = OverlayGeometry.frame(in: screen, height: 156)
        XCTAssertEqual(overlay.midX, screen.midX)
        XCTAssertEqual(notice.midX, overlay.midX)
        XCTAssertEqual(notice.maxY, overlay.maxY)
        XCTAssertTrue(screen.contains(notice))
    }
}
