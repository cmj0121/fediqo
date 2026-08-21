// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fediqo",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "FediqoCore", targets: ["FediqoCore"]),
        .library(name: "FediqoUI", targets: ["FediqoUI"]),
    ],
    targets: [
        .target(
            name: "FediqoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FediqoUI",
            dependencies: ["FediqoCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoCoreTests",
            dependencies: ["FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
