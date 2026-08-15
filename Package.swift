// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MACCommander",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MACCommander",
            path: "Sources/MACCommander",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
