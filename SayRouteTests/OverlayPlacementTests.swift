import AppKit
import XCTest
@testable import SayRoute

final class OverlayPlacementTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testMouseAnchorIsBottomOneThirdAndTopModeRemainsCentered() {
        let anchor = NSPoint(x: 600, y: 400)
        let frame = OverlayGeometry.frame(in: screen, height: 76, mode: .followMouse, anchor: anchor)
        XCTAssertEqual(frame, NSRect(x: 460, y: 400, width: 420, height: 76))
        XCTAssertEqual(OverlayGeometry.frame(in: screen, height: 76, mode: .screenTop, anchor: anchor),
                       NSRect(x: 510, y: 804, width: 420, height: 76))
    }

    func testCornersFlipDownAndClampHorizontally() {
        for (point, expected) in [
            (NSPoint(x: 5, y: 895), NSRect(x: 12, y: 812, width: 420, height: 76)),
            (NSPoint(x: 1435, y: 895), NSRect(x: 1008, y: 812, width: 420, height: 76)),
            (NSPoint(x: 5, y: 5), NSRect(x: 12, y: 12, width: 420, height: 76)),
            (NSPoint(x: 1435, y: 5), NSRect(x: 1008, y: 12, width: 420, height: 76))
        ] {
            XCTAssertEqual(OverlayGeometry.frame(in: screen, height: 76, mode: .followMouse, anchor: point), expected)
        }
    }

    func testOffsetDisplayAndOversizedPanelRemainInsideUsableArea() {
        let offset = NSRect(x: -1920, y: 120, width: 1920, height: 1040)
        let frame = OverlayGeometry.frame(in: offset, height: 180, mode: .followMouse, anchor: NSPoint(x: -20, y: 1100))
        XCTAssertEqual(frame, NSRect(x: -432, y: 920, width: 420, height: 180))
        let tiny = NSRect(x: 0, y: 0, width: 300, height: 150)
        XCTAssertEqual(OverlayGeometry.frame(in: tiny, height: 180, mode: .followMouse, anchor: .zero),
                       NSRect(x: 12, y: 12, width: 276, height: 126))
    }

    func testDisplaySelectionUsesFullFrameAndDisconnectFallsBack() {
        let screens = [OverlayDisplay(id: 1, frame: screen, visibleFrame: screen),
                       OverlayDisplay(id: 2, frame: NSRect(x: -1000, y: 0, width: 1000, height: 800),
                                      visibleFrame: NSRect(x: -1000, y: 30, width: 1000, height: 740))]
        let context = OverlayPlacementContext(mode: .followMouse, anchor: NSPoint(x: -400, y: 795), displays: screens)
        XCTAssertEqual(context.displayID, 2)
        XCTAssertTrue(screens[1].visibleFrame.contains(context.frame(height: 76, displays: screens)))
        XCTAssertTrue(screen.contains(context.frame(height: 180, displays: [screens[0]])))
    }

    func testSettingsPersistButCapturedSessionDoesNotChange() throws {
        let domain = "overlay-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = OverlayPlacementSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .followMouse)
        let captured = OverlayPlacementContext(mode: settings.mode, anchor: NSPoint(x: 600, y: 400),
            displays: [OverlayDisplay(id: 1, frame: screen, visibleFrame: screen)])
        settings.mode = .screenTop
        XCTAssertEqual(OverlayPlacementSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))).mode, .screenTop)
        XCTAssertEqual(captured.mode, .followMouse)
        defaults.set("obsolete", forKey: OverlayPlacementSettings.defaultsKey)
        XCTAssertEqual(settings.mode, .followMouse)
    }

    func testZoomBridgeFlipsGlobalCoordinatesAndHonorsModeAndEnabledState() {
        let frame = NSRect(x: -800, y: 200, width: 420, height: 76)
        var requested: [CGRect] = []
        for (mode, enabled) in [(OverlayPositionMode.screenTop, true), (.followMouse, false), (.followMouse, true)] {
            OverlayZoomSupport.request(frame: frame, primaryScreenTop: 900, mode: mode, enabled: enabled,
                notify: { requested.append($0) })
        }
        XCTAssertEqual(requested, [CGRect(x: -800, y: 624, width: 420, height: 76)])
    }
}
