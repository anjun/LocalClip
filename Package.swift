// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalClip",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LocalClipCore", targets: ["LocalClipCore"]),
        .executable(name: "LocalClip", targets: ["LocalClipApp"]),
        .executable(name: "LocalClipTestRunner", targets: ["LocalClipTestRunner"])
    ],
    targets: [
        .target(
            name: "LocalClipCore",
            path: "Sources/LocalClipCore"
        ),
        .executableTarget(
            name: "LocalClipApp",
            dependencies: ["LocalClipCore"],
            path: "Sources/LocalClipApp"
        ),
        .executableTarget(
            name: "LocalClipTestRunner",
            dependencies: ["LocalClipCore"],
            path: "Sources/LocalClipTestRunner"
        )
        // XCTest unavailable on Command Line Tools-only hosts; use LocalClipTestRunner instead.
    ]
)
