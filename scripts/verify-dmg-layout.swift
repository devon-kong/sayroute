#!/usr/bin/swift
// Inspect Finder's persisted icon-view plist without depending on Finder's
// background-picture getter (which returns missing value on some macOS builds).
import AppKit
import CoreFoundation

func fail(_ message: String) -> Never {
    fputs("DMG layout verification failed: \(message)\n", stderr)
    exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("expected mounted volume path") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    let store = try Data(contentsOf: root.appendingPathComponent(".DS_Store"))
    let marker = Data("icvpblob".utf8)
    guard let record = store.range(of: marker), record.upperBound + 4 <= store.count else {
        fail("missing Finder icon-view record")
    }
    let length = store[record.upperBound ..< record.upperBound + 4].reduce(0) { ($0 << 8) | Int($1) }
    let start = record.upperBound + 4
    guard length > 0, length <= store.count - start,
          let settings = try PropertyListSerialization.propertyList(
            from: store.subdata(in: start ..< start + length), options: [], format: nil) as? [String: Any],
          settings["backgroundType"] as? Int == 2,
          settings["iconSize"] as? Int == 96,
          settings["arrangeBy"] as? String == "none",
          let alias = settings["backgroundImageAlias"] as? Data else {
        fail("invalid background/icon-view settings")
    }
    guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, alias as CFData)?.takeRetainedValue() else {
        fail("invalid background alias record")
    }
    var stale = DarwinBoolean(false)
    var error: Unmanaged<CFError>?
    guard let resolved = CFURLCreateByResolvingBookmarkData(kCFAllocatorDefault, bookmark,
        [.cfurlBookmarkResolutionWithoutUIMask, .cfurlBookmarkResolutionWithoutMountingMask],
        nil, nil, &stale, &error)?.takeRetainedValue() else {
        fail("background alias does not resolve: \(String(describing: error?.takeRetainedValue()))")
    }
    let actual = (resolved as URL).standardizedFileURL.resolvingSymlinksInPath()
    let expected = root.appendingPathComponent(".background/background.png").standardizedFileURL.resolvingSymlinksInPath()
    guard actual == expected else { fail("background resolves outside the mounted image: \(actual.path)") }
    let image = try Data(contentsOf: expected)
    guard image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          let bitmap = NSBitmapImageRep(data: image), bitmap.pixelsWide == 1280, bitmap.pixelsHigh == 840 else {
        fail("background is not a 1280x840 PNG")
    }
    print("Verified Finder background alias resolves within mounted image and icon-view metadata is persisted.")
} catch { fail("\(error)") }
