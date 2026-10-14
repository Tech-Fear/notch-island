// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchIsland", path: "Sources/NotchIsland"),
        // Tiny helper that Claude Code hooks call; ships inside the app as Contents/MacOS/notch-hook.
        .executableTarget(name: "NotchHook", path: "Sources/NotchHook"),
        .testTarget(name: "NotchIslandTests", dependencies: ["NotchIsland"], path: "Tests/NotchIslandTests"),
    ]
)
