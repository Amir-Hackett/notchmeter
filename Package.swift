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
        // C wrappers for Security calls that are deprecated without replacement; clang can silence those, Swift cannot.
        .target(
            name: "NotchmeterShims",
            path: "Sources/NotchmeterShims",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "Notchmeter",
            dependencies: ["DynamicNotchKit", "NotchmeterShims"],
            path: "Sources/Notchmeter",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "NotchmeterTests",
            dependencies: ["Notchmeter"],
            path: "Tests/NotchmeterTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
