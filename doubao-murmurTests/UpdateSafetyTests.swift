import Foundation
import XCTest
@testable import Doubao_Murmur

final class UpdateSafetyTests: XCTestCase {
    private let current = UpdateIdentity(bundleID: "com.doubao.murmur", version: "1.3.1", build: "18", executable: "Doubao Murmur", teamID: "ABCDE12345")
    private var candidate: UpdateIdentity { UpdateIdentity(bundleID: "com.doubao.murmur", version: "1.3.2", build: "19", executable: "Doubao Murmur", teamID: "ABCDE12345") }

    func testOnlySamePublisherIdentityAndExpectedNewVersionAccepted() throws {
        XCTAssertNoThrow(try UpdatePolicy.validate(current: current, candidate: candidate, expectedVersion: "1.3.2"))
        var bad = candidate
        bad.teamID = "OTHER12345"
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: bad, expectedVersion: "1.3.2"))
        bad = candidate; bad.bundleID = "com.doubao.murmur.test.build16"
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: bad, expectedVersion: "1.3.2"))
        bad = candidate; bad.version = "1.3.3"
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: bad, expectedVersion: "1.3.2"))
        bad = candidate; bad.executable = "SomethingElse"
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: bad, expectedVersion: "1.3.2"))
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: current, expectedVersion: "1.3.1"))
    }

    func testAdHocCurrentBuildCannotTrustAnArbitraryMatchingBundle() {
        var unsigned = current; unsigned.teamID = nil
        XCTAssertThrowsError(try UpdatePolicy.validate(current: unsigned, candidate: candidate, expectedVersion: "1.3.2"))
        var unsignedNew = candidate; unsignedNew.teamID = nil
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: unsignedNew, expectedVersion: "1.3.2"))
    }

    func testMalformedReleaseOrDowngradeCannotEnterInstaller() {
        for version in ["1.3.beta", "1.3.2/../evil", "1.3.2\n", "-1.3.2", "999999999999999999999999"] {
            var bad = candidate; bad.version = version
            XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: bad, expectedVersion: version))
        }
        var old = candidate; old.version = "1.2.9"
        XCTAssertThrowsError(try UpdatePolicy.validate(current: current, candidate: old, expectedVersion: "1.2.9"))
    }

    private func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("update-tests-\(UUID())")
        let target = base.appendingPathComponent("Doubao Murmur.app")
        let stage = base.appendingPathComponent(".murmur-update-\(UUID())")
        let incoming = stage.appendingPathComponent("Doubao Murmur.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("payload"))
        try Data("new".utf8).write(to: incoming.appendingPathComponent("payload"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (target, incoming, stage)
    }

    func testSuccessfulAtomicSwapRetainsOldAppAsBackup() throws {
        let (target, incoming, _) = try fixture()
        var validated = false
        let result = try UpdateSwapTransaction.run(target: target, incoming: incoming, validate: {
            validated = true
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "old")
        }, launch: {
            XCTAssertTrue(validated)
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "new")
            return 42
        }, waitUntilReady: { $0 == 42 }, stop: { _ in XCTFail("Healthy update must remain running"); return false })
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(try String(contentsOf: incoming.appendingPathComponent("payload")), "old")
    }

    func testStartupFailureStopsNewProcessAndRestoresOldApp() throws {
        let (target, incoming, _) = try fixture()
        var stopped = false
        let result = try UpdateSwapTransaction.run(target: target, incoming: incoming, validate: {}, launch: { 42 },
            waitUntilReady: { _ in false }, stop: { pid in stopped = pid == 42; return true })
        XCTAssertEqual(result, .rolledBack)
        XCTAssertTrue(stopped)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "old")
        XCTAssertEqual(try String(contentsOf: incoming.appendingPathComponent("payload")), "new")
    }

    func testFailedValidationOrLaunchNeverDestroysOriginal() throws {
        enum Failure: Error { case refused }
        let (target, incoming, _) = try fixture()
        XCTAssertThrowsError(try UpdateSwapTransaction.run(target: target, incoming: incoming,
            validate: { throw Failure.refused }, launch: { XCTFail("Unverified code executed"); return 0 },
            waitUntilReady: { _ in true }, stop: { _ in true }))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "old")
        XCTAssertEqual(try UpdateSwapTransaction.run(target: target, incoming: incoming, validate: {},
            launch: { throw Failure.refused }, waitUntilReady: { _ in true }, stop: { _ in true }), .rolledBack)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "old")
    }

    func testCannotRollbackOverAProcessThatCouldNotBeStopped() throws {
        let (target, incoming, _) = try fixture()
        XCTAssertThrowsError(try UpdateSwapTransaction.run(target: target, incoming: incoming, validate: {}, launch: { 42 },
            waitUntilReady: { _ in false }, stop: { _ in false }))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "new")
        XCTAssertEqual(try String(contentsOf: incoming.appendingPathComponent("payload")), "old")
    }

    func testRollbackDoesNotOverwriteAnAppReplacedExternallyDuringStartup() throws {
        let (target, incoming, stage) = try fixture()
        XCTAssertThrowsError(try UpdateSwapTransaction.run(target: target, incoming: incoming, validate: {}, launch: { 42 },
            waitUntilReady: { _ in
                try! FileManager.default.moveItem(at: target, to: stage.appendingPathComponent("moved-new.app"))
                try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try! Data("external".utf8).write(to: target.appendingPathComponent("payload"))
                return false
            }, stop: { _ in true }))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload")), "external")
        XCTAssertEqual(try String(contentsOf: incoming.appendingPathComponent("payload")), "old")
    }
}
