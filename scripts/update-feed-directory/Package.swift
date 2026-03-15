// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateFeedDirectory",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.11.3"),
        .package(url: "https://github.com/lake-of-fire/swift-readability", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "UpdateFeedDirectory",
            dependencies: [
                "SwiftSoup",
                .product(name: "SwiftReadability", package: "swift-readability"),
            ],
            path: "Sources"
        ),
    ]
)
