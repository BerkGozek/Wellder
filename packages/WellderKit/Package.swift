// swift-tools-version: 6.0
import PackageDescription

// Shared code for the Alpha–Beta iOS and watchOS apps. macOS is listed only so the logic can be
// unit-tested quickly with `swift test`; nothing here is shipped as a Mac app.
let package = Package(
    name: "WellderKit",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "SharedModels", targets: ["SharedModels"]),
        .library(name: "MonitoringCore", targets: ["MonitoringCore"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(name: "SharedModels"),
        .target(name: "MonitoringCore", dependencies: ["SharedModels"]),
        .target(name: "Networking", dependencies: ["SharedModels", "MonitoringCore"]),
        .target(name: "DesignSystem", dependencies: ["SharedModels", "MonitoringCore"]),
        .testTarget(name: "SharedModelsTests", dependencies: ["SharedModels"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MonitoringCoreTests", dependencies: ["MonitoringCore"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
    ]
)
