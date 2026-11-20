import ApplicationServices
import XCTest
@testable import SayRoute

@MainActor
final class UUFullscreenRoutingTests: XCTestCase {
    private let a = AXUIElementCreateApplication(101)
    private let b = AXUIElementCreateApplication(102)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let bindings = [UUBinding(deviceId: "A", name: "A", port: 17771),
                            UUBinding(deviceId: "B", name: "B", port: 17772)]

    private func session(_ id: String, age: Int = 50, name: String? = nil) -> UUConnection {
        let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(age)))
        return UUConnection(deviceId: id, deviceName: name ?? id, platform: "mac", connectionState: "connected",
                            isControlling: true, connectionStartTime: start)
    }

    private func snapshot(_ window: AXUIElement, _ label: String? = nil) -> UUWindowSnapshot {
        UUWindowSnapshot(window: window, label: label, isFullscreen: label == nil, capturedAt: now)
    }

    private func failure(_ destination: Task<UUTarget, Error>, _ expected: PasteFailureReason,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await destination.value; XCTFail("unexpected destination", file: file, line: line) }
        catch { XCTAssertEqual(error as? PasteFailureReason, expected, file: file, line: line) }
    }

    func testTwoNamedWindowsKeepSeparateSessionsAcrossSpacesAndRapidSwitches() async throws {
        let router = UUWindowRouter { [self] in [session("B"), session("A")] }
        router.learn(snapshot(a, "A"))
        router.learn(snapshot(b, "B"))
        let first = router.destination(for: snapshot(a), bindings: bindings)
        let second = router.destination(for: snapshot(b), bindings: bindings)
        let third = router.destination(for: snapshot(a), bindings: bindings)
        let ports = try await [first.value.port, second.value.port, third.value.port]
        XCTAssertEqual(ports, [17771, 17772, 17771])
    }

    func testUnknownFullscreenNeverInfersFromSingleDeviceOrConnectionOrder() async {
        var live = [session("B")]
        let router = UUWindowRouter { live }
        await failure(router.destination(for: snapshot(a), bindings: bindings), .uuFullscreenNeedsName)
        live.append(session("A"))
        router.learn(snapshot(b, "B"))
        await failure(router.destination(for: snapshot(a), bindings: bindings), .uuFullscreenNeedsName)
        await failure(router.destination(for: nil, bindings: bindings), .uuWindowUnidentified)
    }

    func testReconnectExpiresFullscreenIdentityAndWindowedObservationRebinds() async throws {
        var live = [session("A", age: 15)]
        let router = UUWindowRouter { live }
        let original = try await router.destination(for: snapshot(a, "A"), bindings: bindings).value
        live = [session("A", age: 3)]
        XCTAssertThrowsError(try original.validate(connections: live, bindings: bindings))
        await failure(router.destination(for: snapshot(a), bindings: bindings), .uuDisconnected)
        XCTAssertFalse(router.knows(a))
        router.learn(snapshot(a, "A"))
        let updated = try await router.destination(for: snapshot(a), bindings: bindings).value
        XCTAssertNotEqual(updated, original)
    }

    func testChangedBindingsApplyOnlyToTheNextRecording() async throws {
        let live = [session("A"), session("B")]
        let router = UUWindowRouter { live }
        let original = try await router.destination(for: snapshot(a, "A"), bindings: bindings).value
        let changed = [UUBinding(deviceId: "A", name: "A", port: 19999)]
        let next = try await router.destination(for: snapshot(a), bindings: changed).value
        XCTAssertEqual(next.port, 19999)
        XCTAssertThrowsError(try original.validate(connections: live, bindings: changed))
        await failure(router.destination(for: snapshot(b, "B"), bindings: changed), .uuInvalidBinding)
    }

    func testWindowDestructionAndProcessRestartInvalidateCache() async throws {
        let router = UUWindowRouter { [self] in [session("A"), session("B")] }
        router.learn(snapshot(a, "A"))
        router.learn(snapshot(b, "B"))
        router.forget(a)
        await failure(router.destination(for: snapshot(a), bindings: bindings), .uuFullscreenNeedsName)
        let target = try await router.destination(for: snapshot(b), bindings: bindings).value
        XCTAssertEqual(target.deviceId, "B")
        router.reset()
        await failure(router.destination(for: snapshot(b), bindings: bindings), .uuFullscreenNeedsName)
    }

    func testDuplicateNamesAndConnectionsNewerThanObservationCannotBind() async {
        var live = [session("A"), session("B", name: "A")]
        let router = UUWindowRouter { live }
        await failure(router.destination(for: snapshot(a, "A"), bindings: bindings), .uuWindowUnidentified)
        live = [session("A", age: -5)]
        await failure(router.destination(for: snapshot(a, "A"), bindings: bindings), .uuWindowUnidentified)
    }

    func testNameAppearsBeforeCLIListsNewConnection() async throws {
        var calls = 0
        let router = UUWindowRouter { [self] in
            calls += 1
            return calls == 1 ? [] : [session("B")]
        }
        router.learn(snapshot(b, "B"))
        let target = try await router.destination(for: snapshot(b), bindings: bindings).value
        XCTAssertEqual(target.port, 17772)
        XCTAssertEqual(calls, 3)
    }
}
