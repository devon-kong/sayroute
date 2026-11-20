import XCTest
@testable import SayRoute

final class UUTargetTests: XCTestCase {
    let a = UUConnection(deviceId: "a", deviceName: "Mac A", platform: "mac", connectionState: "connected", isControlling: true, connectionStartTime: "first")
    let b = UUConnection(deviceId: "b", deviceName: "Mac B", platform: "mac", connectionState: "connected", isControlling: true, connectionStartTime: "second")
    let bindings = [UUBinding(deviceId: "a", name: "Mac A", port: 17771), UUBinding(deviceId: "b", name: "Mac B", port: 17772)]

    func testCapturedLabelsSelectOnlyTheirOwnPortAcrossSwitch() throws {
        let first = try UUTarget.resolve(labels: ["Mac A"], connections: [a,b], bindings: bindings)
        let second = try UUTarget.resolve(labels: ["Mac B"], connections: [b,a], bindings: bindings)
        XCTAssertEqual(first.url.absoluteString, "http://127.0.0.1:17771")
        XCTAssertEqual(second.url.absoluteString, "http://127.0.0.1:17772")
        XCTAssertNoThrow(try first.validate(connections: [b,a], bindings: bindings))
        XCTAssertThrowsError(try first.validate(connections: [b], bindings: bindings))
        XCTAssertThrowsError(try first.validate(connections: [a,b], bindings: Array(bindings.dropFirst())))
    }

    func testAmbiguousUnboundAndNonSessionWindowsNeverGuess() {
        let duplicate = UUConnection(deviceId: "c", deviceName: "Mac A", platform: "mac", connectionState: "connected", isControlling: true, connectionStartTime: "third")
        for labels in [[], ["Mac"], ["Mac A","Mac B"]] as [[String]] {
            XCTAssertThrowsError(try UUTarget.resolve(labels: labels, connections: [a,b], bindings: bindings))
        }
        XCTAssertThrowsError(try UUTarget.resolve(labels: ["Mac A"], connections: [a,duplicate], bindings: bindings))
        XCTAssertThrowsError(try UUTarget.resolve(labels: ["Mac B"], connections: [a,b], bindings: [bindings[0]]))
        XCTAssertFalse(UUWindowCapture.isRemoteWindow(title: "端口映射", roles: ["AXStaticText", "AXImage"]))
        XCTAssertFalse(UUWindowCapture.isRemoteWindow(title: "", roles: ["AXSplitGroup", "AXToolbar", "AXStaticText"]))
        XCTAssertTrue(UUWindowCapture.isRemoteWindow(title: "", roles: ["AXButton", "AXStaticText", "AXImage"]))
    }

    func testDeviceNameInMacMiniToolbarLayout() {
        let roles = ["AXButton", "AXButton", "AXButton", "AXImage", "AXStaticText", "AXButton",
                     "AXStaticText", "AXImage", "AXImage", "AXStaticText", "AXImage", "AXStaticText", "AXStaticText"]
        let labels = [4: "60 FPS", 6: "办公室的Mac mini", 9: "00:14:12", 11: "统计", 12: "设置"]
        let name = UUWindowCapture.deviceName(title: "", roles: roles,
                                              knownNames: ["家里的Mac mini", "办公室的Mac mini"]) { labels[$0] }
        XCTAssertEqual(name, "办公室的Mac mini")
    }

    func testMatchesOnlyExactRegisteredNamesInStreamChrome() {
        let roles = ["AXImage", "AXButton", "AXButton", "AXButton", "AXImage", "AXStaticText", "AXStaticText"]
        let names: Set<String> = ["Mac A", "Mac B"]
        func identify(_ labels: [String], title: String = "") -> String? {
            UUWindowCapture.deviceName(title: title, roles: roles, knownNames: names) { index in
                XCTAssertTrue([5, 6].contains(index))
                return labels[index - 5]
            }
        }
        XCTAssertEqual(identify(["  Mac A  ", "00:01:42"]), "Mac A")
        XCTAssertEqual(identify(["00:01:42", "Mac B"]), "Mac B")
        XCTAssertNil(identify(["Mac A", "Mac B"]))
        XCTAssertNil(identify(["Mac", "00:01:42"]))
        XCTAssertNil(identify(["Mac A", "17772"], title: "端口映射"))
    }

    func testNameReusedByAnotherDeviceBetweenCaptureAndLookupIsRejected() {
        let replacement = UUConnection(deviceId: "b", deviceName: "Mac A", platform: "mac",
            connectionState: "connected", isControlling: true, connectionStartTime: "new")
        XCTAssertThrowsError(try UUTarget.resolve(labels: ["Mac A"], connections: [replacement], bindings: bindings))
    }

    func testReconnectingSameDeviceInvalidatesPendingRequest() throws {
        let locked = try UUTarget.resolve(labels: ["Mac A"], connections: [a], bindings: bindings)
        let reconnected = UUConnection(deviceId: "a", deviceName: "Mac A", platform: "mac",
            connectionState: "connected", isControlling: true, connectionStartTime: "later")
        XCTAssertThrowsError(try locked.validate(connections: [reconnected], bindings: bindings))
    }

    func testBindingEditsArePersistentAndRejectDuplicatePorts() throws {
        let suite = "UU-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UUBindingStore(defaults: defaults)
        try store.save(bindings[0])
        XCTAssertThrowsError(try store.save(UUBinding(deviceId: "b", name: "Mac B", port: 17771)))
        try store.save(bindings[1])
        XCTAssertEqual(UUBindingStore(defaults: defaults).bindings, bindings)
        store.remove("a")
        XCTAssertEqual(store.bindings, [bindings[1]])
    }

    func testV22BindingsLoadAndAliasEditsDoNotChangePendingRequests() throws {
        let suite = "UU-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"[{"deviceId":"a","name":"Mac A","port":17771}]"#.utf8), forKey: "uuFastDeviceBindings")
        let store = UUBindingStore(defaults: defaults)
        XCTAssertEqual(store.bindings, [bindings[0]])
        XCTAssertEqual(store.bindings.first?.displayName, "Mac A")
        try store.save(UUBinding(deviceId: "a", name: "Mac A", port: 17771, alias: "  工作机  "))
        let target = try UUTarget.resolve(labels: ["Mac A"], connections: [a], bindings: store.bindings)
        XCTAssertEqual(target.displayName, "工作机")
        XCTAssertThrowsError(try UUTarget.resolve(labels: ["工作机"], connections: [a], bindings: store.bindings))
        try store.save(UUBinding(deviceId: "a", name: "Mac A", port: 17771, alias: "  "))
        XCTAssertNil(store.bindings.first?.alias)
        XCTAssertNoThrow(try target.validate(connections: [a], bindings: store.bindings))
        XCTAssertEqual(target.displayName, "工作机")
        try store.save(UUBinding(deviceId: "a", name: "Mac A", port: 17772))
        XCTAssertThrowsError(try target.validate(connections: [a], bindings: store.bindings))
    }
}
