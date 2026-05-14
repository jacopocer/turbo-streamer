// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Streamer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Streamer",
            path: "Sources/Streamer"
        )
    ]
)
