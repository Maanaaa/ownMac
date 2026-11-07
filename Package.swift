// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "OwnMac",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "OwnMac", path: "Sources/OwnMac", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
