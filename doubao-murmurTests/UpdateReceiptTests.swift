import Foundation
import XCTest
@testable import Doubao_Murmur

final class UpdateReceiptTests: XCTestCase {
    func testValidStartupWritesReceiptForOnlyItsOwnTransaction() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-valid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let nonce = UUID(), target = base.appendingPathComponent("Murmur.app")
        let stage = base.appendingPathComponent(".murmur-update-" + nonce.uuidString)
        let incoming = stage.appendingPathComponent(target.lastPathComponent)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.doubao.murmur", "CFBundleShortVersionString": "1.3.2",
                     "CFBundleVersion": "19", "CFBundleExecutable": "Murmur", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: target.appendingPathComponent("Contents/Info.plist"))
        let identity = UpdateIdentity(bundleID: "com.doubao.murmur", version: "1.3.2", build: "19", executable: "Murmur", teamID: "ABCDE12345")
        let plan = UpdatePlan(nonce: nonce, parentPID: 123, target: target, incoming: incoming, current: identity, candidate: identity)
        try JSONEncoder().encode(plan).write(to: stage.appendingPathComponent("plan.json"))
        let bundle = try XCTUnwrap(Bundle(url: target))
        XCTAssertTrue(UpdateStartupReceipt.writeIfRequested(arguments: ["app", "--murmur-update-stage", stage.path,
            "--murmur-update-nonce", nonce.uuidString], bundle: bundle))
        let receipt = try JSONDecoder().decode(UpdateLaunchReceipt.self, from: Data(contentsOf: plan.receiptURL))
        XCTAssertTrue(receipt.matches(nonce: nonce, pid: ProcessInfo.processInfo.processIdentifier, target: target, identity: identity))
    }
    func testReceiptRequiresExactNoncePIDPathAndBuild() {
        let identity = UpdateIdentity(bundleID: "com.doubao.murmur", version: "1.3.2", build: "19", executable: "Doubao Murmur", teamID: "ABCDE12345")
        let path = URL(fileURLWithPath: "/Applications/Doubao Murmur.app")
        let nonce = UUID()
        let receipt = UpdateLaunchReceipt(nonce: nonce, pid: 42, appPath: path.path, bundleID: identity.bundleID, version: identity.version, build: identity.build)
        XCTAssertTrue(receipt.matches(nonce: nonce, pid: 42, target: path, identity: identity))
        XCTAssertFalse(receipt.matches(nonce: UUID(), pid: 42, target: path, identity: identity))
        XCTAssertFalse(receipt.matches(nonce: nonce, pid: 43, target: path, identity: identity))
        XCTAssertFalse(receipt.matches(nonce: nonce, pid: 42, target: path.appendingPathComponent("other"), identity: identity))
        var old = identity; old.build = "18"
        XCTAssertFalse(receipt.matches(nonce: nonce, pid: 42, target: path, identity: old))
    }

    func testStartupCannotWriteReceiptToArbitraryDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-tests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(UpdateStartupReceipt.writeIfRequested(arguments: ["app", "--murmur-update-stage", base.path,
            "--murmur-update-nonce", UUID().uuidString], bundle: .main))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("ready.json").path))
    }
}
