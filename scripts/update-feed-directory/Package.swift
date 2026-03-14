// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateFeedDirectory",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "UpdateFeedDirectory",
            path: "Sources"
        ),
    ]
)
