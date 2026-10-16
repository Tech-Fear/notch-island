// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "NotchIsland", path: "Sources/NotchIsland"),
        // Tiny helper that Claude Code hooks call; ships inside the app as Contents/MacOS/notch-hook.
        .executableTarget(name: "NotchHook", path: "Sources/NotchHook"),
        .testTarget(name: "NotchIslandTests", dependencies: ["NotchIsland"], path: "Tests/NotchIslandTests"),
    ],
    swiftLanguageModes: [.v5] // the code isn't written for Swift 6's strict concurrency checks yet
)
