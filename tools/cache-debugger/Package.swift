// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CacheDebugger",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.11.3"),
        .package(url: "https://github.com/lake-of-fire/swift-readability", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "CacheDebugger",
            dependencies: [
                "SwiftSoup",
                .product(name: "SwiftReadability", package: "swift-readability"),
            ],
            path: "Sources"
        ),
    ]
)
