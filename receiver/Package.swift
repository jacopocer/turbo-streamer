// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Receiver",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Receiver",
            path: "Sources/Receiver"
        )
    ]
)
