import CoreGraphics
import XCTest
@testable import Doubao_Murmur

final class PasteKeySafetyTests: XCTestCase {
    func testHIDContaminationAfterDownDoesNotLeakIntoUp() {
        // Observed on the controlled Mac: our own V-down changes global HID
        // flags from 0x20000000 to 0x20100000 without a physical Command press.
        var globalHID = CGEventFlags(rawValue: 0x20000000)
        var events: [CGEvent] = []
        let result = BalancedPasteKeys.post(hidFlags: { globalHID },
            sessionFlags: { CGEventFlags(rawValue: 0x20000000) }, emit: { event in
                events.append(event.copy()!)
                if event.type == .keyDown { globalHID = CGEventFlags(rawValue: 0x20100000) }
            })
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 9 })
        XCTAssertEqual(events.first?.flags.rawValue, 0x20100000)
        XCTAssertEqual(events.last?.flags.rawValue, 0x20000000,
                       "The helper must not copy its own synthetic Command into V-up")
    }

    func testPasteUsesPrivateSourceAndEndsWithoutSyntheticCommand() {
        var events: [CGEvent] = []
        let result = BalancedPasteKeys.post(hidFlags: { [] }, sessionFlags: { [] }, emit: { events.append($0.copy()!) })
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.type, .keyDown)
        XCTAssertEqual(events.first?.getIntegerValueField(.keyboardEventKeycode), 9)
        XCTAssertTrue(events.first?.flags.contains(.maskCommand) == true)
        XCTAssertEqual(events.last?.type, .keyUp)
        XCTAssertFalse(events.last?.flags.contains(.maskCommand) == true,
                       "The last synthetic event must not leave Command asserted for Delete/Space")
        let sourceID = events.first?.getIntegerValueField(.eventSourceStateID)
        // CG allocates a unique runtime ID for privateState, rather than -1.
        XCTAssertNotEqual(sourceID, 0)
        XCTAssertNotEqual(sourceID, 1)
        XCTAssertEqual(sourceID, events.last?.getIntegerValueField(.eventSourceStateID))
    }

    func testHeldPhysicalOrRemoteModifiersPreventAnySyntheticInput() {
        for flags: CGEventFlags in [.maskCommand, .maskShift, .maskAlternate, .maskControl] {
            var count = 0
            XCTAssertEqual(BalancedPasteKeys.post(hidFlags: { flags }, sessionFlags: { [] }, emit: { _ in count += 1 }), .modifiersHeld)
            XCTAssertEqual(BalancedPasteKeys.post(hidFlags: { [] }, sessionFlags: { flags }, emit: { _ in count += 1 }), .modifiersHeld)
            XCTAssertEqual(count, 0)
        }
    }

    func testPreparedFlagsDescribeBothEventsBeforeEmission() {
        var events: [CGEvent] = []
        var prepared: [BalancedPasteKeys.PreparedFlags] = []
        let result = BalancedPasteKeys.post(hidFlags: { CGEventFlags(rawValue: 0x20000000) }, sessionFlags: { [] },
            emit: { events.append($0.copy()!) }, onPrepared: { flags in
                XCTAssertTrue(events.isEmpty)
                prepared.append(flags)
            })
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.initialHID.rawValue, 0x20000000)
        XCTAssertEqual(prepared.first?.initialSession.rawValue, 0)
        XCTAssertEqual(prepared.first?.down.rawValue, 0x20100000)
        XCTAssertEqual(prepared.first?.up.rawValue, 0x20000000)
        XCTAssertEqual(events.first?.flags, prepared.first?.down)
        XCTAssertEqual(events.last?.flags, prepared.first?.up)
    }

    func testCapsLockSurvivesWithoutSyntheticCommandInFinalEvent() {
        var events: [CGEvent] = []
        let result = BalancedPasteKeys.post(hidFlags: { [.maskAlphaShift, .maskNonCoalesced] },
            sessionFlags: { [.maskAlphaShift] }, emit: { events.append($0.copy()!) })
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(events.last?.flags.rawValue, 0x00010100)
        XCTAssertEqual(events.first?.flags.rawValue, 0x00110100)
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 9 })
    }
}
