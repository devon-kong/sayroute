import XCTest
import CoreGraphics
@testable import SayRoute

final class StartShortcutTests: XCTestCase {
    func testRecordingValidatesModifiersKeysAndCancellation() throws {
        let expected = try XCTUnwrap(StartShortcut(keyCode: 1, modifiers: [.maskAlternate, .maskShift]))
        let capture = ShortcutInteraction.record
        XCTAssertEqual(capture.keyDown(keyCode: 1, flags: [.maskAlternate, .maskShift, .maskAlphaShift], current: .standard), .save(expected))
        for flags: CGEventFlags in [[], .maskShift, [.maskControl, .maskSecondaryFn]] {
            XCTAssertEqual(capture.keyDown(keyCode: 1, flags: flags, current: .standard), .invalid)
        }
        for keyCode: Int64 in [36, 48, 49, 54, 63] {
            XCTAssertEqual(capture.keyDown(keyCode: keyCode, flags: .maskControl, current: .standard), .invalid)
        }
        XCTAssertEqual(capture.keyDown(keyCode: 53, flags: [], current: .standard), .cancel)
    }

    func testSimulatedPasteCannotBeAssignedAsStartShortcut() {
        let result = BalancedPasteKeys.post(hidFlags: { [] }, sessionFlags: { [] }, emit: { event in
            guard event.type == .keyDown else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            XCTAssertNil(StartShortcut(keyCode: keyCode, modifiers: event.flags))
            XCTAssertEqual(ShortcutInteraction.record.keyDown(keyCode: keyCode, flags: event.flags, current: .standard),
                           .pasteReserved)
        })
        XCTAssertEqual(result, .posted)
        XCTAssertNotNil(StartShortcut(keyCode: 9, modifiers: [.maskCommand, .maskShift]))
    }

    func testTryShortcutRequiresExactChordAndNeverProducesSaveOrToggle() throws {
        let custom = try XCTUnwrap(StartShortcut(keyCode: 8, modifiers: [.maskCommand, .maskShift]))
        let test = ShortcutInteraction.test
        XCTAssertEqual(test.keyDown(keyCode: 8, flags: [.maskCommand, .maskShift], current: custom), .testPassed)
        XCTAssertEqual(test.keyDown(keyCode: 8, flags: [.maskCommand], current: custom), .testMiss)
        XCTAssertEqual(test.keyDown(keyCode: 8, flags: [.maskCommand, .maskShift, .maskControl], current: custom), .testMiss)
        XCTAssertEqual(test.keyDown(keyCode: 44, flags: .maskControl, current: custom), .testMiss)
        XCTAssertEqual(test.keyDown(keyCode: 53, flags: [], current: custom), .cancel)
    }

    func testReleaseWaitsForAllConfiguredModifiersAndRepressedKeys() throws {
        let custom = try XCTUnwrap(StartShortcut(keyCode: 8, modifiers: [.maskCommand, .maskShift]))
        var gate = StopHotkeyReleaseGate()
        XCTAssertTrue(gate.begin(custom))
        XCTAssertFalse(gate.fullyReleased(after: .keyUp, keyCode: 44, flags: []))
        XCTAssertFalse(gate.fullyReleased(after: .keyUp, keyCode: 8, flags: custom.modifiers))
        XCTAssertFalse(gate.fullyReleased(after: .flagsChanged, keyCode: 56, flags: .maskCommand))
        XCTAssertFalse(gate.fullyReleased(after: .flagsChanged, keyCode: 56, flags: custom.modifiers))
        XCTAssertFalse(gate.fullyReleased(after: .keyDown, keyCode: 8, flags: custom.modifiers))
        XCTAssertFalse(gate.fullyReleased(after: .flagsChanged, keyCode: 54, flags: []))
        XCTAssertTrue(gate.fullyReleased(after: .keyUp, keyCode: 8, flags: .maskAlternate))
        XCTAssertFalse(gate.fullyReleased(after: .keyUp, keyCode: 8, flags: []))
    }

    func testPersistenceDefaultAndMalformedPreference() throws {
        let suite = "StartShortcutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = StartShortcutPreferences(defaults: defaults)
        XCTAssertEqual(prefs.shortcut, .standard)
        let custom = try XCTUnwrap(StartShortcut(keyCode: 18, modifiers: [.maskAlternate, .maskShift]))
        prefs.shortcut = custom
        XCTAssertEqual(StartShortcutPreferences(defaults: defaults).shortcut, custom)
        prefs.shortcut = .standard
        XCTAssertNil(defaults.object(forKey: StartShortcutPreferences.key))
        defaults.set(["keyCode": 54, "modifiers": 0], forKey: StartShortcutPreferences.key)
        XCTAssertEqual(prefs.shortcut, .standard)
    }
}
