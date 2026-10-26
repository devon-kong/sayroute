import Foundation
import XCTest
@testable import Doubao_Murmur

final class UpdateArchiveTests: XCTestCase {
    func testSingleAppArchiveIsAccepted() throws {
        XCTAssertEqual(try UpdateArchive.applicationRoot(in: zip(["Doubao Murmur.app/Contents/Info.plist"])), "Doubao Murmur.app")
    }
    func testTraversalAbsoluteBackslashAndAmbiguousBundlesAreRejected() {
        for names in [["../outside.app/file"], ["/Applications/evil.app/file"], ["Good.app/../file"],
                      ["Good.app/Contents\\escape"], ["Good.app/a\nfile"], ["A.app/a", "B.app/b"],
                      ["Good.app/A", "Good.app/a"], ["Good.app/a", "outside"]] {
            XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: zip(names)), "\(names)")
        }
    }
    func testSymlinkOversizedAndDisagreeingLocalHeadersAreRejected() {
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: zip(["Good.app/link"], mode: 0o120777)))
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: zip(["Good.app/large"], expanded: 600_000_000)))
        var mismatched = zip(["Good.app/a"])
        mismatched[30] = UInt8(ascii: "B")
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: mismatched))
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: Data([1, 2, 3])))
    }

    func testAlternativeUnicodePathMetadataCannotBypassValidatedNames() {
        // Unicode path extra field (0x7075) can override the validated name in an extractor.
        let alias = Data([0x75, 0x70, 0x04, 0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: zip(["Good.app/file"], extra: alias)))
    }

    func testLocalSizeDisagreementAndStoredContentSizeLieAreRejected() {
        var localLie = zip(["Good.app/file"])
        localLie[18] = 1
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: localLie))
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: zip(["Good.app/file"], expanded: 1)))
    }

    func testRealDittoDeflatedArchiveAndUnderreportedExpansion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zip-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appendingPathComponent("Good.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 100_000).write(to: app.appendingPathComponent("payload"))
        let archive = base.appendingPathComponent("fixture.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var data = try Data(contentsOf: archive)
        XCTAssertEqual(try UpdateArchive.applicationRoot(in: data), "Good.app")
        // Lie consistently in both headers; the real deflate stream still expands.
        for i in 0..<(data.count - 30) {
            if Array(data[i..<(i + 4)]) == [0x50, 0x4b, 0x03, 0x04] {
                data.replaceSubrange((i + 22)..<(i + 26), with: [0, 0, 0, 0])
            }
            if Array(data[i..<(i + 4)]) == [0x50, 0x4b, 0x01, 0x02] {
                data.replaceSubrange((i + 24)..<(i + 28), with: [0, 0, 0, 0])
            }
        }
        XCTAssertThrowsError(try UpdateArchive.applicationRoot(in: data))
    }

    private func zip(_ names: [String], mode: UInt32 = 0o100644, expanded: UInt32 = 0, extra: Data = Data()) -> Data {
        var body = Data(), central = Data()
        func u16(_ n: UInt16) -> Data { withUnsafeBytes(of: n.littleEndian) { Data($0) } }
        func u32(_ n: UInt32) -> Data { withUnsafeBytes(of: n.littleEndian) { Data($0) } }
        for name in names {
            let path = Data(name.utf8), offset = UInt32(body.count)
            body += u32(0x04034b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            body += u32(0) + u32(0) + u32(expanded) + u16(UInt16(path.count)) + u16(UInt16(extra.count)) + path + extra
            central += u32(0x02014b50) + u16(0x0314) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(0) + u32(expanded) + u16(UInt16(path.count)) + u16(UInt16(extra.count)) + u16(0)
            central += u16(0) + u16(0) + u32(mode << 16) + u32(offset) + path + extra
        }
        let offset = UInt32(body.count), size = UInt32(central.count)
        body += central
        body += u32(0x06054b50) + u16(0) + u16(0) + u16(UInt16(names.count)) + u16(UInt16(names.count))
        body += u32(size) + u32(offset) + u16(0)
        return body
    }
}
