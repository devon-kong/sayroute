import Foundation
import XCTest
@testable import SayRoute

final class UpdateSignatureTests: XCTestCase {
    func testRealAdHocSignatureIsReadableButNotTrustedForAutomaticUpdateAndTamperingFails() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("signature-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appendingPathComponent("SayRoute.app")
        let contents = app.appendingPathComponent("Contents"), macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("SayRoute"))
        let plist: [String: String] = ["CFBundleIdentifier": "com.devonkong.sayroute", "CFBundleShortVersionString": "1.3.2",
            "CFBundleVersion": "19", "CFBundleExecutable": "SayRoute", "CFBundlePackageType": "APPL"]
        let info = contents.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let identity = try UpdateSignature.identity(at: app)
        XCTAssertNil(identity.teamID)
        XCTAssertThrowsError(try UpdatePolicy.requireTrustedRelease(identity))
        var changed = plist; changed["CFBundleVersion"] = "20"
        try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: info)
        XCTAssertThrowsError(try UpdateSignature.identity(at: app))
    }
}
