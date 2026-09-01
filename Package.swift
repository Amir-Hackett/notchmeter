// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchmeter",
    platforms: [.macOS(.v14)],
    targets: [
        // MrKai77/DynamicNotchKit 1.1.0 (MIT), vendored so it builds without Xcode's SwiftUI macro plugins.
        .target(
            name: "DynamicNotchKit",
            path: "Vendor/DynamicNotchKit",
            exclude: ["LICENSE"]
        ),
        .executableTarget(
            name: "Notchmeter",
            dependencies: ["DynamicNotchKit"],
            path: "Sources/Notchmeter",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "NotchmeterTests",
            dependencies: ["Notchmeter"],
            path: "Tests/NotchmeterTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
