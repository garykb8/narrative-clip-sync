// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]

let package = Package(
    name: "ClipKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClipKit", targets: ["ClipKit"]),
        .executable(name: "narrative-clip-sync", targets: ["narrative-clip-sync"]),
    ],
    targets: [
        .target(name: "ClipKit", swiftSettings: settings),
        .executableTarget(name: "narrative-clip-sync", dependencies: ["ClipKit"], swiftSettings: settings),
        .testTarget(name: "ClipKitTests", dependencies: ["ClipKit"], swiftSettings: settings),
    ]
)
