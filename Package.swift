// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let generatedDirectories = ["build", "build-tests", "dist", "SayRoute.xcodeproj"].filter {
    FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path)
}

// Hostless tests never launch AppDelegate, global hotkeys or the helper.
let package = Package(
    name: "SayRouteCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SayRoute", targets: ["SayRoute"])],
    targets: [
        .target(
            name: "SayRoute", path: ".",
            exclude: ["SayRoute/SayRouteApp.swift", "SayRoute/Info.plist",
                      "SayRoute/SayRoute.entitlements", "SayRoute/Resources",
                      "SayRouteTests", "docs", "scripts", "packaging",
                      "sayroute-bridge", "sayroute-updater", "README.md", "README.zh-CN.md", "ATTRIBUTION.md", "LICENSE", "project.yml"] + generatedDirectories,
            sources: ["SayRoute", "Shared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "SayRouteTests", dependencies: ["SayRoute"], path: "SayRouteTests")
    ]
)
