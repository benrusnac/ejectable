// swift-tools-version:6.0
import PackageDescription

let release: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "Ejectable",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ejectable", targets: ["Ejectable"]),
        .executable(name: "ejectctl", targets: ["ejectctl"]),
        .library(name: "EjectKit", targets: ["EjectKit"]),
    ],
    targets: [
        // Holder scan, disk topology, eject. No UI; AppKit only for NSRunningApplication / NSWorkspace.
        .target(name: "EjectKit", path: "Sources/EjectKit", swiftSettings: release),
        // The menu-bar app (pure AppKit, LSUIElement). Never import SwiftUI.
        .executableTarget(name: "Ejectable", dependencies: ["EjectKit"], path: "Sources/Ejectable", swiftSettings: release),
        // CLI harness for testing EjectKit without UI.
        .executableTarget(name: "ejectctl", dependencies: ["EjectKit"], path: "Sources/ejectctl", swiftSettings: release),
        .testTarget(name: "EjectKitTests", dependencies: ["EjectKit"], path: "Tests/EjectKitTests"),
    ],
    swiftLanguageModes: [.v6]
)
