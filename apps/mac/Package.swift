// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared wire format between the app and the hook binary.
        .target(name: "PerchKit"),

        // The menu-bar-less app that owns the notch window.
        .executableTarget(
            name: "PerchApp",
            dependencies: ["PerchKit"]
        ),

        // Tiny CLI invoked by Claude Code hooks. Must stay fast and dependency-free.
        .executableTarget(
            name: "perch-hook",
            dependencies: ["PerchKit"]
        ),

        .testTarget(name: "PerchKitTests", dependencies: ["PerchKit"]),
    ]
)
