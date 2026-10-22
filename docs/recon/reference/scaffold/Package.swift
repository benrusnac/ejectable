// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hello",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hello",
            path: "Sources/Hello",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
