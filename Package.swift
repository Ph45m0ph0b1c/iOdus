// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "iOdus",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "iOdus",
            path: "Sources/iOdus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "iOdusTests",
            dependencies: ["iOdus"],
            path: "Tests/iOdusTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
