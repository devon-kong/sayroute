import XCTest
@testable import SayRoute

@MainActor
final class UUDeviceSettingsTests: XCTestCase {
    private let suite = "UUDeviceSettingsTests-\(UUID())"
    private var store: UUBindingStore { UUBindingStore(defaults: UserDefaults(suiteName: suite)!) }
    private let mac = UUDevice(deviceId: "a", deviceName: "Mac A", platform: "mac", isOnline: false)
    private let legacyHealth = BridgeHealth(ok: true, protocolVersion: 2, accessibilityTrusted: nil, helperBuild: nil)

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRefreshRetainsEditedPortAndAliasAndDistinguishesOfflineFromUnknown() async throws {
        let model = UUDeviceSettingsModel(store: store)
        await model.refresh { [mac] }
        XCTAssertEqual(model.rows.first?.isOnline, false)
        model.edit("a", field: \.port, value: "17771")
        await model.refresh {
            model.edit("a", field: \.alias, value: " Desk ")
            throw PasteFailureReason.uuStatusUnavailable
        }
        XCTAssertTrue(model.listUnavailable)
        XCTAssertNil(model.rows.first?.isOnline)
        XCTAssertEqual(model.rows.first?.port, "17771")
        XCTAssertEqual(model.rows.first?.alias, " Desk ")
        model.save("a")
        XCTAssertEqual(store.bindings.first, UUBinding(deviceId: "a", name: "Mac A", port: 17771, alias: "Desk"))

        let renamed = UUDevice(deviceId: "a", deviceName: "Mac A2", platform: "mac", isOnline: true)
        await model.refresh { [renamed] }
        XCTAssertTrue(model.rows[0].needsSave)
        model.save("a")
        XCTAssertEqual(store.bindings.first?.name, "Mac A2")
        model.remove("a")
        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].port, "")
    }

    func testInvalidAndDuplicatePortsDoNotOverwriteSavedBindings() async throws {
        try store.save(UUBinding(deviceId: "b", name: "Mac B", port: 17772))
        let model = UUDeviceSettingsModel(store: store)
        await model.refresh { [mac] }
        for value in ["0", "65536", "text", "17772"] {
            model.edit("a", field: \.port, value: value)
            model.save("a")
            XCTAssertNotNil(model.rows.first { $0.id == "a" }?.message)
            XCTAssertEqual(store.bindings.map(\.deviceId), ["b"])
        }
    }

    func testEditInvalidatesInFlightCheckEvenWhenPortIsChangedBack() async {
        let model = UUDeviceSettingsModel(store: store)
        await model.refresh { [mac] }
        model.edit("a", field: \.port, value: "17771")
        await model.check("a", connections: { [] }, health: { port in
            XCTAssertEqual(port, 17771)
            model.edit("a", field: \.port, value: "17772")
            model.edit("a", field: \.port, value: "17771")
            return legacyHealth
        })
        XCTAssertNil(model.rows[0].checkResult)
        XCTAssertNil(model.rows[0].checkID)
    }

    func testCheckShowsControlAndBridgeIndependently() async {
        let model = UUDeviceSettingsModel(store: store)
        await model.refresh { [mac] }
        model.edit("a", field: \.port, value: "17771")
        await model.check("a", connections: { throw PasteFailureReason.uuStatusUnavailable }, health: { _ in legacyHealth })
        XCTAssertEqual(model.rows[0].checkResult, UUDeviceCheck(port: 17771, controlling: nil, bridge: .ready(legacyHealth)))
        await model.check("a", connections: {
            [UUConnection(deviceId: "other", deviceName: self.mac.deviceName, platform: "mac", connectionState: "connected",
                          isControlling: true, connectionStartTime: "now")]
        }, health: { _ in throw RemoteClipboardClientError.unsupportedProtocol(3) })
        XCTAssertEqual(model.rows[0].checkResult, UUDeviceCheck(port: 17771, controlling: false, bridge: .incompatible(3)))
    }
}

final class BridgeHealthTests: XCTestCase {
    func testOlderAndCurrentBridgeResponses() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [HealthOnlyURLProtocol.self]
        let client = RemoteClipboardClient(baseURL: URL(string: "http://127.0.0.1:17771")!, session: URLSession(configuration: session))
        let legacy = try await client.health()
        XCTAssertNil(legacy.helperBuild)
        XCTAssertNil(legacy.accessibilityTrusted)
        XCTAssertEqual(legacy.protocolVersion, 2)
        let current = RemoteClipboardClient(baseURL: URL(string: "http://127.0.0.1:17772")!, session: URLSession(configuration: session))
        let response = try await current.health()
        XCTAssertEqual(response.helperBuild, "1.4.0 (20)")
        XCTAssertEqual(response.accessibilityTrusted, false)
    }
}

private final class HealthOnlyURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET", url.path == "/health", request.httpBody == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = url.port == 17771
            ? #"{"ok":true,"protocolVersion":2}"#
            : #"{"ok":true,"protocolVersion":2,"accessibilityTrusted":false,"helperBuild":"1.4.0 (20)"}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
