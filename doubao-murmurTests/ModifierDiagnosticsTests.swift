import CoreGraphics
import XCTest
@testable import Doubao_Murmur

final class ModifierDiagnosticsTests: XCTestCase {
    func testPreparedDetailsExposeOnlyRequestedModifierMetadata() throws {
        let flags = BalancedPasteKeys.PreparedFlags(initialHID: CGEventFlags(rawValue: 0x20000000),
            initialSession: [], down: CGEventFlags(rawValue: 0x20100000), up: CGEventFlags(rawValue: 0x20000000))
        let data = Data(ModifierDiagnostics.preparedDetails(flags).utf8)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["initial_hid_flags", "initial_session_flags", "prepared_down_flags", "prepared_up_flags", "strategy"]))
        XCTAssertEqual(fields["initial_hid_flags"] as? UInt64, 0x20000000)
        XCTAssertEqual(fields["initial_session_flags"] as? UInt64, 0)
        XCTAssertEqual(fields["prepared_down_flags"] as? UInt64, 0x20100000)
        XCTAssertEqual(fields["prepared_up_flags"] as? UInt64, 0x20000000)
        XCTAssertEqual(fields["strategy"] as? String, "preflight-snapshot-v2")
    }

    func testOnlyPostedPairSchedulesOneDeferredObservation() {
        for result: BalancedPasteKeys.Result in [.posted, .modifiersHeld, .eventCreationFailed] {
            var delays: [TimeInterval] = [], callbacks: [() -> Void] = []
            var captures = 0
            ModifierDiagnostics.schedulePostDispatch(result: result, schedule: { delay, work in
                delays.append(delay)
                callbacks.append(work)
            }, capture: { captures += 1 })
            XCTAssertEqual(captures, 0, "Observation must not block the paste/ACK path")
            XCTAssertEqual(delays, result == .posted ? [0.05] : [])
            callbacks.forEach { $0() }
            XCTAssertEqual(captures, result == .posted ? 1 : 0)
        }
    }

    func testOnlyExplicitAcceptanceKeysAreClassifiedWithoutText() {
        XCTAssertEqual(ModifierDiagnostics.keyClass(type: .keyDown, keyCode: 49), "space")
        XCTAssertEqual(ModifierDiagnostics.keyClass(type: .keyDown, keyCode: 51), "delete")
        XCTAssertEqual(ModifierDiagnostics.keyClass(type: .flagsChanged, keyCode: 54), "right_command")
        XCTAssertEqual(ModifierDiagnostics.keyClass(type: .keyDown, keyCode: 0), "test_character")
        XCTAssertNil(ModifierDiagnostics.keyClass(type: .keyDown, keyCode: 12))
        XCTAssertNil(ModifierDiagnostics.keyClass(type: .mouseMoved, keyCode: 49))
    }
    @MainActor func testModifierFailureRemainsNotSentRatherThanAmbiguous() {
        XCTAssertEqual(DirectPasteOrderCoordinator.outcome(for: RemoteClipboardClientError.unexpectedStatus(423)), .notSent(.modifiersHeld))
    }
}
