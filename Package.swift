// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let generatedDirectories = ["build", "build-tests", "dist", "doubao-murmur.xcodeproj"].filter {
    FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path)
}

// Hostless tests never launch AppDelegate, global hotkeys or the helper.
let package = Package(
    name: "MurmurCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Doubao_Murmur", targets: ["Doubao_Murmur"])],
    targets: [
        .target(
            name: "Doubao_Murmur", path: ".",
            exclude: ["doubao-murmur/DoubaoMurmurApp.swift", "doubao-murmur/Info.plist",
                      "doubao-murmur/doubao-murmur.entitlements", "doubao-murmur/Resources",
                      "doubao-murmurTests", "docs", "scripts", "packaging",
                      "murmur-mirror", "murmur-updater", "README.md", "LICENSE", "project.yml"] + generatedDirectories,
            sources: ["doubao-murmur", "Shared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "MurmurTests", dependencies: ["Doubao_Murmur"], path: "doubao-murmurTests")
    ]
)
